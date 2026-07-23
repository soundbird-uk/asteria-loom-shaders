#version 330 compatibility
#include "/settings.glsl"

/*
 shadow (vertex) — depth-only render from the sun/moon's point of view.

 Phase 2 applies the distortion WARP here so the rendered shadow map is stored
 pre-distorted, concentrating texels near the camera (see lib/shadow.glsl for
 the exact formula + derivation). The SAME alShadowDistort() is used by every
 lookup in lib/shadow.glsl, so the map and the samples always agree.

 We include lib/shadow.glsl only for the warp function; `AL_SHADOW_VSH` is
 defined first so the shadow-reading sampler block (shadowtex*, noisetex, ...)
 is NOT pulled into the shadow pass, which writes depth and reads none of them.

 texcoord/glcolor are forwarded purely so the fragment stage can cutout-alpha.
*/

#define AL_SHADOW_VSH
#include "/lib/shadow.glsl"
#ifdef AL_WAVING_FOLIAGE
#include "/lib/wind.glsl"
#endif

#ifdef AL_WAVING_FOLIAGE
uniform mat4  shadowModelViewInverse;  // shadow-view -> world (feet)
uniform vec3  cameraPosition;
uniform float frameTimeCounter;
in vec4 mc_Entity;
in vec3 at_midBlock;
#endif

out vec2 texcoord;
out vec4 glcolor;

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;   // shadow-view space

#ifdef AL_WAVING_FOLIAGE
    // Wave foliage in the shadow map with the SAME world-space displacement the
    // gbuffers pass uses, so grass/leaf shadows track the moving geometry (no
    // base flicker from a static shadow under a swaying blade).
    float isGrass = (mc_Entity.x == 10010.0) ? 1.0 : 0.0;
    float isLeaf  = (mc_Entity.x == 10020.0) ? 1.0 : 0.0;
    float amount  = isGrass * AL_WIND_GRASS + isLeaf * AL_WIND_LEAF;
    if (amount > 0.0) {
        vec3 worldPos = (shadowModelViewInverse * viewPos).xyz + cameraPosition;
        float topW = (isLeaf > 0.5)
                   ? 1.0
                   : alSaturate(-at_midBlock.y * (1.0 / 32.0));
        vec3 disp = alFoliageSway(worldPos, frameTimeCounter * AL_WIND_SPEED,
                                  amount, topW, isLeaf);
        viewPos.xyz += transpose(mat3(shadowModelViewInverse)) * disp;
    }
#endif

    vec4 pos = gl_ProjectionMatrix * viewPos;   // shadow clip space
    // Distort in NDC (perspective-divide-safe; shadow ortho has w == 1).
    pos.xyz /= pos.w;
    pos.xyz  = alShadowDistort(pos.xyz);
    pos.xyz *= pos.w;
    gl_Position = pos;

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor  = gl_Color;
}
