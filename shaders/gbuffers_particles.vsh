#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_particles (vertex) — opaque particle path (smoke, crit sparks...).
 Standard opaque G-buffer vertex path. Particles are camera-facing quads;
 the interpolated normal is whatever vanilla supplies (fine for Phase 1).
*/

uniform mat4 gbufferModelViewInverse;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;

void main() {
    gl_Position = ftransform();
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
}
