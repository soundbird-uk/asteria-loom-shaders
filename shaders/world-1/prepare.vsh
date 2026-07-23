#version 330 compatibility
#include "/settings.glsl"

/*
 prepare (vertex) — fullscreen quad for the sky-view LUT bake. Iris supplies
 the quad; ftransform() places it and gl_MultiTexCoord0 carries 0..1 screen uv
 (unused by the fragment stage, which addresses the tile by gl_FragCoord).
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
