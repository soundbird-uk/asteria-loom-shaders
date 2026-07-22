#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_terrain (vertex) — opaque solid/cutout terrain.
 Writes the G-buffer only; no lighting here (deferred does that).
 mc_Entity is declared per the contract so Phase-2+ can branch on block IDs;
 Phase 1 has no block.properties, so terrain simply uses the default matID 0.
*/

uniform mat4 gbufferModelViewInverse;

in vec4 mc_Entity;   // (blockId, renderType, ...) — reserved for later phases

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;

void main() {
    gl_Position = ftransform();

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;   // atlas uv
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;   // lightmap 0..1
    glcolor  = gl_Color;                                       // vertex colour (+vanilla AO)

    // Normal to world space: view normal via gl_NormalMatrix, then rotate to
    // world with the modelview inverse (rotation part only).
    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
}
