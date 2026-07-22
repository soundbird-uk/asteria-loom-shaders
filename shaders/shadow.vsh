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

out vec2 texcoord;
out vec4 glcolor;

void main() {
    vec4 pos = ftransform();          // shadow clip space
    // Distort in NDC (perspective-divide-safe; shadow ortho has w == 1).
    pos.xyz /= pos.w;
    pos.xyz  = alShadowDistort(pos.xyz);
    pos.xyz *= pos.w;
    gl_Position = pos;

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor  = gl_Color;
}
