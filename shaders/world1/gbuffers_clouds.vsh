#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_clouds (vertex) — vanilla clouds, simple forward-lit. Phase 3
 replaces these with volumetric clouds. The whole pass is gated by
 VANILLA_CLOUDS via `program.gbuffers_clouds.enabled` in shaders.properties.
*/

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();
    gl_Position = alJitter(gl_Position);   // TAA sub-pixel jitter — LAST gl_Position write
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
}
