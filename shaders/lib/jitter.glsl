#ifndef AL_LIB_JITTER
#define AL_LIB_JITTER

/*
 lib/jitter.glsl — TAA camera jitter (Phase 4).

 Applies a Halton(2,3) 8-frame sub-pixel offset to the clip-space vertex
 position so successive frames sample the pixel grid at slightly different
 points; composite3 then temporally resolves those samples into an
 anti-aliased image. Included by every gbuffers vertex shader that renders
 geometry into the scene (terrain, entities, sky, ...); the WATER agent adds
 the same include to its rewritten water/hand_water vsh. NOT included by
 shadow.vsh or any fullscreen (composite/deferred/final) pass.

 -------------------------------------------------------------------------
 CONST-ARRAY vs BRANCH-CHAIN DECISION (documented per contract §4.1):
 A `const vec2 kOffsets[8] = vec2[8](...)` initializer is core GLSL 3.30
 (array constructors landed in GLSL 1.20) and is therefore *syntactically*
 Mac-safe. HOWEVER the offset is looked up by a DYNAMIC index
 (frameCounter % 8), and Apple's OpenGL GLSL compiler has a long, documented
 history (shaderLABS wiki; multiple shaderpacks) of miscompiling dynamic
 indexing into const local arrays on the GL 4.1 path — the exact primary dev
 target here. The contract says "choose the robust option and document", so
 we use a BRANCH CHAIN (`alHaltonOffset`) that touches no array at all and
 cannot hit that quirk. It is a handful of comparisons in the vertex shader
 (negligible) and is bulletproof on every driver.

 UNIFORM OWNERSHIP: viewWidth / viewHeight / frameCounter are declared HERE,
 guarded by this file's include guard. A survey of every gbuffers *.vsh
 confirmed none of them declares these three uniforms, so including this file
 can never collide with a caller's own declaration. Any including vsh that
 does not use TAA simply carries three unused uniforms (glslang ignores them;
 Iris supplies them regardless) — harmless.
 -------------------------------------------------------------------------
*/

#include "/lib/common.glsl"

uniform float viewWidth;    // framebuffer width  in pixels
uniform float viewHeight;   // framebuffer height in pixels
uniform int   frameCounter; // frame index (wraps; Iris increments each frame)

/*
 Halton(2,3) sequence, indices 1..8, each component re-centred to [-0.5, 0.5]
 (subtract 0.5) so the jitter is a symmetric sub-pixel wobble about the pixel
 centre. Returned via a branch chain — see the const-array note above.
   base-2 (x):  0.5 .25 .75 .125 .625 .375 .875 .0625
   base-3 (y):  1/3 2/3 1/9 4/9  7/9  2/9  5/9  8/9
*/
vec2 alHaltonOffset(int i) {
    if (i == 0) return vec2( 0.00000, -0.16667);
    if (i == 1) return vec2(-0.25000,  0.16667);
    if (i == 2) return vec2( 0.25000, -0.38889);
    if (i == 3) return vec2(-0.37500, -0.05556);
    if (i == 4) return vec2( 0.12500,  0.27778);
    if (i == 5) return vec2(-0.12500, -0.27778);
    if (i == 6) return vec2( 0.37500,  0.05556);
    return              vec2(-0.43750,  0.38889); // i == 7
}

/*
 Apply the current frame's jitter to a clip-space position. A one-pixel offset
 in clip space is 2/viewSize (NDC spans [-1,1] across viewSize pixels), and the
 perspective divide by w happens after the vertex stage, so we pre-multiply by
 clipPos.w to keep the offset a constant screen-space distance at any depth.
 Behind #ifdef TAA with an exact identity fallback (returns the input unchanged)
 so a TAA-off build renders with no jitter and no cost.
*/
vec4 alJitter(vec4 clipPos) {
    // 0.4.4: the sub-pixel camera jitter is DISABLED. Field testing found the
    // jittered-TAA path visibly SHAKING distant terrain (the reprojection could
    // not track the sub-pixel wobble on far, high-contrast silhouettes), which is
    // exactly the shimmer the brief calls out. Anti-aliasing is now handled by an
    // FXAA edge pass plus an (unjittered, therefore exact) temporal stabilisation
    // in composite3 — smooth edges with NO geometry wobble. This function stays a
    // no-op wrapper so every gbuffers vsh can keep calling it unchanged; re-enable
    // the block below only if a fully reworked jitter+reproject lands later.
    return clipPos;
}

#endif // AL_LIB_JITTER
