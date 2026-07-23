#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_basic (vertex) — untextured geometry: the block selection outline,
 hitboxes, leash/fishing lines. No atlas texture; colour comes from gl_Color.
 These primitives often have degenerate normals (lines), so we hand the
 fragment stage a fixed up-normal rather than a garbage one.
*/

out vec2 lmcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();
    gl_Position = alJitter(gl_Position);   // TAA sub-pixel jitter — LAST gl_Position write
    lmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor = gl_Color;
}
