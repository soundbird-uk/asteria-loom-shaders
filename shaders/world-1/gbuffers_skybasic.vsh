#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_skybasic (vertex) — the vanilla sky dome / horizon / void / stars.
 We keep the vanilla geometry and pass a world-space view direction so the
 fragment stage can reproduce a simple vertical gradient. Star suppression is
 handled in the fragment stage via renderStage.
*/

uniform mat4 gbufferModelViewInverse;

out vec3 worldDir;

void main() {
    gl_Position = ftransform();
    gl_Position = alJitter(gl_Position);   // TAA sub-pixel jitter — LAST gl_Position write
    vec3 viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    worldDir = mat3(gbufferModelViewInverse) * viewPos;
}
