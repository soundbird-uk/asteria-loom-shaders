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
   vec3  alWaterWaveNormal(vec3 worldPos, float t, float strength)
       — directional wind-aligned ripple normal in a world Y-UP frame (assumes a
         near-horizontal water surface; the caller reorients for undersides and
         blends only where the surface is roughly flat). 2-3 octaves of scrolling
         value-noise + a directional swell, gentle amplitude for the dreamy look.
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

// --- Wave height field ------------------------------------------------------
// Wind direction matches the clouds' drift dir (lib/clouds_common alCloudWind =
// vec2(1.0, 0.35)) so water ripples and cloud shadows read as ONE weather
// system. normalize(vec2(1.0, 0.35)) = vec2(0.94388, 0.33036).
float alWaterHeight(vec2 wp, float t) {
    const vec2 wind = vec2(0.94388, 0.33036);
    float h = 0.0, amp = 0.5, norm = 0.0, freq = AL_WATER_WAVE_SCALE;
    for (int i = 0; i < AL_WATER_WAVE_OCTAVES; i++) {
        // Each octave scrolls along the wind, finer octaves a touch faster.
        vec2 sp = wp * freq + wind * (t * AL_WATER_WAVE_SPEED * (1.0 + float(i) * 0.7));
        float n = alWaterValue2D(sp) * 2.0 - 1.0;             // [-1,1] chop
        // Directional swell: a low sine aligned to the wind gives the coherent
        // wind-driven ridges the pure noise lacks.
        float swell = sin(dot(wp, wind) * freq * AL_TAU + t * AL_WATER_WAVE_SPEED * 2.0);
        h    += amp * mix(n, swell, 0.35);
        norm += amp;
        freq *= 2.0;
        amp  *= 0.5;
    }
    return h / max(norm, 1e-4);
}

// Ripple normal in the world Y-up frame (central differences on the height).
// `strength` scales the horizontal gradient (ripple amplitude); 1.0 = the tuned
// look, smaller = calmer.
vec3 alWaterWaveNormal(vec3 worldPos, float t, float strength) {
    vec2 wp = worldPos.xz;
    float e = AL_WATER_NORMAL_EPS;
    float h0 = alWaterHeight(wp, t);
    float hx = alWaterHeight(wp + vec2(e, 0.0), t);
    float hz = alWaterHeight(wp + vec2(0.0, e), t);
    float dhdx = (hx - h0) / e;
    float dhdz = (hz - h0) / e;
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
