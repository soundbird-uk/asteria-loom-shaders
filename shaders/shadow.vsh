#version 330 compatibility
#include "/settings.glsl"

/*
 shadow (vertex) — depth-only render from the sun/moon's point of view.
 Phase 1 is a PLAIN shadow map: gl_Position = ftransform() with NO distortion
 warp. Phase 2 adds the warp here (concentrating resolution near the camera)
 and in lib/shadow.glsl's sampling — keeping both in lockstep. We forward the
 atlas uv and vertex colour purely so the fragment stage can do cutout alpha.
*/

out vec2 texcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor  = gl_Color;
}
