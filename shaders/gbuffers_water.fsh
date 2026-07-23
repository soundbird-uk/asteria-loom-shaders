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
    pass to reflect + depth-tint (RENDERTARGETS: 0,2,3 — see the directive
    below the includes):
       colortex0 = forward-lit water colour (blended)
       colortex2 = octahedral ripple normal .rg + lightmap .ba (SAME encoding as
                   opaques, lib/encoding.glsl) — this is what SSR reflects off
       colortex3 = matID WATER (+ flags) — the composite pass's water mask

    WHY THIS IS SAFE (documented per contract §3): the deferred lighting pass
    (deferred1) has ALREADY consumed the opaque G-buffer for THIS frame before
    any translucent draws, so overwriting colortex2/3 for translucent pixels here
    does not corrupt opaque shading. Later fullscreen passes that read colortex2/3
    (fog's sky-lightmap gate, TAA) then see the translucent surface's normal/
    lightmap, which is fine for those effects.

    NON-WATER TRANSLUCENTS (stained glass, ice, slime, honey, nether portal) ALSO
    draw through this program (Iris routes ALL translucent terrain here — the
    terrain fallback applies only when the program is absent). They are
    discriminated via mc_Entity (block.properties, sentinel ID 10001) into the
    `isWater` varying and take the else-branch: their own colour/alpha, geometric
    normal, and matID AL_MATID_TRANSLUCENT — so the composite pass gives them NO
    SSR / absorption / caustics.

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
flat in float isWater;   // 1 = real water, 0 = other translucent (glass/ice/...)

/* RENDERTARGETS: 0,2,3 */
layout(location = 0) out vec4 outColor;      // colortex0 (blended lit surface)
layout(location = 1) out vec4 outNormalLm;   // colortex2 (surface normal + lm)
layout(location = 2) out vec4 outMaterial;   // colortex3 (matID)

/*
 CRITICAL (MAJOR-1/2 review fixes):
   * ALL translucent terrain (stained glass, ice, slime, honey, nether portal)
     routes through THIS program in Iris. Only mc_Entity.x == 10001 (isWater=1,
     mapped in block.properties) is treated as water — everything else keeps its
     own texture colour/alpha, its geometric normal, and a NON-water matID, so
     the composite pass never SSR/absorb/caustic-treats glass or ice.
   * colortex2/3 here are the aux draw buffers of an MRT whose colortex0 target
     is alpha-blended. Vanilla blend state applies to EVERY MRT target, which
     would corrupt the matID (alpha*encode decodes to the wrong ID at low alpha)
     and blend octahedral normals into garbage. shaders.properties therefore
     sets `blend.gbuffers_water.1 = off` and `.2 = off`, making these two writes
     AUTHORITATIVE OVERWRITES (colortex0 keeps blending). Both branches below
     write fully-formed values because they now land verbatim.
*/
void main() {
    vec4 tex = texture(gtexture, texcoord) * glcolor;

    vec3  Ng = normalize(wnormal);
    vec3  wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3  wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    if (isWater > 0.5) {
        // ================= REAL WATER =================
        // Biome water colour comes through glcolor. Decode to linear, apply a
        // gentle cool blue-green deepening for the dreamy identity.
        vec3 albedoLin = alSrgbToLinear(tex.rgb) * vec3(0.55, 0.80, 0.90);

        // --- Ripple normal ---
        vec3 N = Ng;
#ifdef WATER_WAVES
        // Only perturb near-horizontal surfaces (the vast majority of water);
        // the detail normal is in a world Y-up frame, flipped for undersides.
        if (abs(Ng.y) > 0.5) {
            vec3 worldPos = playerPos + cameraPosition;
            // length(playerPos) = camera-relative distance -> fades the micro
            // detail layer with range (anti-sparkle; see lib/water.glsl).
            vec3 nd = alWaterWaveNormal(worldPos, frameTimeCounter,
                                        AL_WATER_WAVE_AMP, length(playerPos));
            nd.y *= sign(Ng.y);
            N = normalize(nd);
        }
#endif
        // --- Fresnel-driven opacity ---
        vec3  Vw   = normalize(-playerPos);
        float cosV = alSaturate(dot(Vw, N));
        float fres = AL_WATER_F0 + (1.0 - AL_WATER_F0) * pow(1.0 - cosV, 5.0);
        // More transparent looking down (low Fresnel), opaque at grazing.
        float alpha = mix(AL_WATER_ALPHA_MIN, AL_WATER_ALPHA_MAX, alSaturate(fres));
        alpha *= tex.a;   // keep vanilla water density

        float NdotL = max(dot(N, wLightDir), 0.0);
        float shadowVis = alShadowVisibility(playerPos, N, NdotL);
        vec3 color = alLightPhase1(albedoLin, N, lmcoord, shadowVis, wLightDir,
                                   wSunDir, playerPos + cameraPosition, dayFactor);

        outColor    = vec4(color, alpha);
        outNormalLm = vec4(alEncodeNormal(N), lmcoord);      // ripple normal
        outMaterial = vec4(alEncodeMatID(AL_MATID_WATER),
                           alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
    } else {
        // ============ OTHER TRANSLUCENT (glass / ice / slime / honey / ...) ===
        // 0.3.x behaviour: own texture colour + alpha (NO blue-green tint, NO
        // Fresnel remap, NO waves), forward-lit with the shared model, own
        // geometric normal + lightmap, and a NON-water matID so composite skips
        // it. Alpha-test is not needed here (translucents blend, not cutout).
        vec3 albedoLin = alSrgbToLinear(tex.rgb);

        float NdotL = max(dot(Ng, wLightDir), 0.0);
        float shadowVis = alShadowVisibility(playerPos, Ng, NdotL);
        vec3 color = alLightPhase1(albedoLin, Ng, lmcoord, shadowVis, wLightDir,
                                   wSunDir, playerPos + cameraPosition, dayFactor);

        outColor    = vec4(color, tex.a);                    // keep glass colour+alpha
        outNormalLm = vec4(alEncodeNormal(Ng), lmcoord);     // geometric normal
        outMaterial = vec4(alEncodeMatID(AL_MATID_TRANSLUCENT),
                           alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
    }
}
