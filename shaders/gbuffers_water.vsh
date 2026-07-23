#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_water (vertex) — Phase 4 real water. Forward-lit AND (new) surface
 data for the SSR/absorption composite pass. We forward everything the shared
 lighting model needs plus the player-space position, which the fragment stage
 turns into a world position for the procedural ripple wave-noise. The last
 position line applies the TAA sub-pixel jitter (lib/jitter.glsl, identity when
 TAA is off) — water must jitter with every other jittered gbuffer or it
 shimmers against the resolved scene.
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

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;

    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
    playerPos = (gbufferModelViewInverse * viewPos).xyz;

    gl_Position = alJitter(gl_Position);   // TAA jitter (identity when TAA off)
}
