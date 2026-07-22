#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_weather (vertex) — rain and snow particles. Simple lightmap-lit
 forward pass; kept faint so precipitation reads as atmosphere, not confetti.
*/

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
}
