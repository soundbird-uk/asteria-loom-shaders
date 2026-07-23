#ifndef AL_LIB_WATER
#define AL_LIB_WATER

/*
 lib/water.glsl — SAMPLER-FREE, uniform-free water maths (Phase 4, WATER agent).

 Pure GLSL 3.30 / Mac-GL4.1 math: NO samplers, NO uniform declarations, NO
 state. Every function takes the world position + time (+ sun direction) it
 needs as ARGUMENTS, exactly like lib/atmosphere_common.glsl and
 lib/clouds_common's noise helpers. This is deliberate: the file is included by
 THREE passes with DIFFERENT uniform environments —
   * gbuffers_water.fsh   (has frameTimeCounter via lib/lighting -> clouds_common)
   * composite.fsh        (the new water-effects pass; has its own uniforms)
 and must never collide with a uniform a consumer already declares. In
 particular it must NOT include lib/clouds_common.glsl (that declares
 rainStrength/frameTimeCounter/sunAngle, which some consumers already own —
 re-declaring would be a duplicate-uniform error), so it carries its OWN tiny
 hash/value-noise rather than reusing alCloudValue2D.

 Exports:
   vec3  alWaterWaveNormal(vec3 worldPos, float t, float strength, float dist)
       — irregular multi-directional ripple normal in a world Y-UP frame
         (assumes a near-horizontal surface; the caller reorients undersides and
         blends only where the surface is roughly flat). NOT a single marching
         front: a superposition of directional waves at spread angles + a
         spatially-varying patch field + a distance-faded micro-detail layer.
         See the wave section below for the full model.
   float alWaterCaustic(vec3 worldPos, vec3 sunDir, float t)
       — animated 2-octave voronoi-ish caustic network in [0,1], evaluated at the
         SUBMERGED surface position and projected along the sun direction. Bright
         thin lines near 1.0; used to modulate the submerged scene ±.
*/

#include "/lib/common.glsl"

// --- Private hashes / value noise (no uniforms) ----------------------------
// Pure-math hash (no bit ops — GL 3.30/4.1 / Apple-path safe).
float alWaterHash21(vec2 p) {
    p = fract(p * vec2(0.1031, 0.11369));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

vec2 alWaterHash22(vec2 p) {
    p = vec2(dot(p, vec2(127.1, 311.7)), dot(p, vec2(269.5, 183.3)));
    return fract(sin(p) * 43758.5453);
}

float alWaterValue2D(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = alWaterHash21(i);
    float b = alWaterHash21(i + vec2(1.0, 0.0));
    float c = alWaterHash21(i + vec2(0.0, 1.0));
    float d = alWaterHash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/*
============================================================================
 WAVE MODEL (0.4.2 rework — "make it random, different parts moving in
 different directions, lots of micro 3D texture").
----------------------------------------------------------------------------
 THREE layers, summed as a HEIGHT FIELD whose gradient is the ripple normal:

 1. BIG WAVES — a superposition of AL_WATER_WAVE_COMPONENTS (6) directional
    sine waves. Component i:
      * DIRECTION: base angle i/N * 2pi (60deg apart -> components i and i+3 are
        ~opposing => standing / criss-cross interference, not a marching front),
        plus a fixed per-component hash jitter so the spread is irregular, plus a
        per-PATCH rotation (layer 2) so it varies across the world.
      * FREQUENCY: k = K * (1 + golden(i)*1.6), a low-discrepancy spread over
        ~2.6x (a 1.4-octave band) that is NON-monotonic in the angle.
      * SPEED: DISPERSION — long waves travel faster. omega = SPEED*sqrt(k), so
        phase speed omega/k = SPEED/sqrt(k) rises for the low-k (long) waves.
      * AMPLITUDE: 1/sqrt(kmul) (longer waves a touch taller), times the
        per-patch weight (layer 2), then normalised.
    The gradient of this layer is ANALYTIC (d/dx of amp*sin(dot(wp,dir)*k + ...)
    = amp*k*cos(...)*dir), so it is evaluated in ONE pass with the EXACT slope —
    cheaper than 3 finite-difference height samples AND free of aliasing sparkle.

 2. PATCH FIELD — two very-low-frequency value-noise samples over worldXZ give a
    local rotation (spins every component's direction) and a weight seed (shifts
    which components dominate). Different lake patches therefore move in visibly
    different directions/mixes. Sampled ONCE per fragment (low frequency => its
    own gradient is negligible and deliberately not differentiated).

 3. MICRO DETAIL — a high-frequency 2-warp domain-warped value noise, drifting
    off-sync from the big waves, at small amplitude: the fine "physical 3D
    texture". It has no cheap analytic gradient, so its slope is taken by central
    differences (epsilon AL_WATER_NORMAL_EPS, sized to its wavelength). It FADES
    to zero by AL_WATER_MICRO_FADE blocks so distant water can't sparkle under
    the finite-difference derivative (and far fragments skip it entirely).

 COST (per shaded water fragment, i.e. per normal):
   patch:  2 value-noise           = 8 hash
   big:    6 components, ONE pass   = ~6 cos(dir)+6 sin(dir)+6 cos(theta)
                                       +12 hash-free const trig +6 sqrt/rsqrt
   micro:  3 evals x 5 value-noise  = 60 hash  (NEAR only; 0 past the fade)
 So near water ~ 68 hash + ~30 trig (~1.8-2.2x the old 36-hash/3-sin model, the
 stated ~2x budget); far water ~ 8 hash + ~30 trig (micro skipped) — cheaper
 than before. All pure math, NaN-safe (every divisor guarded, inputs bounded).
============================================================================
*/

// High-frequency 2-warp domain-warped value noise in [-1,1] (the micro layer).
// `t` is the (already micro-scaled) time; the drift is off-sync from the waves.
float alWaterMicro(vec2 wp, float t) {
    vec2 q = wp * AL_WATER_MICRO_SCALE + vec2(t * 0.13, -t * 0.11);
    vec2 w1 = vec2(alWaterValue2D(q), alWaterValue2D(q + 5.2));
    vec2 w2 = vec2(alWaterValue2D(q + 4.0 * w1), alWaterValue2D(q + 4.0 * w1 + 3.1));
    return alWaterValue2D(q + 4.0 * w2) * 2.0 - 1.0;
}

// Ocean-like ripple normal (world Y-up frame). `strength` scales the horizontal
// slope; `dist` fades the micro layer out with range (anti-sparkle).
//
// 0.4.4 REWRITE ("water looks terrible / circles / not random"): the old model's
// EVENLY-spaced component directions + per-patch ROTATION produced radially-
// symmetric, circular interference ("circles going in"). This is a proper OCEAN
// SPECTRUM instead: many waves whose DIRECTIONS are hash-randomised (never a
// symmetric fan) across a wide GEOMETRIC frequency band — long swells (~15 blk)
// down to short ripples (~1 blk) — with amplitude falling and speed following
// dispersion. The sum of many incommensurate directional waves NEVER repeats, so
// the surface laps and swells randomly everywhere. A very-low-frequency patch
// field only modulates overall CHOPPINESS (calm vs choppy areas), never rotation,
// and a faint domain-warped micro layer adds the fine "micro water interaction"
// texture up close. Big-wave normal is analytic (exact gradient, alias-free).
vec3 alWaterWaveNormal(vec3 worldPos, float t, float strength, float dist) {
    vec2 wp = worldPos.xz;

    // Large-scale choppiness field (calm patches vs choppy patches). No rotation.
    float chop = mix(0.55, 1.35, alWaterValue2D(wp * AL_WATER_PATCH_SCALE));

    float dhdx = 0.0, dhdz = 0.0, norm = 0.0;
    for (int i = 0; i < AL_WATER_WAVE_COMPONENTS; i++) {
        float fi = float(i);
        // Hash-randomised direction (NOT an even fan) -> no circular symmetry.
        float a  = alWaterHash21(vec2(fi * 1.7, 4.3)) * AL_TAU;
        vec2  dir = vec2(cos(a), sin(a));
        // Geometric frequency band: long swells -> short ripples.
        float k    = AL_WATER_WAVE_K * pow(1.34, fi);
        float amp  = pow(0.80, fi) * chop;               // falling amplitude
        float omega = AL_WATER_WAVE_SPEED * sqrt(k);     // dispersion
        float phase = alWaterHash21(vec2(fi * 2.1, 9.7)) * AL_TAU;
        // Gentle steepening (Gerstner-ish) so crests sharpen, troughs flatten.
        float th = dot(wp, dir) * k + t * omega + phase;
        float c  = cos(th);
        dhdx += amp * k * c * dir.x;
        dhdz += amp * k * c * dir.y;
        norm += amp;
    }
    float inv = 1.0 / max(norm, 1e-4);
    dhdx *= inv;
    dhdz *= inv;

    // Micro detail (finite diff, distance-faded): the fine surface texture.
    float microAmt = alSaturate(1.0 - dist / AL_WATER_MICRO_FADE);
    if (microAmt > 0.001) {
        float e  = AL_WATER_NORMAL_EPS;
        float mt = t * AL_WATER_MICRO_SPEED;
        float m0 = alWaterMicro(wp, mt);
        float mx = alWaterMicro(wp + vec2(e, 0.0), mt);
        float mz = alWaterMicro(wp + vec2(0.0, e), mt);
        float ma = AL_WATER_MICRO_AMP * microAmt;
        dhdx += ma * (mx - m0) / e;
        dhdz += ma * (mz - m0) / e;
    }

    return normalize(vec3(-dhdx * strength, 1.0, -dhdz * strength));
}

// --- Animated caustics ------------------------------------------------------
// 0.4.4 REWRITE ("no real caustics / just circles"): the old voronoi produced
// round cell blobs. This is the classic looping-domain caustic — a few iterations
// of a self-referential trig fold that yields the characteristic WEB of thin,
// curved, interlocking bright filaments real underwater caustics have. Projected
// along the sun direction so the pattern "casts" from above and slides with the
// sun's arc. Pure math, GL3.30-safe (divisors guarded so no NaN/Inf). Returns
// [0,1], bright filaments near 1.0.
float alWaterCaustic(vec3 worldPos, vec3 sunDir, float t) {
    vec2 uv = (worldPos.xz + (sunDir.xz / max(sunDir.y, 0.30)) * worldPos.y)
            * AL_CAUSTIC_SCALE;
    float tt0 = t;
    vec2  p   = mod(uv * AL_TAU, AL_TAU) - 250.0;
    vec2  ii  = p;
    float c   = 1.0;
    float inten = 0.0045;
    for (int n = 0; n < 3; n++) {
        float tw = tt0 * (1.0 - 3.5 / float(n + 1));
        ii = p + vec2(cos(tw - ii.x) + sin(tw + ii.y),
                      sin(tw - ii.y) + cos(tw + ii.x));
        float sx = sin(ii.x + tw); sx = (abs(sx) < 1e-3) ? 1e-3 : sx;
        float cy = cos(ii.y + tw); cy = (abs(cy) < 1e-3) ? 1e-3 : cy;
        c += 1.0 / length(vec2(p.x / (sx / inten), p.y / (cy / inten)));
    }
    c = 1.17 - pow(max(c / 3.0, 0.0), 1.4);
    return alSaturate(pow(abs(c), 8.0));
}

#endif // AL_LIB_WATER
