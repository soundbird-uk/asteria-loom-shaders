#version 330 compatibility
#include "/settings.glsl"

/*
 composite1 (vertex) — fullscreen pass (aerial-perspective fog).
 Same trivial fullscreen setup as composite.vsh; the fog work is all in the
 fragment shader.
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
