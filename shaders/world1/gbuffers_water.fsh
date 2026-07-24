#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"
// deep swirling nether portal (bare include line — flattener needs no trailing text)
#include "/lib/water.glsl"
#include "/lib/portal.glsl"

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
in vec2 waterRefXZ;            // undisplaced world XZ — Gerstner rest position
in float waterShore;           // 0 shallow/calm shore .. 1 deep/rough open water
flat in float isWater;         // 1 = real water, 0 = other translucent (glass/ice/...)
flat in float isNetherPortal;  // 1 = nether portal (block.properties 10002)
flat in float isEndPortal;     // 1 = end portal / gateway (10003) — translucent-route fallback
flat in float isIce;           // 1 = regular translucent ice (10052) — glassy SSR reflection

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
    // NETHER PORTAL: a deep swirling violet portal with an emissive glow and a
    // Fresnel edge sheen (lib/portal.glsl) — replaces the flat vanilla swirl.
    // Detected via mc_Entity (block.properties 10002). Tagged TRANSLUCENT so the
    // composite water pass leaves it alone.
    if (isNetherPortal > 0.5) {
        vec3  N   = normalize(wnormal);
        vec3  Vw  = normalize(-playerPos);
        vec3  wp  = playerPos + cameraPosition;
        vec3  up0 = (abs(N.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3  tang = normalize(cross(up0, N));
        vec3  bit  = cross(N, tang);
        vec2  pc  = vec2(dot(wp, tang), dot(wp, bit));
        vec2  par = vec2(dot(Vw, tang), dot(Vw, bit));
        float fres = pow(1.0 - abs(dot(Vw, N)), 4.0);
        vec4  pcol = alNetherPortal(pc, par, fres, frameTimeCounter);
        outColor    = pcol;
        outNormalLm = vec4(alEncodeNormal(N), lmcoord);
        // colortex3.b = reflectivity so the composite SSR pass gives the portal
        // water-like reflections (dielectric, metalness 0).
        outMaterial = vec4(alEncodeMatID(AL_MATID_TRANSLUCENT),
                           alEncodeFlags(AL_FLAG_NONE), AL_NETHER_PORTAL_REFLECT, 0.0);
        return;
    }

    // END PORTAL / GATEWAY (block.properties 10003): a FALLBACK render in case
    // Iris routes the end portal through the translucent (water) program rather
    // than gbuffers_block. Paint the same 3D parallax starfield (lib/portal.glsl)
    // so it is never flat black. Tagged TRANSLUCENT so composite leaves it alone.
    if (isEndPortal > 0.5) {
        vec3  N   = normalize(wnormal);
        vec3  Vw  = normalize(-playerPos);
        vec3  wp  = playerPos + cameraPosition;
        vec3  up0 = (abs(N.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3  tang = normalize(cross(up0, N));
        vec3  bit  = cross(N, tang);
        vec2  pc  = vec2(dot(wp, tang), dot(wp, bit));
        vec2  par = vec2(dot(Vw, tang), dot(Vw, bit));
        vec3  star = alEndPortal(pc, par, frameTimeCounter);
        outColor    = vec4(star, 1.0);
        outNormalLm = vec4(alEncodeNormal(N), lmcoord);
        outMaterial = vec4(alEncodeMatID(AL_MATID_TRANSLUCENT),
                           alEncodeFlags(AL_FLAG_NONE), AL_END_PORTAL_REFLECT, 0.0);
        return;
    }

    vec4 tex = texture(gtexture, texcoord) * glcolor;

    vec3  Ng = normalize(wnormal);
    vec3  wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3  wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    if (isWater > 0.5) {
        // ================= REAL WATER =================
        // ISSUE 11 ("vanilla scrolling texture still visible"): do NOT sample the
        // animated vanilla water atlas into the albedo — that is what made the
        // tiled scrolling pattern show through. Use the pack's shader-driven
        // deep-water identity (AL_WATER_TINT) as the surface colour, nudged gently
        // toward the biome hue in glcolor so swamp/warm waters still read. The look
        // is then defined by reflection + depth absorption (composite), i.e. a real
        // shader water surface, not the scrolling atlas.
        vec3 biomeLin  = alSrgbToLinear(glcolor.rgb);
        vec3 albedoLin = AL_WATER_TINT * mix(vec3(1.0), biomeLin * 3.0, 0.30);

        // --- Gerstner surface normal (per-fragment) + micro-ripples + foam ----
        vec3  N   = Ng;
        float crestFoam = 0.0;
#ifdef WATER_WAVES
        // Only shade near-horizontal water (the vast majority); the wave frame is
        // world Y-up, flipped for undersides.
        if (abs(Ng.y) > 0.5) {
            float dist = length(playerPos);
            // Analytic Gerstner normal + Jacobian at the UNDISPLACED rest position.
            // shoreFactor attenuates big swells near land (fine ripples preserved).
            vec3  gN; float jac;
            alGerstnerSurface(waterRefXZ, frameTimeCounter, 1.0, waterShore, gN, jac);
            // Domain-warped 3D-simplex micro-ripples (fade out with range).
            float microAmt = alSaturate(1.0 - dist / AL_WATER_MICRO_FADE);
            vec3  mN = alWaterMicroNormal(waterRefXZ, frameTimeCounter, microAmt);
            N = alBlendNormals(gN, mN);
            // ANTI-SPARKLE: fade the normal toward flat with distance so far crests
            // don't alias into shimmer (helps FXAA especially; TAA is off by default).
            float flatAmt = smoothstep(AL_WATER_NORMAL_FADE_A, AL_WATER_NORMAL_FADE_B, dist)
                          * AL_WATER_NORMAL_MAXFLAT;
            N = normalize(mix(N, vec3(0.0, 1.0, 0.0), flatAmt));
            if (Ng.y < 0.0) N.y = -N.y;                // undersides
            N = normalize(N);
#ifdef WATER_FOAM
            // JACOBIAN CREST FOAM: the horizontal-displacement Jacobian folds
            // negative where crests pinch/overhang -> whitecap foam there.
            crestFoam = 1.0 - smoothstep(AL_WATER_FOAM_JAC_LO, AL_WATER_FOAM_JAC_HI, jac);
            crestFoam *= microAmt;                     // fade the fine foam with range
            // WHISPY FRACTAL breakup: modulate by a domain-warped noise so crest foam
            // reads as chaotic whiskers, not a smooth uniform cap.
            crestFoam *= 0.15 + 0.85 * alWaterFoamNoise(waterRefXZ, frameTimeCounter);
#endif
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

        // Crest foam: lit with the SAME lighting model as the water (foam albedo),
        // so it darkens to moonlit grey at night instead of glowing white (field
        // report). Only computed where foam actually is.
        if (crestFoam > 0.001) {
            vec3 foamLit = alLightPhase1(AL_WATER_FOAM_COLOR, N, lmcoord, shadowVis,
                                         wLightDir, wSunDir, playerPos + cameraPosition,
                                         dayFactor);
            color = mix(color, foamLit, crestFoam);
            alpha = mix(alpha, 1.0, crestFoam);
        }

        outColor    = vec4(color, alpha);
        outNormalLm = vec4(alEncodeNormal(N), lmcoord);      // Gerstner+micro normal
        // colortex3.b carries the crest-foam amount so the composite pass can keep
        // foam matte (skip SSR/absorption there); .a spare.
        outMaterial = vec4(alEncodeMatID(AL_MATID_WATER),
                           alEncodeFlags(AL_FLAG_NONE), crestFoam, 0.0);
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
        // Regular ice gets a glassy reflectivity in colortex3.b so the composite
        // SSR pass reflects it (material-dependent, dielectric); plain glass keeps 0.
        float iceRefl = (isIce > 0.5) ? AL_REFLECT_ICE : 0.0;
        outMaterial = vec4(alEncodeMatID(AL_MATID_TRANSLUCENT),
                           alEncodeFlags(AL_FLAG_NONE), iceRefl, 0.0);
    }
}
