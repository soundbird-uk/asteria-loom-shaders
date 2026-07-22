#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_entities_translucent (vertex) — the translucent half of entity
 rendering (slime outer shell, enderman-eye overlay, entity shadow blobs,
 nametag backgrounds, ...).

 With `separateEntityDraws = true`, Iris routes these draws to the
 POST-deferred phase and dispatches THIS program (the *_translucent split).
 The G-buffer is dead by then, so this is FORWARD-LIT and writes colortex0.
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
