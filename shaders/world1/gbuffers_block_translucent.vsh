#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_block_translucent (vertex) — the TRANSLUCENT half of block-entity
 rendering: sign TEXT glyphs, banner PATTERN layers, and other translucent
 block-entity decals. Iris renders these AFTER the deferred pass (the G-buffer is
 dead by then), so this is a FORWARD-LIT program that writes colortex0.

 WHY THIS PROGRAM EXISTS (field: "banners white, sign text missing"): without a
 gbuffers_block_translucent, Iris falls translucent block-entity draws back to the
 OPAQUE gbuffers_block, where the layered pattern / glyph quads get alpha-tested
 away (so a banner shows only its white base cloth and sign text vanishes). Adding
 this program routes them to a proper blended forward pass instead.
*/

uniform mat4 gbufferModelViewInverse;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
out vec3 playerPos;

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
}
