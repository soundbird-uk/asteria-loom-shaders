#version 330 compatibility
#include "/settings.glsl"

/*
 composite (vertex) — fullscreen quad for the water-effects pass (SSR,
 absorption, caustics). Trivial fullscreen setup; all the work is in the
 fragment shader. This is a FULLSCREEN pass, so it carries NO TAA jitter (jitter
 is applied only to scene geometry vertex shaders).
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
