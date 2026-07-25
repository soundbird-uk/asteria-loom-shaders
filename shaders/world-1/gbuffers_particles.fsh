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

 DEPTH OCCLUSION (5.4 field bug: particles drawn THROUGH water and blocks):
 `particles.ordering = after` moves this program into the post-deferred phase,
 where Iris rebinds the framebuffer for the forward colortex0 write. Particles
 that arrive there without a working depth test paint over geometry that is in
 front of them — block-break crumbs seen through the block, potion swirls
 floating on top of the water surface they are under.

 So the pass no longer TRUSTS the fixed-function depth test: it re-runs it in the
 fragment stage against the scene depth buffers and discards anything that lies
 behind the geometry already on screen:
   depthtex0 = ALL geometry, translucents included (this is what puts particles
               BEHIND a water surface — water depth exists only here);
   depthtex1 = OPAQUE-only geometry (this is what puts particles behind solid
               blocks even in the frames/orderings where depthtex0 has not yet
               received the translucent pass).
 Both are read with texelFetch at the fragment's own integer pixel, so there is
 no filtering, no half-texel offset and no viewWidth/viewHeight round-trip — the
 comparison is EXACTLY the one the hardware depth test would make, in the same
 non-linear [0,1] window-space Z, at highp. The test is `>` (strictly behind),
 never `>=`, so a particle exactly coplanar with the geometry it sits on (a
 crumb on a block face) still draws, and the redundant case (hardware test also
 working) produces an identical image.

 Sampler count: 3 (gtexture, depthtex0, depthtex1). No shadow samplers, no
 noisetex, no LUT.
*/

uniform sampler2D gtexture;
uniform sampler2D depthtex0;   // ALL geometry (translucents included: water)
uniform sampler2D depthtex1;   // opaque-only geometry
uniform float alphaTestRef;
uniform vec3 sunPosition;           // view space; only for atmosphere day-scale
uniform mat4 gbufferModelViewInverse;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // --- Manual depth occlusion (see header) ------------------------------
    // Window-space Z of this fragment vs the scene depth already on screen.
    // highp: at far distances the non-linear depth values differ in the last
    // few mantissa bits, and a mediump compare there would either leak
    // particles through distant geometry or cull ones that are in front.
    ivec2 px = ivec2(gl_FragCoord.xy);
    highp float sceneDepth = min(texelFetch(depthtex0, px, 0).r,
                                 texelFetch(depthtex1, px, 0).r);
    if (gl_FragCoord.z > sceneDepth) discard;   // strictly behind -> occluded

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
