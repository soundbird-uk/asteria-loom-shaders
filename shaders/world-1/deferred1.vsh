#version 330 compatibility
#include "/settings.glsl"

/*
 deferred (vertex) — fullscreen pass. Iris supplies the fullscreen quad;
 ftransform() places it and gl_MultiTexCoord0 carries 0..1 screen uv.
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
