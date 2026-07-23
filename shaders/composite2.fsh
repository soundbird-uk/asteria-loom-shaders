#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"

/*
 composite2 (fragment) — aerial-perspective fog.

 Runs AFTER composite (volumetric clouds already blended into colortex0). It
 reconstructs each pixel's world-relative position from depthtex0 (translucent-
 inclusive, so water/glass/particles get fogged too — Phase 3 correctly fogs
 the water surface that was already drawn into colortex0), builds the view ray,
 and applies exponential-height aerial-perspective fog (lib/fog.glsl):
 extinction toward the distance + in-scatter toward the atmosphere's sky LUT in
 the view direction. That single-scattering model is what shifts distance
 bluer/desaturated with a warm hazy horizon and tracks time of day for free.

 Sky pixels (depth == 1) pass through UNCHANGED: the clouds pass already carries
 the sky's own transmittance, so fogging them would double-count. isEyeInWater
 != 0 (underwater / lava / powder snow) also passes through — Phase 4 owns
 underwater fog. Biome and weather modulate density + tint (see lib/fog.glsl
 for the full multiplier table).

 SKY-EXPOSURE GATING: aerial fog is outdoor haze, so it is scaled by this
 pixel's sky lightmap (colortex2.a) — caves and interiors (sky-lm ~0) receive
 ZERO fog, preserving Phase 2's cave darkness; open valleys keep the full
 amount. Combined with the sea-level DENSITY FLOOR in lib/fog.glsl this fixes
 the reviewer's "bright haze fills caves / below-sea space" bug.
 CAVEAT: colortex2 is the OPAQUE G-buffer. Where depthtex0 is a translucent
 surface, the sky lightmap sampled belongs to the opaque geometry BEHIND it —
 an accepted approximation (the translucent layer is thin relative to the fog).

 --------------------------------------------------------------------------
 UNIFORM VERIFICATION (exact Iris names) — evidence:
   * rainStrength, wetness, isEyeInWater, frameTimeCounter:
       IrisShaders/ShaderDoc  uniforms.md  (✔️ Iris) — declared as shown.
   * thunderStrength:
       Iris 1.21.11 IrisExclusiveUniforms.java:62
         uniform1f(PER_FRAME, "thunderStrength", ...)
   * biome_category (int), temperature (float), rainfall (float):
       Iris 1.21.11 BiomeUniforms.java:32/52/50
         uniform1i(PER_TICK, "biome_category", ...)  // = BiomeCategories.ordinal()
         uniform1f(PER_TICK, "temperature", ...)     // Biome base temperature
         uniform1f(PER_TICK, "rainfall", ...)        // Biome downfall
   NOTE: Iris does NOT auto-define CAT_* macros (verified: no CAT_* in
   StandardMacros.java), so lib/fog.glsl defines AL_CAT_* matching the enum
   ordinals. All biome reads are gated behind AL_FOG_BIOME_UNIFORMS
   (lib/fog.glsl) so the pack degrades gracefully if they ever change.
 --------------------------------------------------------------------------

 Sampler count: 4 (colortex0, colortex2, depthtex0, + colortex6 via the
 atmosphere include). Budget ≤5. No loops; a couple of exp() only — trivially
 cheap, kept on in every profile.
*/

// colortex6 (sky-view LUT tile) is declared and OWNED by lib/atmosphere.glsl
// (its alSkySample() reads it). We must NOT redeclare it here — that include is
// the single owner of the sampler (its header states callers must not collide).
// The LUT read is range-validated NaN-proof there AND again around the result
// in lib/fog.glsl (clear=false buffer, analytic-sky fallback).
uniform sampler2D colortex0;   // scene HDR (sky + lit scene + translucents + clouds)
uniform sampler2D colortex2;   // G-buffer: normal.rg (octahedral), lightmap.ba (block, sky)
uniform sampler2D colortex3;   // G-buffer: matID .r (outline / god-ray gating)
uniform sampler2D depthtex0;   // translucent-inclusive depth

// Weather (verified). rainStrength/wetness/thunderStrength drive density/tint.
uniform float rainStrength;
uniform float wetness;
uniform float thunderStrength;

// Camera state (verified). isEyeInWater: 0 = none, 1 = water, 2 = lava, 3 =
// powder snow. Phase 4 (WATER agent) now HANDLES the submerged cases here (the
// underwater medium) instead of passing them through.
uniform int   isEyeInWater;

// frameTimeCounter (verified Iris uniform) — Phase 4 addition, needed ONLY by
// the underwater UV-refraction wobble in the isEyeInWater branch below. Declared
// nowhere else in this program / its includes, so this is collision-free.
uniform float frameTimeCounter;

// Render distance (blocks). Feeds the thin edge-insurance strip that closes the
// terrain/sky seam at low render distances (the primary sky-convergence is
// optical-depth driven inside lib/fog.glsl — no distance band).
uniform float far;

// Sun position (view/eye space, Iris/OptiFine standard). Transformed to world
// space (via lib/space.glsl) for the fog's time-of-day scene tone and the night
// factor that drives the night fog floor.
uniform vec3 sunPosition;

// Forward projection (view -> clip) for the god-ray sun screen position. Owned
// here: lib/space.glsl declares only the INVERSE, so this is collision-free.
uniform mat4 gbufferProjection;

// Biome (verified Iris uniforms — see header). Used only behind
// AL_FOG_BIOME_UNIFORMS in lib/fog.glsl; declared here unconditionally so the
// program always compiles (Iris supplies them; unused declarations are legal).
uniform int   biome_category;
uniform float temperature;
uniform float rainfall;

// cameraPosition + the inverse matrices used for reconstruction come from
// lib/space.glsl (it OWNS them — do not redeclare).

// lib/atmosphere.glsl provides alSkySample() (cheap colortex6 read) and OWNS
// the colortex6 declaration. Included BEFORE lib/fog.glsl, which calls
// alSkySample().
#include "/lib/atmosphere.glsl"
#include "/lib/fog.glsl"

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;   // -> colortex0 (fogged scene)

#ifdef AL_GOD_RAYS
// Screen-space sun shafts (ISSUE 12). March from this pixel toward the sun's
// screen position, accumulating UNOCCLUDED (sky / gap) samples with a decaying
// weight. Returns a normalised [0,1] shaft amount; the caller tints + gates it.
// Reuses depthtex0 (no extra sampler). Dithered start kills banding.
float alGodRayAmount(vec2 uv, vec2 sunUV, float dither) {
    vec2  delta = (sunUV - uv) / float(AL_GODRAY_SAMPLES);
    vec2  p     = uv + delta * dither;
    float w     = 1.0;
    float accum = 0.0;
    for (int i = 0; i < AL_GODRAY_SAMPLES; i++) {
        float d = texture(depthtex0, clamp(p, vec2(0.0015), vec2(0.9985))).r;
        accum += ((d >= 1.0) ? 1.0 : 0.0) * w;   // sky/gap = light gets through
        w     *= AL_GODRAY_DECAY;
        p     += delta;
    }
    float wsum = (1.0 - pow(AL_GODRAY_DECAY, float(AL_GODRAY_SAMPLES)))
               / max(1.0 - AL_GODRAY_DECAY, 1e-4);
    return accum / max(wsum, 1e-4);
}
#endif

void main() {
    vec3  scene = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;

#if DEBUG_VIEW != 0
    // Debug views inspect earlier buffers / the deferred1 probes — never fog the
    // probe output. Pass colortex0 straight through so DEBUG_VIEW 7/8 (and any
    // grading debug) see exactly what the upstream pass wrote.
    outColor = vec4(scene, 1.0);
    return;
#endif

    // ---- UNDERWATER MEDIUM (Phase 4, WATER agent — the isEyeInWater branch) --
    // isEyeInWater: 1 = water, 2 = lava, 3 = powder snow. Each is an exponential
    // distance haze toward a medium tint; water additionally gets a gentle
    // time-animated UV refraction wobble of the scene sample. Aerial fog stays
    // SKIPPED underwater (this branch returns before the fog integral). We have
    // no per-biome water colour at composite time, so water uses a pleasant
    // UNIVERSAL blue-green (documented approximation). All NaN-safe: fail clear.
    if (isEyeInWater != 0) {
        vec2 uv = texcoord;
        if (isEyeInWater == 1) {
            float t = frameTimeCounter;
            vec2 wob = vec2(sin(uv.y * 42.0 + t * 1.4),
                            sin(uv.x * 42.0 + t * 1.7)) * AL_UW_WOBBLE;
            uv = clamp(texcoord + wob, 0.0, 1.0);
        }
        vec3  s  = texture(colortex0, uv).rgb;
        float du = texture(depthtex0, uv).r;

        // Distance to the sampled surface (sky / degenerate -> far).
        float d;
        if (du >= 1.0) {
            d = far * 2.0;
        } else {
            vec3 pp = alViewToPlayer(alScreenToView(uv, du));
            d = length(pp);
            if (!(d >= 0.0) || d > 1.0e7) d = far * 2.0;
        }

        vec3  tint; float density;
        if (isEyeInWater == 1)      { tint = AL_UW_WATER_TINT; density = AL_UW_WATER_DENSITY; }
        else if (isEyeInWater == 2) { tint = AL_UW_LAVA_TINT;  density = AL_UW_LAVA_DENSITY;  }
        else                        { tint = AL_UW_SNOW_TINT;  density = AL_UW_SNOW_DENSITY;  }

        float haze = alSaturate(1.0 - exp(-max(density, 0.0) * d));
        vec3  outc = mix(s, tint, haze);

        bool okU = all(greaterThanEqual(outc, vec3(0.0)));
        outColor = vec4(okU ? outc : s, 1.0);
        return;
    }

    // Sky (clouds carry their own transmittance) -> passthrough.
    if (depth >= 1.0) {
        outColor = vec4(scene, 1.0);
        return;
    }

    // Block selection outline / hitboxes (matID BASIC): an interaction overlay,
    // NOT world geometry — must not be fogged (ISSUE 16). Pass it straight through.
    if (alDecodeMatID(texture(colortex3, texcoord).r) == AL_MATID_BASIC) {
        outColor = vec4(scene, 1.0);
        return;
    }

    // Reconstruct the world-relative view ray from depth.
    vec3  viewPos   = alScreenToView(texcoord, depth);
    vec3  playerPos = alViewToPlayer(viewPos);          // world pos rel. camera
    float dist      = length(playerPos);

    // FAIL-SAFE (Mac world-wash fix): a degenerate reconstruction (NaN from a
    // near-zero clip.w on Apple GL, or an absurd distance) must PASS THE SCENE
    // THROUGH, never feed a huge/NaN distance into the fog integral where it
    // saturates optical depth and replaces the whole world with sky in-scatter.
    // Comparisons reject NaN/Inf (neither is >= 0.0).
    if (!(dist >= 0.0) || dist > 1.0e7) {
        outColor = vec4(scene, 1.0);
        return;
    }
    vec3  worldDir  = (dist > 1.0e-4) ? playerPos / dist : vec3(0.0, 1.0, 0.0);

    // Sky-exposure gate input: raw sky lightmap (colortex2.a). Range-clamped so
    // a stray value can't push the smoothstep out of [0,1].
    float skyLm = alSaturate(texture(colortex2, texcoord).a);

    // World-space sun direction for the time-of-day scene tone / night factor.
    vec3 worldSunDir = normalize(alViewDirToWorld(sunPosition));

    vec3 fogged = alApplyAerialFog(scene, cameraPosition.y, worldDir, dist,
                                   FOG_DENSITY, skyLm, far, worldSunDir,
                                   biome_category, temperature, rainfall,
                                   rainStrength, wetness, thunderStrength);

#ifdef AL_GOD_RAYS
    // --- Sun shafts / god rays (ISSUE 12) ---------------------------------
    // Additive warm shafts fanning from the sun through gaps in leaves/terrain.
    // Heavily gated so it costs ~nothing and never washes the screen: only when
    // the sun is in front of the camera, above the horizon, on/near screen, and
    // the view points roughly toward it; strongest at low sun and in haze.
    {
        vec4 sc = gbufferProjection * vec4(sunPosition, 1.0);
        if (sc.w > 0.0 && worldSunDir.y > -0.02) {
            vec2  sunUV   = sc.xy / sc.w * 0.5 + 0.5;
            float dayUp   = smoothstep(-0.02, 0.12, worldSunDir.y);
            float lowSun  = mix(1.0, AL_GODRAY_LOWSUN,
                                1.0 - smoothstep(0.04, 0.35, worldSunDir.y));
            float haze    = mix(1.0, AL_GODRAY_RAINBOOST, alSaturate(rainStrength));
            // Soft on-screen window (a little off-screen still contributes edge rays).
            vec2  q       = alSaturate((sunUV + 0.35) / 1.70);
            float onScr   = alSaturate(16.0 * q.x * (1.0 - q.x) * q.y * (1.0 - q.y));
            float facing  = alSaturate(dot(worldDir, worldSunDir));
            float gate    = dayUp * onScr * lowSun * haze * (0.25 + 0.75 * facing);
            if (gate > 0.001) {
                float dither = fract(frameTimeCounter * 61.8
                                   + dot(gl_FragCoord.xy, vec2(0.0071, 0.0113)));
                float shaft  = alGodRayAmount(texcoord, sunUV, dither);
                fogged += alDirectColor(worldSunDir)
                        * (shaft * AL_GODRAY_INTENSITY * gate);
            }
        }
    }
#endif

    // Clamp the output (NaN-safe: a non-finite result falls back to the raw
    // scene rather than propagating).
    bool finite = (fogged.r >= 0.0 && fogged.g >= 0.0 && fogged.b >= 0.0);
    outColor = vec4(finite ? min(fogged, vec3(65000.0)) : scene, 1.0);
}
