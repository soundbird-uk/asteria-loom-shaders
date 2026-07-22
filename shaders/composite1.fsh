#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/space.glsl"

/*
 composite1 (fragment) — aerial-perspective fog.

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
uniform sampler2D depthtex0;   // translucent-inclusive depth

// Weather (verified). rainStrength/wetness/thunderStrength drive density/tint.
uniform float rainStrength;
uniform float wetness;
uniform float thunderStrength;

// Camera state (verified). Skip fog when the eye is submerged (Phase 4 owns it).
uniform int   isEyeInWater;

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

void main() {
    vec3  scene = texture(colortex0, texcoord).rgb;
    float depth = texture(depthtex0, texcoord).r;

    // Sky (clouds carry their own transmittance) and underwater -> passthrough.
    if (depth >= 1.0 || isEyeInWater != 0) {
        outColor = vec4(scene, 1.0);
        return;
    }

    // Reconstruct the world-relative view ray from depth.
    vec3  viewPos   = alScreenToView(texcoord, depth);
    vec3  playerPos = alViewToPlayer(viewPos);          // world pos rel. camera
    float dist      = length(playerPos);
    vec3  worldDir  = (dist > 1.0e-4) ? playerPos / dist : vec3(0.0, 1.0, 0.0);

    // Sky-exposure gate input: raw sky lightmap (colortex2.a). Range-clamped so
    // a stray value can't push the smoothstep out of [0,1].
    float skyLm = alSaturate(texture(colortex2, texcoord).a);

    vec3 fogged = alApplyAerialFog(scene, cameraPosition.y, worldDir, dist,
                                   FOG_DENSITY, skyLm, biome_category,
                                   temperature, rainfall, rainStrength,
                                   wetness, thunderStrength);

    // Clamp the output (NaN-safe: a non-finite result falls back to the raw
    // scene rather than propagating).
    bool finite = (fogged.r >= 0.0 && fogged.g >= 0.0 && fogged.b >= 0.0);
    outColor = vec4(finite ? min(fogged, vec3(65000.0)) : scene, 1.0);
}
