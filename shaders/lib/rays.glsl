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
*/

#include "/lib/common.glsl"

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
