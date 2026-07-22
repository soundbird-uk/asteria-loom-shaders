#version 330 compatibility
#include "/settings.glsl"

/*
 composite (vertex) — fullscreen pass.
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
