#version 330 compatibility
#include "/settings.glsl"

/*
 composite12 (vertex) — fullscreen pass (bloom upsample U3).
 Trivial fullscreen setup; all bloom work is in the fragment shader.
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
