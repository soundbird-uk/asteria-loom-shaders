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

/*
 -------------------------------------------------------------------------
 PREVIOUS-FRAME reprojection (for temporal accumulation — GTAO history).
 -------------------------------------------------------------------------
 To find where THIS frame's surface point sat on the PREVIOUS frame's screen
 we must re-express its position in the previous frame's player (feet) space.
 Player space is camera-relative, so a world-static point shifts by the camera
 delta (cameraPosition - previousCameraPosition) between frames. We then apply
 the PREVIOUS frame's model-view + projection (Iris' gbufferPrevious* matrices)
 to land in previous-frame clip space. These uniforms are declared here so any
 fullscreen pass that reprojects gets them for free (declaring an unused uniform
 is harmless — Iris still supplies it, glslang ignores it).
*/
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

// Current-frame player-space position -> previous-frame VIEW space.
vec3 alPlayerToPrevView(vec3 playerPos) {
    vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
    return (gbufferPreviousModelView * vec4(prevPlayer, 1.0)).xyz;
}

// Previous-frame view-space position -> previous-frame screen space.
// Returns vec3(uv.xy, ndcDepth), all in [0,1] when the point is on-screen and
// in front of the previous camera (caller checks the range for validity).
vec3 alPrevViewToScreen(vec3 prevView) {
    vec4 clip = gbufferPreviousProjection * vec4(prevView, 1.0);
    vec3 ndc  = clip.xyz / clip.w;
    return ndc * 0.5 + 0.5;
}

// Linear eye-space depth (positive distance in front of the camera) from a
// view-space position. No near/far needed — it is just -z. Shared convention
// for the AO history's stored depth (colortex5.b) and its reprojection test.
float alLinearEyeDepth(vec3 viewPos) {
    return -viewPos.z;
}

#endif // AL_LIB_SPACE
