#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_block (vertex) — block entities (chests, signs, banners, beds...).
 Standard opaque G-buffer vertex path.
*/

uniform mat4 gbufferModelViewInverse;

// End portal / gateway are BLOCK ENTITIES (TheEndPortalRenderer), so they are
// identified by the `blockEntityId` UNIFORM — NOT the mc_Entity vertex attribute
// (which is only populated for chunk-mesh blocks). block.properties maps
// `block.10003 = minecraft:end_portal minecraft:end_gateway`, which feeds BOTH
// mc_Entity (blocks) and blockEntityId (block entities); we read the latter here.
uniform int blockEntityId;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
out vec3 playerPos;             // for the end-portal parallax starfield
flat out float isEndPortal;     // 1.0 for end_portal / end_gateway

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    gl_Position = gl_ProjectionMatrix * viewPos;   // == ftransform()
    gl_Position = alJitter(gl_Position);   // TAA sub-pixel jitter — LAST gl_Position write
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
    playerPos = (gbufferModelViewInverse * viewPos).xyz;
    isEndPortal = (blockEntityId == 10003) ? 1.0 : 0.0;
}
