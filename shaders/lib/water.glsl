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

// Irregular multi-directional ripple normal (world Y-up frame). `strength`
// scales the horizontal slope (ripple amplitude); `dist` is the fragment's
// distance from the camera (blocks) and fades the micro layer out.
vec3 alWaterWaveNormal(vec3 worldPos, float t, float strength, float dist) {
    vec2 wp = worldPos.xz;

    // --- Layer 2: per-patch rotation + weight seed (low freq, once) ----------
    float patchNoise = alWaterValue2D(wp * AL_WATER_PATCH_SCALE);
    float patchRot   = (alWaterValue2D(wp * AL_WATER_PATCH_SCALE + 31.7) - 0.5)
                     * AL_WATER_PATCH_ROT;

    // --- Layer 1: big waves, analytic gradient (one pass) --------------------
    float dhdx = 0.0, dhdz = 0.0, norm = 0.0;
    float invN = 1.0 / float(AL_WATER_WAVE_COMPONENTS);
    for (int i = 0; i < AL_WATER_WAVE_COMPONENTS; i++) {
        float fi = float(i);
        // Spread angle + irregular per-component jitter + per-patch rotation.
        float ang = fi * invN * AL_TAU
                  + fract(sin(fi * 12.9898) * 43758.5453) * 1.4
                  + patchRot;
        vec2  dir = vec2(cos(ang), sin(ang));

        float kmul = 1.0 + fract(fi * 0.618034) * 1.6;   // non-monotonic freq spread
        float k    = AL_WATER_WAVE_K * kmul;
        float omega = AL_WATER_WAVE_SPEED * sqrt(k);      // dispersion (long = faster)
        float amp   = inversesqrt(kmul)
                    * mix(0.35, 1.0, fract(patchNoise + fi * 0.37));   // per-patch weight
        float phase = fract(sin(fi * 78.233) * 24634.6345) * AL_TAU;

        float th = dot(wp, dir) * k + t * omega + phase;
        float c  = cos(th);                               // d/d(theta) sin = cos
        dhdx += amp * k * c * dir.x;
        dhdz += amp * k * c * dir.y;
        norm += amp;
    }
    float inv = 1.0 / max(norm, 1e-4);
    dhdx *= inv;
    dhdz *= inv;

    // --- Layer 3: micro detail (finite diff, distance-faded) -----------------
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
// Projected along the sun direction onto the submerged surface point. The
// projection offset (sunDir.xz / sunDir.y * worldY) slides the pattern with the
// sun's arc so caustics "cast" from above, dreamy and slow. Returns [0,1] with
// bright thin lines near 1.0. 2 octaves x a 3x3 voronoi search (pure math).
float alWaterCaustic(vec3 worldPos, vec3 sunDir, float t) {
    vec2 base = worldPos.xz + (sunDir.xz / max(sunDir.y, 0.30)) * worldPos.y;
    float c = 0.0, amp = 1.0, scl = AL_CAUSTIC_SCALE, norm = 0.0;
    for (int o = 0; o < 2; o++) {
        vec2 p = base * scl + vec2(float(o) * 17.3);
        vec2 n = floor(p);
        vec2 f = fract(p);
        float md = 8.0;
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec2 g = vec2(float(x), float(y));
                vec2 off = alWaterHash22(n + g);
                off = 0.5 + 0.5 * sin(t + AL_TAU * off);       // animate feature pts
                vec2 r = g + off - f;
                md = min(md, dot(r, r));
            }
        }
        float d = sqrt(md);
        c    += amp * (1.0 - smoothstep(0.0, 0.7, d));         // thin bright network
        norm += amp;
        amp  *= 0.5;
        scl  *= 2.0;
    }
    return alSaturate(c / max(norm, 1e-4));
}

#endif // AL_LIB_WATER
