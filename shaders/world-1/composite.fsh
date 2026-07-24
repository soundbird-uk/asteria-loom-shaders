#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/clouds_common.glsl"
#include "/lib/water.glsl"

/*
============================================================================
 composite (fragment) — WATER EFFECTS. Runs AFTER translucents, BEFORE the
 clouds pass (composite1) and fog pass (composite2).
----------------------------------------------------------------------------
 gbuffers_water tagged every water pixel: colortex3.r = matID WATER, colortex2
 = ripple normal (.rg) + lightmap (.ba). For those pixels this pass:

   1. SSR — reconstruct the water surface view position from depthtex0, decode
      the ripple normal, reflect the view ray and RAYMARCH it in VIEW SPACE
      against depthtex0 (16/24/32 steps by SSR_QUALITY, binary-search refined,
      dithered start, screen-edge + thickness rejection). Hit -> sample the
      post-translucent scene (colortex0); miss/off-screen -> alSkySample of the
      world reflected dir. Blended over the water via Schlick Fresnel (f0=0.02).
      Gated INTERNALLY by SSR so absorption + caustics still run with SSR off.

   2. ABSORPTION — where an opaque surface sits behind the water (depthtex1 >
      depthtex0), tint the pixel by Beer-Lambert over the water PATH LENGTH
      between the two linearized depths (green-blue: red absorbed most). HONEST
      APPROXIMATION (documented): colortex0 here already blended the translucent
      water over the scene, so we cannot isolate the transmitted term — we apply
      absorption as a MULTIPLICATIVE darkening of the pixel, weighted by
      (1 - Fresnel) so it reads as depth-dependent water colour and vanishes into
      the reflection at grazing.

   3. CAUSTICS (behind WATER_CAUSTICS) — an animated 2-octave voronoi network
      (pure math, lib/water.glsl) evaluated at the SUBMERGED surface position
      (reconstructed from depthtex1) and projected along the sun direction
      (alSunDirWorld, sampler-free). Modulates the submerged contribution ±~28%,
      scaled by water-depth falloff, the water surface's sky lightmap, and the
      day factor. Soft, dreamy, slow.

 The pass ALWAYS runs (NOT gated on SSR — that would kill absorption/caustics
 with SSR off, contract §6). Non-water pixels take a one-line early-out.

 SAMPLER BUDGET (recount): 7 of 8 max —
   1 colortex0  (scene, SSR hit colour + base)
   2 colortex2  (water ripple normal .rg + lightmap .ba)
   3 colortex3  (matID mask)
   4 depthtex0  (translucent-inclusive = water surface depth; SSR march target)
   5 depthtex1  (opaque-only depth = scene behind the water)
   6 noisetex   (SSR dither)
   7 colortex6  (sky-view LUT, via lib/atmosphere.glsl alSkySample)
 lib/space.glsl and lib/clouds_common.glsl add only matrices/plain uniforms
 (no samplers). <= 8. NaN-law: every clear=false read (colortex6) is range-
 validated in its accessor; reconstruction is guarded; the result falls back to
 the untouched scene on any non-finite value (fail toward the plain scene).
============================================================================
*/

// SSR step count from the quality tier (16 / 24 / 32).
#if SSR_QUALITY == 1
    #define AL_SSR_STEPS 16
#elif SSR_QUALITY == 3
    #define AL_SSR_STEPS 32
#else
    #define AL_SSR_STEPS 24
#endif

uniform sampler2D colortex0;   // scene HDR (opaque + translucents blended)
uniform sampler2D colortex2;   // water surface: normal .rg, lightmap .ba
uniform sampler2D colortex3;   // matID .r
uniform sampler2D depthtex0;   // translucent-inclusive depth (water surface)
uniform sampler2D depthtex1;   // opaque-only depth (behind the water)
uniform sampler2D noisetex;    // blue-ish noise for the dithered SSR start

// Forward matrices for the view-space raymarch projection. lib/space.glsl owns
// the INVERSE matrices + cameraPosition/previous* (do not redeclare those);
// these two are declared nowhere else, so declaring them here is collision-free.
uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

uniform int frameCounter;      // Iris: frame index (wraps) for the R2 dither

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;   // -> colortex0 (water-reflected scene)

// View-space linear eye distance in front of the camera (positive).
float alEyeZ(vec3 viewPos) { return -viewPos.z; }

/*
 SSR raymarch in view space against depthtex0. `origin` is the water surface
 view position, `dir` the reflected view direction (unit). Returns true + the
 hit UV when the ray crosses behind a thin surface on-screen; false otherwise.
 Standard scheme: fixed-length steps with a dithered start, detect the crossing
 (rayPos passes behind the sampled surface: rayPos.z < sceneZ), reject when the
 gap exceeds a thickness tolerance (ray slipped behind a foreground object), and
 binary-search between the last in-front and first behind sample to refine.
*/
bool alTraceSSR(vec3 origin, vec3 dir, float dither, out vec2 hitUV) {
    float stepLen = AL_SSR_MAX_DIST / float(AL_SSR_STEPS);
    vec3  rayPos  = origin + dir * stepLen * (0.5 + dither);   // dithered start
    hitUV = vec2(0.0);

    for (int i = 0; i < AL_SSR_STEPS; i++) {
        rayPos += dir * stepLen;

        vec4 clip = gbufferProjection * vec4(rayPos, 1.0);
        if (clip.w <= 0.0) return false;                       // behind camera
        vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return false;

        float sd = texture(depthtex0, uv).r;
        if (sd >= 1.0) continue;                               // sky here, no hit
        vec3 scene = alScreenToView(uv, sd);

        // Both z are negative (view forward = -z). rayPos behind surface => more
        // negative than scene.z => (rayPos.z - scene.z) < 0.
        if (rayPos.z - scene.z < 0.0) {
            float thick = scene.z - rayPos.z;                  // positive gap
            if (thick < AL_SSR_THICKNESS + stepLen) {
                // Binary-search refine between the previous (in-front) sample and
                // this (behind) sample.
                vec3 a = rayPos - dir * stepLen;
                vec3 b = rayPos;
                for (int r = 0; r < AL_SSR_REFINE; r++) {
                    vec3 m = (a + b) * 0.5;
                    vec4 mc = gbufferProjection * vec4(m, 1.0);
                    vec2 muv = (mc.xy / mc.w) * 0.5 + 0.5;
                    float msd = texture(depthtex0, muv).r;
                    vec3 ms = alScreenToView(muv, msd);
                    if (m.z - ms.z < 0.0) b = m; else a = m;
                }
                vec4 bc = gbufferProjection * vec4(b, 1.0);
                hitUV = (bc.xy / bc.w) * 0.5 + 0.5;
                return true;
            }
            return false;   // crossed but too thick -> behind an object, reject
        }
    }
    return false;
}

void main() {
    vec3 base = texture(colortex0, texcoord).rgb;

#if DEBUG_VIEW != 0
    // Keep the debug probes / raw-channel views exactly as upstream wrote them —
    // water FX must never colour a debug view (matches composite2's pattern).
    outColor = vec4(base, 1.0);
    return;
#endif

    // Non-water pixels: untouched.
    int mat = alDecodeMatID(texture(colortex3, texcoord).r);
    if (mat != AL_MATID_WATER) {
        outColor = vec4(base, 1.0);
        return;
    }

    float d0 = texture(depthtex0, texcoord).r;

    // Reconstruct the water surface view position; guard degenerate math.
    vec3 P0 = alScreenToView(texcoord, d0);
    float dist0 = length(P0);
    if (!(dist0 >= 0.0) || dist0 > 1.0e7) {
        outColor = vec4(base, 1.0);
        return;
    }

    // Decode the ripple normal (world) -> view space for the raymarch.
    vec3 Nw = alDecodeNormal(texture(colortex2, texcoord).rg);
    vec3 Nv = normalize(mat3(gbufferModelView) * Nw);
    vec3 I  = normalize(P0);                       // camera -> surface (view)
    float cosI = alSaturate(dot(-I, Nv));

    // Schlick Fresnel, capped a touch below 1 so water never chromes out.
    float fres = AL_WATER_F0 + (1.0 - AL_WATER_F0) * pow(1.0 - cosI, 5.0);
    fres = min(alSaturate(fres), AL_WATER_REFLECT_MAX);

    // --- Reflection colour ---------------------------------------------------
    // Sky-access gate: water with no open sky above it (caves, covered flowing
    // water) must NOT reflect the sky — otherwise the bright horizon band shows in
    // the water underground (field report). Fade the sky fallback to a dark cave
    // reflection as the water's sky lightmap falls.
    float wSkyLm  = alSaturate(texture(colortex2, texcoord).a);
    float skyGate = smoothstep(0.0, 0.35, wSkyLm);
    vec3 Rv = reflect(I, Nv);
    vec3 Rw = normalize(alViewDirToWorld(Rv));
    vec3 refl = mix(vec3(0.015, 0.020, 0.035), alSkySample(Rw), skyGate);  // fallback

#ifdef SSR
    // R2 low-discrepancy dither on the noisetex value, advanced by frameCounter.
    vec2 noiseUV = gl_FragCoord.xy / 256.0;        // noisetex is 256x256
    float dither = texture(noisetex, noiseUV).r;
    dither = fract(dither + float(frameCounter) * 0.61803398875);

    vec2 hitUV;
    if (alTraceSSR(P0, Rv, dither, hitUV)) {
        vec3 hitCol = texture(colortex0, hitUV).rgb;
        // Fade the reflection to the sky sample near the screen edges (the march
        // has no data past them) so reflections don't clip hard.
        vec2 e = smoothstep(vec2(0.0), vec2(AL_SSR_EDGE_FADE), hitUV)
               * (1.0 - smoothstep(vec2(1.0 - AL_SSR_EDGE_FADE), vec2(1.0), hitUV));
        float edgeFade = e.x * e.y;
        bool okHit = all(greaterThanEqual(hitCol, vec3(0.0)))
                  && all(lessThan(hitCol, vec3(65000.0)));
        refl = mix(refl, okHit ? hitCol : refl, edgeFade);
    }
#endif

    // --- Absorption + caustics on the submerged scene ------------------------
    vec3  transmitted = base;
    float d1 = texture(depthtex1, texcoord).r;
    float skyLm = alSaturate(texture(colortex2, texcoord).a);

    if (d1 > d0 && d1 < 1.0) {
        vec3 P1 = alScreenToView(texcoord, d1);
        float waterPath = max(alEyeZ(P1) - alEyeZ(P0), 0.0);   // metres through water

        // Beer-Lambert green-blue tint over the path length.
        vec3 absorb = exp(-AL_WATER_ABSORB * (waterPath * AL_WATER_ABSORB_SCALE));

#ifdef WATER_CAUSTICS
        vec3  sunDir = alSunDirWorld();
        float dayF   = alSmooth(smoothstep(-0.06, 0.16, sunDir.y));   // == alDayFactor
        vec3  wposB  = alViewToPlayer(P1) + cameraPosition;
        float caus   = alWaterCaustic(wposB, sunDir, frameTimeCounter * AL_CAUSTIC_SPEED);
        float dfade  = exp(-waterPath / AL_CAUSTIC_DEPTH_FADE);       // shallow -> strong
        float gate   = skyLm * dayF * dfade;
        float cmod   = 1.0 + AL_CAUSTIC_STRENGTH * (caus * 2.0 - 1.0) * gate;
        absorb *= max(cmod, 0.0);
#endif

        // Weight by (1 - Fresnel): depth tint fades into the reflection at grazing.
        transmitted = base * mix(vec3(1.0), absorb, 1.0 - fres);
    }

    // Reflection over the (absorbed) water colour.
    vec3 result = mix(transmitted, refl, fres);

    // NaN-law: any non-finite channel -> fall back to the untouched scene.
    bool ok = all(greaterThanEqual(result, vec3(0.0)));
    outColor = vec4(ok ? min(result, vec3(65000.0)) : base, 1.0);
}
