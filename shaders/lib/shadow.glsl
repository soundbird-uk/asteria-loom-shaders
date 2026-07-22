#ifndef AL_LIB_SHADOW
#define AL_LIB_SHADOW

/*
 lib/shadow.glsl — provisional shadow sampling (Phase 1).

 Deliberately minimal per the Phase-1 contract: a plain 2048 shadow map,
 single or 2x2 tap of shadowtex1, with normal-offset + slope-scaled depth
 bias. NO distortion warp, NO PCSS — those are Phase 2 and slot in HERE so
 the rest of the pipeline never has to change. All shadow-space math is
 isolated in this file.

 The shadow uniforms/sampler are declared INSIDE the SHADOWS guard so a
 program that compiles with shadows off never even declares shadowtex1
 (keeps the fragment sampler budget honest).

 Convention: caller passes PLAYER-space position (world-relative-to-camera),
 the same space Iris' shadowModelView expects.
*/

#include "/lib/common.glsl"

#ifdef SHADOWS
uniform sampler2D shadowtex1;      // depth of everything (opaque + translucent)
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
#endif

/*
 Returns direct-light visibility in [0,1]. 1.0 = fully lit.
 With SHADOWS off this compiles to a constant 1.0 (no sampler declared).

   playerPos : world position relative to camera (player/feet space)
   worldN    : world-space geometric normal (for the normal offset)
   NdotL     : clamped N.L (drives slope-scaled bias + offset growth)
*/
float alShadowVisibility(vec3 playerPos, vec3 worldN, float NdotL) {
#ifdef SHADOWS
    // Normal offset: push the sample point along the surface normal to fight
    // acne. Scale by one shadow texel in world units and grow at grazing
    // angles where the projected footprint is largest. The ortho shadow
    // projection spans ±shadowDistance, so the map covers 2*shadowDistance
    // world units across shadowMapResolution texels -> the factor 2 matters.
    float texelWorld = 2.0 * shadowDistance / float(shadowMapResolution);
    float offset = texelWorld * (0.85 + (1.0 - NdotL) * 2.5);
    vec3 samplePos = playerPos + worldN * offset;

    vec4 shadowClip = shadowProjection * shadowModelView * vec4(samplePos, 1.0);
    vec3 sc = shadowClip.xyz / shadowClip.w;   // NDC [-1,1]
    sc = sc * 0.5 + 0.5;                        // -> [0,1]

    // Outside the shadow map (or behind near plane) -> treat as fully lit so
    // distant terrain is never wrongly darkened.
    if (sc.x <= 0.0 || sc.x >= 1.0 || sc.y <= 0.0 || sc.y >= 1.0 || sc.z >= 1.0) {
        return 1.0;
    }

    // Slope-scaled depth bias: larger where the surface faces away from the
    // light (grazing) and the depth gradient across a texel is steep.
    float bias = mix(0.00035, 0.0022, 1.0 - NdotL);
    float refDepth = sc.z - bias;

    #ifdef SHADOW_FILTER
        // Cheap 2x2 tap (4 samples) for softened edges.
        float texel = 1.0 / float(shadowMapResolution);
        float sum = 0.0;
        for (int x = 0; x < 2; x++) {
            for (int y = 0; y < 2; y++) {
                vec2 o = (vec2(float(x), float(y)) - 0.5) * texel;
                float d = texture(shadowtex1, sc.xy + o).r;
                sum += step(refDepth, d);
            }
        }
        return sum * 0.25;
    #else
        // Single hard tap (cheapest).
        float d = texture(shadowtex1, sc.xy).r;
        return step(refDepth, d);
    #endif
#else
    return 1.0;
#endif
}

#endif // AL_LIB_SHADOW
