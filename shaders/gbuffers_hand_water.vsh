#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_hand_water (vertex) — translucent held items (potions, stained
 glass in hand, water bucket contents). Same forward-lit path as water, kept
 MINIMAL: no G-buffer surface write (RENDERTARGETS: 0 only in the fsh) — held
 items get no SSR — just the shared forward lighting. The last position line
 applies the TAA sub-pixel jitter (identity when TAA is off) so the hand moves
 with the rest of the jittered scene and does not shimmer.
*/

uniform mat4 gbufferModelViewInverse;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
out vec3 playerPos;

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    gl_Position = gl_ProjectionMatrix * viewPos;

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;

    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
    playerPos = (gbufferModelViewInverse * viewPos).xyz;

    gl_Position = alJitter(gl_Position);   // TAA jitter (identity when TAA off)
}
