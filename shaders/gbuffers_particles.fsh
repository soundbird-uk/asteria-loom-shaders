#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/atmosphere_common.glsl"

/*
 gbuffers_particles (fragment) — FORWARD, NON-DIRECTIONALLY lit particles
 (walk/sprint dust, block-break crumbs, crit sparks, smoke, redstone, ...)
 blended into colortex0.

 WHY NOT THE FULL DIRECTIONAL MODEL (field bug 0.2.1):
 Particles are camera-facing billboards; their interpolated normal usually
 faces the CAMERA, not the sun. Running them through alLightPhase1 gave
 NdotL ~ 0 against the daytime sun, plus shadow-map + cloud-shadow occlusion,
 so walk/run dust rendered as near-BLACK quads that followed the player. The
 fix: light particles the way gbuffers_weather lights precipitation — purely
 by their lightmap, with the pack's colour identity but no view-dependent term.

 Model (ambient-style, non-directional):
   colour = albedo * ( skyAmbient + warmBlock + floor )
     skyAmbient = alAmbientColor(sun)          // pack cool ambient identity,
                  * (sky-lm^2 * AMBIENT_INTENSITY),  atmosphere day-scaled,
                  desaturated toward grey as sky exposure falls (no cave purple).
     warmBlock  = pack blocklight ramp/falloff (verbatim from lib/lighting.glsl)
                  driven by the block lightmap -> torch-lit puffs glow amber.
     floor      = AL_BOUNCE * BOUNCE_INTENSITY  // tiny lift, never pure black.
   NO NdotL, NO shadow-map sampling, NO cloud shadow. Reuses the sampler-free
   colour helpers (alAmbientColor / blocklight tint ramp) so particle tint stays
   consistent with the scene, but never calls the directional alLightPhase1.

 Sampler count: 1 (gtexture). No shadow samplers, no noisetex, no LUT.
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec3 sunPosition;           // view space; only for atmosphere day-scale
uniform mat4 gbufferModelViewInverse;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex = texture(gtexture, texcoord) * glcolor;
    if (tex.a < alphaTestRef) discard;      // keep cutout discard

    vec3 albedoLin = alSrgbToLinear(tex.rgb);

    // World-space sun direction feeds only the analytic day-scaling of the
    // ambient colour (pure math, sampler-free) — never a directional NdotL.
    vec3 wSunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);

    // --- Sky ambient (the cool fill) --------------------------------------
    vec3 skyCol = alAmbientColor(wSunDir);
    // Desaturate toward luminance-preserving grey as sky exposure falls, so
    // particles in caves / deep dark don't glow purple (matches lib ambient).
    float skySat = smoothstep(AL_AMBIENT_DESAT_LO, AL_AMBIENT_DESAT_HI, lmcoord.y);
    skyCol = mix(vec3(alLuminance(skyCol)), skyCol, skySat);
    float skyLm = lmcoord.y * lmcoord.y;                 // eased, as in lib
    vec3 ambient = skyCol * (skyLm * AMBIENT_INTENSITY);

    // --- Warm block light -------------------------------------------------
    // Same ramp / falloff shaping as lib/lighting.glsl so a torch-lit puff
    // matches the amber of the terrain around it.
    float bl     = lmcoord.x;
    float blCore = pow(bl, AL_BLOCKLIGHT_FALLOFF);
    float blTail = bl * bl;
    float blAmt  = mix(blCore, blTail, AL_BLOCKLIGHT_TAIL);
#ifdef BLOCKLIGHT_TINT
    vec3 blTint = mix(AL_TORCH_EMBER, AL_TORCH_CANDLE, bl);
#else
    vec3 blTint = AL_TORCH_TINT;
#endif
    vec3 block = blTint * (blAmt * AL_BLOCKLIGHT_BASE * BLOCKLIGHT_INTENSITY);

    // --- Small floor ------------------------------------------------------
    // The only light an unlit particle (deep cave, no torch) gets — never black.
    vec3 floorTerm = AL_BOUNCE * BOUNCE_INTENSITY;

    vec3 lightSum = ambient + block + floorTerm;
    outColor = vec4(albedoLin * lightSum, tex.a);
}
