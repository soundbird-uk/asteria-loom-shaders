#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_skytextured (vertex) — the sun and moon textures (and any custom
 sky textures). Simple textured pass; forwards uv and vertex colour.
*/

out vec2 texcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor  = gl_Color;
}
