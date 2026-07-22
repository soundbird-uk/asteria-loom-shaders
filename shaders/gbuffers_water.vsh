#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_water (vertex) — translucent water, forward-lit. Phase 1 is plain
 vanilla-texture water, slightly tinted and transparent; real water (SSR,
 caustics, ripples) is Phase 4. We forward everything the shared lighting
 model needs, plus player-space position for shadow sampling.
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
}
