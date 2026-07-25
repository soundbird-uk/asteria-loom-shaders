#ifndef AL_LIB_RAYS
#define AL_LIB_RAYS

/*
 lib/rays.glsl — the Loom "light-weave" crepuscular-ray signature (Phase 5,
 world0). LOOM agent.

 The screen-space god-ray MARCH itself lives in world0/composite2.fsh (it needs
 that program's depthtex0 / colortex0 samplers and is shared with the underwater
 path, so it stays co-located with its samplers). What lives HERE is the loom
 signature: a WEAVE that modulates the shaft brightness by a slow angular
 interference pattern around the sun, so the shafts read as gently interwoven
 bands — the pack's "light-weave" motif — rather than a uniform radial fan.

 alRayWeave(uv, sunUV, time):
   - uv     : this pixel's screen UV.
   - sunUV  : the sun's screen-space position (from composite2's alGodRayGate).
   - time   : frameTimeCounter (drives the SLOW drift; not per-pixel noise).
   - returns: a multiplier in [1 - AL_RAY_WEAVE_DEPTH, 1] — never negative, never
              brighter than the un-woven shaft, so it can only carve subtle bands.

 Two overlapping angular frequencies (AL_RAY_WEAVE_FREQ_A/B) counter-rotate
 slowly (AL_RAY_WEAVE_DRIFT); their product is an interference pattern whose
 crests/troughs sweep around the sun as interwoven bands. The drift is a slow
 rotation of a spatial pattern (NOT frame-varying noise), so it breathes without
 reintroducing the temporal flicker the stable shaft march was built to avoid.

 Pure math, no samplers, NaN-safe (degenerate pixel==sun returns 1.0). Gated by
 GOD_RAYS (the weave only exists where the shafts do); returns 1.0 when off.

 This file also hosts alSSRThicknessMax() (below) — the co-located, sampler-free
 Z-thickness acceptance window shared by the world0/composite.fsh SSR raymarch
 (Track 1). It is pure screen-space-ray math with no god-ray dependency, so it
 sits beside the other ray helpers and is compiled in unconditionally (NOT gated
 behind GOD_RAYS); composite.fsh includes this file solely to reach it.
*/

#include "/lib/common.glsl"

/*
============================================================================
 SSR Z-THICKNESS ACCEPTANCE WINDOW (Track 1, 5.3.0) — pure math, no samplers.
----------------------------------------------------------------------------
 The screen-space-reflection raymarch (world0/composite.fsh alTraceSSR) samples
 the depth buffer at discrete steps and must decide, when the ray first crosses
 BEHIND a sampled surface, whether that crossing is a genuine reflection HIT or
 whether the ray merely slipped behind a THIN foreground object (which must be a
 MISS so the reflection falls through to the sky / analytic in-fill instead of
 smearing that object's colour across the water).

 This helper returns MAX_THICKNESS: the largest linear eye-depth gap
   depthDiff = eyeZ(ray) - eyeZ(sampledSurface)      (both positive; = -view z)
 that may still count as a hit. It is DERIVED, never a hand-tuned constant:

   perStepZ = |rayDir.z| * stepLen
     View-space z is LINEAR (Iris reconstructs it straight from
     gbufferProjectionInverse), so between the last IN-FRONT sample and the first
     BEHIND sample the ray's eye depth advanced by exactly perStepZ. A genuine hit
     on the SAME surface therefore leaves a residual gap < perStepZ: at step i-1
     the ray sat in front of depth S, at step i it is behind the SAME S, so
     (eyeZ_i - S) < (eyeZ_i - eyeZ_{i-1}) = perStepZ. A ray that slipped behind a
     thin object instead lands over a NEARER surface, so its gap is
     (eyeZ - nearZ) >> perStepZ. Bounding the window by perStepZ is what separates
     "hit this surface" from "passed behind that thin one".

 Two physically-motivated slacks widen it (geometry, not visual fudge):
   * AL_SSR_THICK_STEPK (>1)  — headroom over perStepZ for the binary-search
     residual and the finite real thickness blocks actually have.
   * eyeZ * AL_SSR_THICK_DISTK — one depth texel spans MORE world at distance
     under perspective, so the reconstructed surface Z is coarser far away; the
     window grows linearly with the hit's eye depth to track that texel footprint.
   * AL_SSR_THICK_BASE — a sub-block floor so a near, fronto-parallel ray
     (rayDir.z ~ 0 => perStepZ ~ 0) still has a non-zero window and can hit.

 These constants live HERE (this file owns the helper) rather than in
 settings.glsl, per the pack rule that new internal tuning is #defined in the
 editing agent's own file, never surfaced as a user option.

 macOS precision: every term and intermediate is highp so Apple's GL 4.1 driver
 cannot demote this view-space depth arithmetic to fp16 and shear the accept test.
============================================================================
*/
#define AL_SSR_THICK_BASE   0.06   // sub-block floor (world metres)
#define AL_SSR_THICK_STEPK  1.6    // headroom multiplier over the per-step depth advance
#define AL_SSR_THICK_DISTK  0.020  // extra window per metre of eye depth (texel footprint)

highp float alSSRThicknessMax(highp float stepLen, highp vec3 rayDir, highp float eyeZ) {
    highp float perStepZ = abs(rayDir.z) * stepLen;
    return AL_SSR_THICK_BASE
         + perStepZ * AL_SSR_THICK_STEPK
         + eyeZ     * AL_SSR_THICK_DISTK;
}

float alRayWeave(vec2 uv, vec2 sunUV, float time) {
#ifdef GOD_RAYS
    vec2  d  = uv - sunUV;
    float r2 = dot(d, d);
    if (r2 < 1.0e-8) return 1.0;               // at the sun centre: no bands

    float theta = atan(d.y, d.x);              // angle around the sun (rad)

    // Two overlapping angular frequencies, slowly counter-rotating.
    float a = cos(theta * AL_RAY_WEAVE_FREQ_A + time * AL_RAY_WEAVE_DRIFT);
    float b = cos(theta * AL_RAY_WEAVE_FREQ_B - time * (AL_RAY_WEAVE_DRIFT * 0.6));

    // Product -> interference; remap to [0,1] interwoven bands.
    float weave = 0.5 + 0.5 * a * b;

    // Subtle: only dip the shaft in the troughs, never fully cut it or brighten.
    return 1.0 - AL_RAY_WEAVE_DEPTH * (1.0 - alSaturate(weave));
#else
    return 1.0;
#endif
}

#endif // AL_LIB_RAYS
