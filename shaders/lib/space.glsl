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
/*
 PRECISION LAW FOR THE REPROJECTION PATH (macOS / Apple Silicon)
 -------------------------------------------------------------------------
 Two independent precision hazards live on this exact code path, and both
 show up as the SAME symptom: distant geometry jitters/crawls under TAA
 while nearby geometry looks fine.

 1. STORAGE precision. Apple Silicon drivers aggressively demote GLSL that
    is not explicitly qualified to 16-bit (`half`). A 16-bit float has a
    10-bit mantissa: at a world coordinate of a few thousand blocks the
    representable step is already larger than a pixel's worth of parallax,
    so the reprojection lands on the wrong texel and the history swims.
    Every matrix and every position on this path is therefore explicitly
    `highp` (32-bit). In `#version 330 compatibility` the qualifier is
    legal and inherited by the expressions built from these operands.

 2. CANCELLATION. `cameraPosition - previousCameraPosition` is a difference
    of two LARGE, NEARLY EQUAL numbers (Iris wraps cameraPosition at ~30000
    blocks, so the operands can reach 3e4 while their difference is a
    fraction of a block). Even in 32-bit that subtraction discards most of
    the delta's significant bits — catastrophic cancellation. Iris exposes
    the split form for exactly this reason: `cameraPositionInt` (integer
    block counts) and `cameraPositionFract` ([0,1) remainder), plus the
    previous-frame twins. Subtracting the INTEGER parts as integers is
    EXACT, and the fractional parts are both small, so their difference is
    exact too. No large float difference is ever formed.

 The split uniforms are Iris-exclusive, so they are guarded by IS_IRIS; the
 fallback keeps the plain (still `highp`) subtraction so the pack continues
 to compile and run on OptiFine.
*/
uniform highp mat4 gbufferPreviousModelView;
uniform highp mat4 gbufferPreviousProjection;
uniform highp vec3 cameraPosition;
uniform highp vec3 previousCameraPosition;

#ifdef IS_IRIS
uniform ivec3 cameraPositionInt;          // Iris-exclusive: integer block part
uniform ivec3 previousCameraPositionInt;
uniform highp vec3 cameraPositionFract;   // Iris-exclusive: [0,1) remainder
uniform highp vec3 previousCameraPositionFract;
#endif

// Frame-to-frame camera translation, computed without catastrophic
// cancellation wherever Iris supplies the split camera position.
highp vec3 alCameraDelta() {
#ifdef IS_IRIS
    highp vec3 iDelta = vec3(cameraPositionInt - previousCameraPositionInt);
    highp vec3 fDelta = cameraPositionFract - previousCameraPositionFract;
    return iDelta + fDelta;
#else
    return cameraPosition - previousCameraPosition;
#endif
}

// Current-frame player-space position -> previous-frame VIEW space.
vec3 alPlayerToPrevView(vec3 playerPos) {
    highp vec3 prevPlayer = playerPos + alCameraDelta();
    return (gbufferPreviousModelView * vec4(prevPlayer, 1.0)).xyz;
}

// Previous-frame view-space position -> previous-frame screen space.
// Returns vec3(uv.xy, ndcDepth), all in [0,1] when the point is on-screen and
// in front of the previous camera (caller checks the range for validity).
vec3 alPrevViewToScreen(vec3 prevView) {
    highp vec4 clip = gbufferPreviousProjection * vec4(prevView, 1.0);
    highp vec3 ndc  = clip.xyz / clip.w;
    return ndc * 0.5 + 0.5;
}

// Linear eye-space depth (positive distance in front of the camera) from a
// view-space position. No near/far needed — it is just -z. Shared convention
// for the AO history's stored depth (colortex5.b) and its reprojection test.
float alLinearEyeDepth(vec3 viewPos) {
    return -viewPos.z;
}

/*
 MOTION VECTOR + history lookup, shared by every temporal accumulation pass
 (GTAO history in deferred, shadow history in deferred1, SSR history in
 composite). Iris exposes no motion-vector buffer and no built-in TAA jitter
 uniform, so the vector is DERIVED here from the previous-frame matrices exactly
 as the Iris uniform docs describe: re-express the point in the previous frame's
 player space (camera-delta), apply gbufferPreviousModelView /
 gbufferPreviousProjection, divide, and take the screen-space difference.

   viewPos   — this frame's VIEW-space position of the surface point.
   curUV     — this frame's screen uv of that point (usually texcoord; pass the
               UN-JITTERED uv if the caller jitters, so the vector is jitter-free).
   prevUV    — out: previous-frame screen uv (only valid when the call returns true).
               The screen-space motion vector, if a caller ever needs it, is
               simply prevUV - curUV.
   prevEyeZ  — out: the point's eye depth in the PREVIOUS frame, for the
               depth-consistency test against the stored history depth.

 Returns false — and leaves the outputs at safe defaults — when the point was
 behind the previous camera, lands off-screen, or produces a non-finite result.
 Every test is a comparison, so NaN fails it and falls through to `false`
 (the pack's NaN law: a poisoned history can never be accepted).
*/
bool alMotionVector(vec3 viewPos, vec2 curUV,
                    out vec2 prevUV, out float prevEyeZ) {
    prevUV   = curUV;
    prevEyeZ = -1.0;

    vec3 prevView = alPlayerToPrevView(alViewToPlayer(viewPos));
    vec4 clip     = gbufferPreviousProjection * vec4(prevView, 1.0);
    if (!(clip.w > 0.0)) return false;                 // behind the previous camera

    vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
    if (!(uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0)) return false;

    float z = alLinearEyeDepth(prevView);
    if (!(z > 0.0 && z < 65000.0)) return false;

    prevUV   = uv;
    prevEyeZ = z;
    return true;
}

/*
 Depth-consistency test for a reprojected history sample. `storedZ` is the eye
 depth the history buffer recorded for that texel, `expectZ` the depth we now
 predict for the same surface. Relative (not absolute) so the tolerance scales
 with distance. NaN fails both comparisons -> rejected.
*/
bool alHistoryDepthOK(float storedZ, float expectZ, float tolerance) {
    if (!(storedZ > 0.0 && storedZ < 65000.0)) return false;
    if (!(expectZ > 0.0 && expectZ < 65000.0)) return false;
    return (abs(expectZ - storedZ) / max(storedZ, 0.001)) < tolerance;
}

#endif // AL_LIB_SPACE
