#ifndef AL_LIB_CLOUDS_COMMON
#define AL_LIB_CLOUDS_COMMON

/*
 lib/clouds_common.glsl — SAMPLER-FREE cloud coverage + cheap cloud shadow.

 This file is included by lib/lighting.glsl (and therefore by EVERY lighting
 consumer: the deferred lighting pass and all forward translucent passes), so
 it must be dirt cheap and add ZERO samplers. Only plain uniforms are declared
 here, and only ones NO lighting consumer already declares — verified:
 rainStrength / frameTimeCounter / sunAngle are declared nowhere else, so
 declaring them here cannot collide. It must NOT reference sunPosition /
 shadowLightPosition / gbufferModelViewInverse / cameraPosition (those ARE
 declared by the consumers, and re-declaring would be a duplicate-uniform
 error), which is why the cloud shadow derives its own APPROXIMATE world sun
 direction from sunAngle instead of the shadow-map light matrix.

 Two exports:
   float alCloudCoverage2D(vec2 worldXZ)  — 2D FBM value-noise coverage field in
     [0,1], wind-drifted, pure hash math (no noisetex). Shared verbatim by the
     volumetric raymarch (lib/clouds.glsl) so cloud shapes and their ground
     shadows always agree.
   float alCloudShadow(vec3 worldPos)     — 1.0 = full sun, <1 under a cloud.
     Traces the sun ray from worldPos to the cumulus mid-plane, samples the
     coverage there, smooths and weights by weather. <=1 coverage evaluation.
     Behind #ifdef VOLUMETRIC_CLOUDS; a `return 1.0;` fallback is ALWAYS
     compiled when the define is off so lighting links either way.
*/

#include "/lib/common.glsl"

// Plain uniforms (NOT samplers). See header for the no-collision rationale.
uniform float rainStrength;
uniform float frameTimeCounter;
uniform float sunAngle;            // Iris: 0..1 over the full day (0 = sunrise)

// --- 2D value-noise hash + FBM ---------------------------------------------
// Pure-math hash (no bit ops — GL 3.30/4.1 safe on the Apple path).
float alCloudHash21(vec2 p) {
    p = fract(p * vec2(0.1031, 0.11369));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float alCloudValue2D(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);            // smoothstep interpolation
    float a = alCloudHash21(i + vec2(0.0, 0.0));
    float b = alCloudHash21(i + vec2(1.0, 0.0));
    float c = alCloudHash21(i + vec2(0.0, 1.0));
    float d = alCloudHash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Coverage wind: a steady drift in the noise domain so clouds roll across the
// sky. frameTimeCounter wraps (~1h) but the FBM is continuous, so no visible
// jump. Shared by the raymarch and the shadow => shapes and shadows move
// together.
vec2 alCloudWind() {
    return vec2(1.0, 0.35) * (frameTimeCounter * AL_CLOUD_WIND_SPEED);
}

// 2D FBM coverage field in [0,1] (amplitude-normalised).
float alCloudCoverage2D(vec2 worldXZ) {
    vec2 p = worldXZ * AL_CLOUD_COVERAGE_SCALE + alCloudWind();
    float f = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    float norm = 0.0;
    for (int i = 0; i < AL_CLOUD_COVERAGE_OCTAVES; i++) {
        f    += amp * alCloudValue2D(p * freq);
        norm += amp;
        freq *= 2.0;
        amp  *= 0.5;
    }
    return f / max(norm, 1e-4);
}

// EXACT world-space SUN direction, pure math from the sunAngle uniform (no
// samplers, no sunPosition / gbufferModelViewInverse — which lighting consumers
// already own). Re-derived from Iris' CelestialUniforms: Iris sunAngle =
// skyAngle + 0.25, so theta = skyAngle*360deg = (sunAngle - 0.25)*TAU, and with
// the pack's sunPathRotation tilt phi (degrees, from settings.glsl — the SAME
// const the atmosphere uses):
//     sun = ( -sin(theta), cos(theta)*cos(phi), -cos(theta)*sin(phi) )
// The magnitude is identically 1 (sin^2+cos^2), so no normalize is required.
// Checks: noon  (sunAngle=0.25) -> (0, 0.819, 0.574) for phi=-35deg;
//         sunrise(sunAngle=0.00) -> (1, 0, 0).
// This is now EXACT (not an approximation): the raymarch phase, the sun colour
// and the cloud shadow all match the true sun disc and terrain-shadow azimuth.
vec3 alSunDirWorld() {
    float theta = (sunAngle - 0.25) * AL_TAU;
    float phi   = sunPathRotation * (AL_PI / 180.0);
    float st = sin(theta);
    float ct = cos(theta);
    return vec3(-st, ct * cos(phi), -ct * sin(phi));
}

// Backwards-compatible alias (gbuffers_skybasic and composite.fsh call this
// name). Kept so external callers stay valid; now resolves to the EXACT dir.
vec3 alApproxSunDirWorld() { return alSunDirWorld(); }

// --- Cheap cloud shadow -----------------------------------------------------
// Uses the EXACT world sun direction, so ground cloud-shadows align with both
// the visible sun disc and the terrain shadow-map azimuth.
float alCloudShadow(vec3 worldPos) {
#ifdef VOLUMETRIC_CLOUDS
    vec3 sunDir = alSunDirWorld();

    // Sun below the horizon -> no sun-cast cloud shadow (moon shadows ignored).
    if (sunDir.y < 0.05) return 1.0;

    // Pierce point where the sun ray from worldPos meets the cumulus mid-plane.
    float midAlt = 0.5 * (AL_CLOUD_CUMULUS_BOT + AL_CLOUD_CUMULUS_TOP);
    float t = (midAlt - worldPos.y) / sunDir.y;
    if (t <= 0.0) return 1.0;                    // already above the cloud layer

    vec2  pierce = worldPos.xz + sunDir.xz * t;
    float cov    = alCloudCoverage2D(pierce);

    // Weather-aware coverage threshold (matches the raymarch's).
    float coverage = clamp(VC_COVERAGE + rainStrength * AL_CLOUD_STORM_BOOST,
                           0.0, 0.95);
    float lo = 1.0 - coverage;
    float cloudAmt = smoothstep(lo, lo + AL_CLOUD_EDGE, cov);

    // Fade the shadow out as the sun nears the horizon (grazing = weak shadow).
    float elevFade = alSaturate(sunDir.y * 4.0);
    float strength = mix(AL_CLOUD_SHADOW_CLEAR, AL_CLOUD_SHADOW_STORM,
                         rainStrength) * elevFade;

    return 1.0 - cloudAmt * strength;
#else
    return 1.0;
#endif
}

#endif // AL_LIB_CLOUDS_COMMON
