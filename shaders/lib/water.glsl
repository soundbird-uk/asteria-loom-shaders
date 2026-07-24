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

/*
============================================================================
 GERSTNER OCEAN (5.1.0 water overhaul)
----------------------------------------------------------------------------
 A sum of AL_WATER_WAVE_N Gerstner (trochoidal) waves. Unlike a pure sine height
 field, Gerstner waves also displace HORIZONTALLY toward the crests, so wave tops
 PINCH/SHARPEN and troughs BROADEN — real swell shape. Wave directions are spaced
 by the GOLDEN ANGLE (2.39996 rad), an irrational increment, so the directional
 set is never commensurate and the summed surface NEVER repeats across large
 oceans. Frequencies follow a geometric band (long swells -> short chop) and speed
 follows deep-water dispersion (omega = SPEED*sqrt(k)).

 Two entry points share the model so each stage pays only for what it needs:
   alGerstnerDisplace(wp,t)                 -> vec3 world displacement (vertex sh.)
   alGerstnerSurface(wp,t, out N, out J)    -> analytic normal + Jacobian (frag sh.)
 The Jacobian J of the horizontal displacement folds negative (J<0) exactly where
 crests overhang — the trigger for crest foam.
 Pure GL3.30 math (no samplers, no bit ops).
============================================================================
*/
#define AL_GOLDEN_ANGLE 2.39996323

// Per-wave parameters for index i (kept identical across both entry points so the
// displaced geometry and the shaded normal agree).
void alGerstnerParams(int i, out vec2 dir, out float ki, out float ai,
                      out float wi, out float qi) {
    float fi  = float(i);
    float ang = fi * AL_GOLDEN_ANGLE;                       // irrational spacing
    dir = vec2(cos(ang), sin(ang));
    ki  = AL_WATER_WAVE_K * pow(AL_WATER_WAVE_GAIN, fi);    // geometric freq band
    ai  = AL_WATER_WAVE_AMP * pow(AL_WATER_AMP_GAIN, fi);   // falling amplitude
    wi  = AL_WATER_WAVE_SPEED * sqrt(ki);                   // deep-water dispersion
    // Per-wave steepness, bounded by 1/(k*N) so crests sharpen without looping.
    qi  = AL_WATER_STEEPNESS / (ki * float(AL_WATER_WAVE_N) + 1e-4);
}

// World-space Gerstner displacement (x,z pinch toward crests, y height).
vec3 alGerstnerDisplace(vec2 wp, float t) {
    vec3 disp = vec3(0.0);
    for (int i = 0; i < AL_WATER_WAVE_N; i++) {
        vec2 dir; float ki, ai, wi, qi;
        alGerstnerParams(i, dir, ki, ai, wi, qi);
        float th = dot(wp, dir) * ki + t * wi + float(i) * 1.3;
        float s = sin(th), c = cos(th);
        disp.x += qi * ai * dir.x * c;
        disp.z += qi * ai * dir.y * c;
        disp.y += ai * s;
    }
    return disp;
}

// Analytic surface normal (world Y-up) + Jacobian determinant of the horizontal
// displacement. `strength` scales the horizontal slope of the normal.
void alGerstnerSurface(vec2 wp, float t, float strength, out vec3 nrm, out float jac) {
    float dhdx = 0.0, dhdz = 0.0, nySum = 0.0;
    float jxx = 0.0, jzz = 0.0, jxz = 0.0;
    for (int i = 0; i < AL_WATER_WAVE_N; i++) {
        vec2 dir; float ki, ai, wi, qi;
        alGerstnerParams(i, dir, ki, ai, wi, qi);
        float th = dot(wp, dir) * ki + t * wi + float(i) * 1.3;
        float s = sin(th), c = cos(th);
        float ka = ki * ai;
        dhdx  += dir.x * ka * c;
        dhdz  += dir.y * ka * c;
        nySum += qi * ka * s;
        float wa = qi * ka * s;                 // shared Jacobian term
        jxx += dir.x * dir.x * wa;
        jzz += dir.y * dir.y * wa;
        jxz += dir.x * dir.y * wa;
    }
    nrm = normalize(vec3(-dhdx * strength, max(1.0 - nySum, 0.02), -dhdz * strength));
    jac = (1.0 - jxx) * (1.0 - jzz) - jxz * jxz;   // < 0 where crests fold
}

// --- 3D simplex noise (Ashima/McEwan; GL3.30-safe, no bit ops) --------------
// Used for the domain-warped micro-ripple normal (capillary waves / wind gusts).
vec3 alW_mod289(vec3 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 alW_mod289(vec4 x){ return x - floor(x * (1.0/289.0)) * 289.0; }
vec4 alW_permute(vec4 x){ return alW_mod289(((x*34.0)+1.0)*x); }
vec4 alW_taylorInvSqrt(vec4 r){ return 1.79284291400159 - 0.85373472095314 * r; }
float alSimplex3(vec3 v) {
    const vec2 C = vec2(1.0/6.0, 1.0/3.0);
    const vec4 D = vec4(0.0, 0.5, 1.0, 2.0);
    vec3 i  = floor(v + dot(v, C.yyy));
    vec3 x0 = v - i + dot(i, C.xxx);
    vec3 g  = step(x0.yzx, x0.xyz);
    vec3 l  = 1.0 - g;
    vec3 i1 = min(g.xyz, l.zxy);
    vec3 i2 = max(g.xyz, l.zxy);
    vec3 x1 = x0 - i1 + C.xxx;
    vec3 x2 = x0 - i2 + C.yyy;
    vec3 x3 = x0 - D.yyy;
    i = alW_mod289(i);
    vec4 p = alW_permute(alW_permute(alW_permute(
              i.z + vec4(0.0, i1.z, i2.z, 1.0))
            + i.y + vec4(0.0, i1.y, i2.y, 1.0))
            + i.x + vec4(0.0, i1.x, i2.x, 1.0));
    float n_ = 0.142857142857;
    vec3 ns = n_ * D.wyz - D.xzx;
    vec4 j = p - 49.0 * floor(p * ns.z * ns.z);
    vec4 x_ = floor(j * ns.z);
    vec4 y_ = floor(j - 7.0 * x_);
    vec4 x = x_ * ns.x + ns.yyyy;
    vec4 y = y_ * ns.x + ns.yyyy;
    vec4 h = 1.0 - abs(x) - abs(y);
    vec4 b0 = vec4(x.xy, y.xy);
    vec4 b1 = vec4(x.zw, y.zw);
    vec4 s0 = floor(b0) * 2.0 + 1.0;
    vec4 s1 = floor(b1) * 2.0 + 1.0;
    vec4 sh = -step(h, vec4(0.0));
    vec4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
    vec4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
    vec3 p0 = vec3(a0.xy, h.x);
    vec3 p1 = vec3(a0.zw, h.y);
    vec3 p2 = vec3(a1.xy, h.z);
    vec3 p3 = vec3(a1.zw, h.w);
    vec4 nrm = alW_taylorInvSqrt(vec4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3)));
    p0 *= nrm.x; p1 *= nrm.y; p2 *= nrm.z; p3 *= nrm.w;
    vec4 m = max(0.6 - vec4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
    m = m * m;
    return 42.0 * dot(m*m, vec4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
}

// Domain-warped micro-ripple normal detail (capillary waves + wind gusts). Two
// warp passes of 3D simplex (z = time) give evolving, non-repeating fine ripples;
// central differences of the warped field build a tangent-space-ish slope that we
// fold into the Gerstner normal. `amt` (0..1) fades it out with distance.
vec3 alWaterMicroNormal(vec2 wp, float t, float amt) {
    if (amt <= 0.001) return vec3(0.0, 1.0, 0.0);
    float sc = AL_WATER_MICRO_SCALE;
    vec3 q  = vec3(wp * sc, t * AL_WATER_MICRO_SPEED);
    // domain warp
    vec3 w  = vec3(alSimplex3(q), alSimplex3(q + 11.5), 0.0);
    vec3 qw = q + vec3(w.xy * AL_WATER_MICRO_WARP, 0.0);
    float e = 0.75;
    float h0 = alSimplex3(qw);
    float hx = alSimplex3(qw + vec3(e, 0.0, 0.0));
    float hz = alSimplex3(qw + vec3(0.0, e, 0.0));
    float amp = AL_WATER_MICRO_AMP * amt;
    return normalize(vec3(-(hx - h0) / e * amp, 1.0, -(hz - h0) / e * amp));
}

// Combine a detail normal (world Y-up) onto a base normal (reoriented-normal
// blend): keeps the base slope and adds the detail's tilt. Both are Y-up frames.
vec3 alBlendNormals(vec3 base, vec3 detail) {
    return normalize(vec3(base.xz + detail.xz, base.y * detail.y));
}

#endif // AL_LIB_WATER
