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
// TRACK 2 reflection reuses the pack's OWN analytic atmosphere (alSkyRadiance,
// alDirectColor). That core — lib/atmosphere_common.glsl — is, like this file,
// strictly SAMPLER-FREE and UNIFORM-FREE (its LUT-sampling sibling
// lib/atmosphere.glsl is what adds colortex6, and we deliberately do NOT include
// that here), and it is #ifndef-guarded, so pulling it in is safe in every
// program that already includes water.glsl (vertex + fragment, all worlds,
// composite) and never re-declares a uniform a consumer already owns. This lets
// the water surface reflect the REAL time-of-day sky instead of a constant blue,
// without inventing a second sky model.
#include "/lib/atmosphere_common.glsl"

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

// SHORELINE weight for wave i: near shore (shoreFactor -> 0) the big LOW-frequency
// swells (low i) fade out while the fine high-frequency capillary ripples (high i)
// are preserved, so shallow water stays rippled, never flat glass. Offshore
// (shoreFactor -> 1) every wave is at full amplitude.
float alShoreWaveW(int i, float shoreFactor) {
    float hf = float(i) / float(AL_WATER_WAVE_N - 1);   // 0 = biggest swell, 1 = finest ripple
    return mix(shoreFactor, 1.0, hf);
}

// World-space Gerstner displacement (x,z pinch toward crests, y height).
// shoreFactor (0 shallow/calm .. 1 deep/rough) attenuates the big swells near land.
// The phase `th` mixes WORLD position with TIME (frameTimeCounter), so it is kept
// `highp` — on Apple-silicon GL4.1 a demoted 16-bit phase would band/stair the
// waves badly once wp grows large. See alGerstnerSurface for the matching fold.
vec3 alGerstnerDisplace(vec2 wp, float t, float shoreFactor) {
    highp vec3 disp = vec3(0.0);
    for (int i = 0; i < AL_WATER_WAVE_N; i++) {
        vec2 dir; float ki, ai, wi, qi;
        alGerstnerParams(i, dir, ki, ai, wi, qi);
        ai *= alShoreWaveW(i, shoreFactor);
        highp float th = dot(wp, dir) * ki + t * wi + float(i) * 1.3;
        float s = sin(th), c = cos(th);
        disp.x += qi * ai * dir.x * c;
        disp.z += qi * ai * dir.y * c;
        disp.y += ai * s;
    }
    return disp;
}

/*
============================================================================
 TRACK 3 — JACOBIAN-DETERMINANT WHITECAP FOAM (open-water compression foam)
----------------------------------------------------------------------------
 alGerstnerSurface returns the analytic world Y-up normal AND a NORMALIZED
 WAVE-FOLD measure derived from the Jacobian of the horizontal Gerstner map,
 both accumulated INSIDE the single existing wave loop (two extra adds, no extra
 trig) so the instruction budget is unchanged.

 The horizontal displacement map is
   P.xz(x) = x + SUM_i Q_i A_i D_i cos(theta_i),   theta_i = k_i (D_i . x) + w_i t
 (exactly the alGerstnerDisplace above). Its Jacobian determinant's first-order
 area term is the divergence
   div P.xz - 2 = SUM_i Q_i A_i k_i (D_i . D_i) (-sin theta_i)
              = -SUM_i Q_i A_i k_i sin(theta_i)        (D_i is a unit vector)
 giving the textbook fold determinant
   J_raw = 1 - SUM_i Q_i A_i k_i sin(theta_i).
 This is the brief's `J = 1 - sum_i Q_i A_i k_i cos(...)` with sin in place of
 cos, purely because THIS pack drives the horizontal displacement with cos, so
 its x-derivative is -sin — same Q_i (steepness), A_i (amplitude), k_i (wave
 number) and w_i (angular frequency) the displacement itself uses, phase-locked
 to the same frameTimeCounter term; NOT a parallel fake wave sum.

 WHY IT IS NORMALIZED. The pack deliberately BOUNDS per-wave steepness with
 q_i = STEEPNESS/(k_i N) so the summed surface never self-intersects on the block
 grid. As a direct consequence the raw determinant only ever dips to ~0.69
 (measured over the whole surface across time) and NEVER reaches the classic
 J < 0 (or even J < 0.2) fully-folded crest — a literal `foldJ < 0.2` test on
 J_raw would spawn ZERO foam. To make the fold an amplitude-independent measure
 whose sub-0.2 tail is genuinely populated by the sharpest crests, the signed
 compression C = SUM_i Q_i A_i k_i sin(theta_i) is divided by its own analytic
 maximum Cmax = SUM_i Q_i A_i k_i (every wave crest-aligned, sin = 1):
   foldJ = 1 - C / Cmax  in [0, 2]
 which reads 0 at the TIGHTEST achievable crest, 1 at flat rest and 2 in the
 deepest trough. foldJ is a strictly monotonic (hence C-infinity) rescale of the
 real Jacobian compression, so the crest RANKING is identical to J_raw's — the
 foam still marks precisely the most-compressed water, only on a scale where the
 brief's < 0.2 threshold is meaningful. Cmax is guarded (>= 1e-4) so no divide by
 zero. `highp` throughout: C and the phase mix world position with time.

 The caller ramps foam with a smoothstep on foldJ (no branch, no pop) and full
 whitecap at foldJ < AL_WATER_JFOAM_FULL (= 0.20, the brief's fold threshold).
============================================================================
*/
// Foam ramp on the normalized fold (see above). Foam is FULL below FULL (the
// brief's J < 0.2 fully-folded crest) and rises continuously up to ONSET, above
// which open water carries no crest foam.
#define AL_WATER_JFOAM_FULL   0.20   // foldJ below this = solid whitecap (brief J<0.2)
#define AL_WATER_JFOAM_ONSET  0.62   // foldJ above this = no crest foam (soft C1 edge)

// Analytic surface normal (world Y-up) + the normalized wave-fold `foldJ`.
// `strength` scales the horizontal slope of the normal; shoreFactor attenuates
// the big-swell contribution near land (fine ripples preserved).
void alGerstnerSurface(vec2 wp, float t, float strength, float shoreFactor,
                       out vec3 nrm, out float foldJ) {
    highp float dhdx = 0.0, dhdz = 0.0;
    highp float cComp = 0.0;   // C    = SUM Q_i A_i k_i sin(theta_i)  (signed compression)
    highp float cNorm = 0.0;   // Cmax = SUM Q_i A_i k_i               (crest-aligned bound)
    for (int i = 0; i < AL_WATER_WAVE_N; i++) {
        vec2 dir; float ki, ai, wi, qi;
        alGerstnerParams(i, dir, ki, ai, wi, qi);
        ai *= alShoreWaveW(i, shoreFactor);
        highp float th = dot(wp, dir) * ki + t * wi + float(i) * 1.3;
        float s = sin(th), c = cos(th);
        float ka = ki * ai;
        dhdx  += dir.x * ka * c;
        dhdz  += dir.y * ka * c;
        float wa = qi * ka * s;                 // Q_i A_i k_i sin(theta_i)
        cComp += wa;                            // signed horizontal compression C
        cNorm += qi * ka;                       // its crest-aligned maximum Cmax
    }
    // cComp doubles as the vertical foreshortening of the normal (SUM q_i k_i a_i
    // sin), so the height field and the fold stay derived from one accumulation.
    nrm = normalize(vec3(-dhdx * strength, max(1.0 - cComp, 0.02), -dhdz * strength));
    foldJ = 1.0 - cComp / max(cNorm, 1e-4);     // 0 tight crest .. 1 rest .. 2 trough
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
//
// COMPONENT ORDER IS LOad-BEARING. The textbook RNM blend is written for a Z-up
// tangent frame (`vec3(base.xy + detail.xy, base.z * detail.z)`); this pack's
// wave normals are world Y-UP, so the SLOPE pair is .xz and the UP term is .y.
// Converting only the input swizzle and leaving `vec3(vec2, float)` construction
// alone silently emitted (x, z, y) — GLSL fills components in order, so the
// z-slope landed in .y and the up term in .z. That tipped every water normal
// nearly horizontal (~±0.26, ±0.26, 0.93 for typical slopes), which in turn made
// SSR reject about half its rays on the first dot(), turned the reflected-ray
// horizon cut into a per-pixel two-tone selector, and blew up the refraction
// offset — i.e. the "dark patchy grainy grid" and "just blue" water reports.
// Build the components explicitly so the ordering can never drift again.
vec3 alBlendNormals(vec3 base, vec3 detail) {
    return normalize(vec3(base.x + detail.x,      // x slope
                          base.y * detail.y,      // up  (RNM product)
                          base.z + detail.z));    // z slope
}

/*
 WHISPY FRACTAL FOAM mask in [0,1] — lib/water.glsl's foam noise field.

 Structure (5.3.0 rewrite):
   1. TWO-STAGE DOMAIN WARP. The sample point is displaced by a low-frequency
      3D-simplex vector (stage 1, coarse: bends the whole foam sheet into
      organic tongues) and then again by a higher-frequency, counter-offset
      vector (stage 2, fine: shears those tongues into whiskers). A single warp
      stage produces rounded blobs; the second stage is what makes the field
      filamentary.
   2. RIDGED OCTAVES. Each octave is 1 - |simplex| rather than plain simplex.
      Plain fBm is smooth and gaussian-ish, which reads as a soft gradient —
      exactly the "uniform painted band" complaint. Ridged noise concentrates
      its energy into thin crests, so the fractal sum is a web of filaments.
   3. z = time, so the whole field evolves and drifts instead of being a static
      texture painted onto the water.

 Returned unclamped in [0,1] and deliberately NOT thresholded here: the callers
 combine it with their own drive term (Jacobian for crest foam, depth mask for
 shoreline foam) and then erode with alWaterFoamErode, so the threshold acts on
 the PRODUCT and chews the band's edge into whiskers rather than fading it.
*/
float alWaterFoamNoise(vec2 wp, float t) {
    vec3 q = vec3(wp * AL_WATER_FOAM_SCALE, t * 0.28);
    // Stage 1 — coarse domain warp (organic tongues).
    vec3 w1 = vec3(alSimplex3(q), alSimplex3(q + 19.3), alSimplex3(q + 7.1));
    q += w1 * AL_WATER_FOAM_WARP;
    // Stage 2 — fine, counter-offset warp (shears the tongues into whiskers).
    vec3 q2 = q * 2.17 + 4.7;
    vec3 w2 = vec3(alSimplex3(q2 + 3.1), alSimplex3(q2 - 8.9), alSimplex3(q2 + 12.7));
    q += w2 * AL_WATER_FOAM_WARP2;

    float f = 0.0, amp = 0.6, freq = 1.0, norm = 0.0;
    for (int i = 0; i < AL_WATER_FOAM_OCTAVES; i++) {
        // Ridged octave: 1 - |n| puts the maximum on the noise's zero crossings,
        // which are thin curves -> filaments instead of blobs.
        f    += amp * (1.0 - abs(alSimplex3(q * freq)));
        norm += amp;
        freq *= 2.1;
        amp  *= 0.5;
    }
    return alSaturate(f / max(norm, 1e-4));
}

/*
 FOAM EROSION. `drive` is the physical foam amount the caller computed (crest
 Jacobian fold, or shoreline depth proximity), `mask` the fractal field above.

 Instead of `foam = drive * mask` (which only DIMS a band that keeps its smooth
 shape), the product is pushed through a smoothstep threshold: everywhere the
 combined value fails to clear AL_WATER_FOAM_ERODE_LO the foam is removed
 outright, so the band develops holes and ragged, broken edges. A high-frequency
 filament term is then added back near the threshold, which is where real foam
 tears into whiskers.

 Returns 0 exactly where there is no foam, so callers can keep their cheap
 `if (foam > 0.001)` guards.
*/
float alWaterFoamErode(float drive, float mask) {
    if (drive <= 0.0) return 0.0;
    float v = alSaturate(drive) * mask;
    float eroded = smoothstep(AL_WATER_FOAM_ERODE_LO, AL_WATER_FOAM_ERODE_HI, v);
    // Filament gain: strongest where the eroded edge is (0<e<1), so the whiskers
    // appear along the torn boundary rather than in the solid interior.
    float edge = eroded * (1.0 - eroded) * 4.0;
    float fil  = 1.0 + AL_WATER_FOAM_FIL * edge * (mask * 2.0 - 1.0);
    // NOTE: `drive` is NOT applied again here — it is already baked into `v`, so
    // re-multiplying would square it and leave the foam far too sparse to see.
    return alSaturate(eroded * fil);
}

/*
============================================================================
 TRACK 2 — DYNAMIC ENVIRONMENT REFLECTION (sun/moon-aware, day/night-blended)
----------------------------------------------------------------------------
 alWaterSkyReflection evaluates the radiance the water reflects along a WORLD-
 space reflection vector. It exists to ERADICATE the flat hard-coded blue that
 water reflections used to fall back to: the colour returned here tracks the real
 time-of-day sky and both celestial bodies, continuously, with no `if (day)`
 branch anywhere.

 THREE additive parts, all from the pack's OWN atmosphere library (no second sky
 model, no LUT sampler — this file stays sampler-free, so the closed-form march is
 evaluated directly; consumers that DO own the sky-view LUT can still layer their
 alSkySample result over this):

   1. SKY DOME. alSkyRadiance(reflDir, sunDir) — the identical analytic single-
      scatter model prepare.fsh bakes into colortex6 — sampled along the reflected
      ray. This already contains the Rayleigh/Mie glow around BOTH the sun and the
      (anti-solar) moon, scaled here by SKY_BRIGHTNESS to match the baked LUT.

   2. SUN / MOON SPECULAR-ATMOSPHERIC RESPONSE, driven by the dot product of the
      reflection vector with each body's world direction (the brief's requirement:
      reflect . sunPosition and reflect . moonPosition). Each body gets TWO cosine
      lobes: a BROAD halo (the near-disc atmospheric brightening) and a TIGHT
      glint (the mirrored disc itself, which a screen-space trace can NEVER capture
      because the sun/moon disc is not in the depth buffer). The sun lobes use the
      pack's warm key colour alDirectColor(); the moon lobes use the cool AL_MOON_TINT.

   3. CONTINUOUS DAY/NIGHT CROSSFADE. The sun and moon responses are mixed by a
      day factor computed as alSmooth(smoothstep(-0.06, 0.16, sunDir.y)) — the
      EXACT ramp lib/lighting.glsl::alDayFactor uses (re-derived inline here so
      this file need not include the lighting lib, which would drag in colliding
      uniforms). smoothstep is C1 and alSmooth (a Hermite) keeps it C1 at the
      endpoints, so the sun glint hands over to the moon glint seamlessly through
      dawn/dusk — no discontinuity, no step, mathematically continuous as required.

 `highp` on the directions and the accumulator: these are world-space + celestial
 intermediates whose small angular differences (the tight glint) must not be
 crushed to 16 bits on Apple-silicon drivers.
============================================================================
*/
#define AL_WATER_REFL_SKY_GAIN        1.00   // sky-dome reflectance (dielectric water)
#define AL_WATER_REFL_SUN_BROAD_POW   14.0   // broad reflected-sun halo tightness
#define AL_WATER_REFL_SUN_BROAD_GAIN  0.55
#define AL_WATER_REFL_SUN_TIGHT_POW   320.0  // tight mirrored-sun-disc glint
#define AL_WATER_REFL_SUN_TIGHT_GAIN  6.0
#define AL_WATER_REFL_MOON_BROAD_POW  28.0   // broad reflected-moon halo
#define AL_WATER_REFL_MOON_BROAD_GAIN 0.28
#define AL_WATER_REFL_MOON_TIGHT_POW  440.0  // tight mirrored-moon-disc glint
#define AL_WATER_REFL_MOON_TIGHT_GAIN 1.7

vec3 alWaterSkyReflection(highp vec3 reflDir, highp vec3 sunDirWorld,
                          highp vec3 moonDirWorld) {
    reflDir      = normalize(reflDir);
    sunDirWorld  = normalize(sunDirWorld);
    moonDirWorld = normalize(moonDirWorld);

    // (1) Physical sky dome along the reflected ray (pack's own atmosphere model).
    highp vec3 sky = alSkyRadiance(reflDir, sunDirWorld) * SKY_BRIGHTNESS;

    // (2) Per-body specular/atmospheric response from reflect . body.
    highp float muSun  = max(dot(reflDir, sunDirWorld),  0.0);
    highp float muMoon = max(dot(reflDir, moonDirWorld), 0.0);
    vec3 sunCol  = alDirectColor(sunDirWorld);          // warm, atmosphere-tinted key
    vec3 moonCol = AL_MOON_TINT * 0.16 * SUN_INTENSITY;        // cool night key
    vec3 sunResp  = sunCol  * (AL_WATER_REFL_SUN_BROAD_GAIN  * pow(muSun,  AL_WATER_REFL_SUN_BROAD_POW)
                             + AL_WATER_REFL_SUN_TIGHT_GAIN  * pow(muSun,  AL_WATER_REFL_SUN_TIGHT_POW));
    vec3 moonResp = moonCol * (AL_WATER_REFL_MOON_BROAD_GAIN * pow(muMoon, AL_WATER_REFL_MOON_BROAD_POW)
                             + AL_WATER_REFL_MOON_TIGHT_GAIN * pow(muMoon, AL_WATER_REFL_MOON_TIGHT_POW));

    // (3) C1-continuous day/night crossfade (matches alDayFactor exactly).
    float day = alSmooth(smoothstep(-0.06, 0.16, sunDirWorld.y));
    vec3 bodies = mix(moonResp, sunResp, day);

    vec3 refl = sky * AL_WATER_REFL_SKY_GAIN + bodies;
    // NaN/Inf guard (comparisons, not isnan): never poison the blended surface.
    if (!all(greaterThanEqual(refl, vec3(0.0))) || !all(lessThan(refl, vec3(1e4)))) {
        refl = sky;
    }
    return max(refl, vec3(0.0));
}

#endif // AL_LIB_WATER
