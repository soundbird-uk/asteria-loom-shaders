#version 330 compatibility
#include "/settings.glsl"

/*
 composite3 (vertex) — fullscreen TAA-resolve pass. Plain screen-quad; no
 jitter here (jitter is applied only to the gbuffers geometry passes).
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
