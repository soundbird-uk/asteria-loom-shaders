#version 330 compatibility
#include "/settings.glsl"

/*
 deferred (vertex) — fullscreen GTAO pass. Iris supplies the fullscreen quad;
 ftransform() places it and gl_MultiTexCoord0 carries 0..1 screen uv.

 (Phase 1's deferred lighting pass is now deferred1; this deferred slot holds
 the horizon-based AO + temporal-accumulation pass — see deferred.fsh.)
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
