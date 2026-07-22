#ifndef AL_LIB_SPACE
#define AL_LIB_SPACE

/*
 lib/space.glsl — coordinate-space transforms for fullscreen passes.
 Screen (uv+depth) -> view -> player/world. This file OWNS the inverse
 matrices it needs, so any fullscreen fragment program that includes it must
 NOT redeclare them (avoids duplicate-uniform errors). Gbuffers vertex
 shaders that only need gbufferModelViewInverse declare it themselves and do
 not include this file.
*/

#include "/lib/common.glsl"

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;

// Screen-space (uv in [0,1], hardware depth in [0,1]) -> view space.
vec3 alScreenToView(vec2 uv, float depth) {
    vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
    vec4 clip = vec4(ndc, 1.0);
    vec4 view = gbufferProjectionInverse * clip;
    return view.xyz / view.w;
}

// View space -> player space (world position relative to the camera / feet).
// This is the space Iris' shadow matrices operate in.
vec3 alViewToPlayer(vec3 viewPos) {
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

// Direction only (ignores translation) view -> world.
vec3 alViewDirToWorld(vec3 v) {
    return mat3(gbufferModelViewInverse) * v;
}

#endif // AL_LIB_SPACE
