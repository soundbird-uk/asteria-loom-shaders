#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"
#include "/lib/water.glsl"

/*
 gbuffers_water (fragment) — Phase 4 real water. Two jobs:

 1. FORWARD SHADE the water surface (blended over the already-lit opaque scene
    in colortex0) with the SAME lighting model as the deferred opaque pass, so
    water matches its surroundings. Procedural wind-aligned ripple normals
    (lib/water.glsl, pure math) perturb the surface; Fresnel drives the opacity
    (near-transparent looking straight down, opaque at grazing); the biome water
    colour comes through glcolor (vanilla carries the biome tint in the vertex
    colour).

 2. WRITE THE WATER SURFACE INTO THE G-BUFFER for the new `composite` water
    pass to reflect + depth-tint:
       /* RENDERTARGETS: 0,2,3 */
       colortex0 = forward-lit water colour (blended)
       colortex2 = octahedral ripple normal .rg + lightmap .ba (SAME encoding as
                   opaques, lib/encoding.glsl) — this is what SSR reflects off
       colortex3 = matID WATER (+ flags) — the composite pass's water mask

    WHY THIS IS SAFE (documented per contract §3): the deferred lighting pass
    (deferred1) has ALREADY consumed the opaque G-buffer for THIS frame before
    any translucent draws, so overwriting colortex2/3 for water pixels here does
    not corrupt opaque shading. Later fullscreen passes that read colortex2/3
    (fog's sky-lightmap gate, TAA) then see the WATER surface's normal/lightmap
    at water pixels, which is correct for those effects. Non-water translucents
    (ice, stained glass) keep the terrain fallback path and never reach here, so
    their matID stays non-water and they get no SSR this phase.

 Sampler count: gtexture + shadow samplers via lib/shadow.glsl (SHADOWS):
   Mac fallback = 3 (gtexture, shadowtex1, noisetex);
   hardware-flag = 4 (gtexture, shadowtex0, shadowtex1HW, noisetex). <=4 budget.
   (The ripple + Fresnel maths add ZERO samplers — pure math.)
*/

uniform sampler2D gtexture;
uniform vec3 sunPosition;          // view space
uniform vec3 shadowLightPosition;  // view space, toward dominant light
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;       // world-space camera (waves + cloud shadow)
// frameTimeCounter comes from lib/clouds_common.glsl (pulled in by lighting).

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
in vec3 playerPos;

/* RENDERTARGETS: 0,2,3 */
layout(location = 0) out vec4 outColor;      // colortex0 (blended lit water)
layout(location = 1) out vec4 outNormalLm;   // colortex2 (ripple normal + lm)
layout(location = 2) out vec4 outMaterial;   // colortex3 (matID WATER)

void main() {
    vec4 tex = texture(gtexture, texcoord) * glcolor;

    // Biome water colour comes through glcolor. Decode to linear, apply a gentle
    // cool blue-green deepening for the dreamy identity.
    vec3 albedoLin = alSrgbToLinear(tex.rgb) * vec3(0.55, 0.80, 0.90);

    // --- Ripple normal --------------------------------------------------------
    vec3 Ng = normalize(wnormal);
    vec3 N  = Ng;
#ifdef WATER_WAVES
    // Only perturb near-horizontal surfaces (the vast majority of water); the
    // detail normal is computed in a world Y-up frame, flipped for undersides.
    if (abs(Ng.y) > 0.5) {
        vec3 worldPos = playerPos + cameraPosition;
        vec3 nd = alWaterWaveNormal(worldPos, frameTimeCounter, AL_WATER_WAVE_AMP);
        nd.y *= sign(Ng.y);
        N = normalize(nd);
    }
#endif

    // --- Fresnel-driven opacity ----------------------------------------------
    // View direction toward the camera in world space. cos small at grazing.
    vec3  Vw    = normalize(-playerPos);
    float cosV  = alSaturate(dot(Vw, N));
    float fres  = AL_WATER_F0 + (1.0 - AL_WATER_F0) * pow(1.0 - cosV, 5.0);
    // More transparent looking down (low Fresnel), more opaque at grazing.
    float alpha = mix(AL_WATER_ALPHA_MIN, AL_WATER_ALPHA_MAX, alSaturate(fres));
    alpha *= tex.a;   // keep vanilla water density

    // --- Forward lighting (shared model) -------------------------------------
    vec3 wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3 wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    float NdotL = max(dot(N, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, N, NdotL);

    vec3 color = alLightPhase1(albedoLin, N, lmcoord, shadowVis, wLightDir, wSunDir,
                               playerPos + cameraPosition, dayFactor);

    outColor = vec4(color, alpha);

    // --- G-buffer surface data for the composite water pass ------------------
    outNormalLm = vec4(alEncodeNormal(N), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_WATER),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
