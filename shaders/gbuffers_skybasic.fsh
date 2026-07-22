#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/nightsky.glsl"

/*
 gbuffers_skybasic (fragment) — the physically based sky. Replaces the Phase-1
 vanilla gradient with:
   1. the baked atmosphere sky (alSkySample from the colortex6 LUT tile),
   2. a procedural, limb-darkened HDR sun disc (blooms in Phase 4, tonemaps
      cleanly now), and
   3. the procedural night sky (alNightSky, additive) from the NIGHT SKY lib.

 Iris draws the sky gradient, the void plane AND the vanilla stars through this
 same program, distinguished by renderStage. We SUPPRESS vanilla stars (the
 procedural night sky owns them) but keep the void plane, which now renders the
 atmosphere's horizon/below-horizon colour instead of a black band.

 Sampler count: 1 (colortex6, via lib/atmosphere.glsl). lib/nightsky.glsl and
 lib/atmosphere_common.glsl are pure math (no samplers).
*/

uniform int renderStage;
uniform vec3 sunPosition;               // view space, toward the sun
uniform mat4 gbufferModelViewInverse;

in vec3 worldDir;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // Kill ONLY the vanilla stars — the procedural night sky replaces them.
    if (renderStage == MC_RENDER_STAGE_STARS) {
        discard;
    }

    vec3 dir    = normalize(worldDir);
    vec3 sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);

    // --- Base atmosphere (baked LUT) --------------------------------------
    vec3 sky = alSkySample(dir);

    // --- Procedural night sky (additive, fades in as the sun sets) --------
    // nightFactor: 0 in full day, 1 well after sunset.
    float nightFactor = smoothstep(0.04, -0.10, sunDir.y);
    sky += alNightSky(dir, nightFactor);

    // --- Procedural HDR sun disc ------------------------------------------
    // Only above the horizon and only when the sun is up; limb-darkened so the
    // rim reads softer than the core.
    float sunCos = clamp(dot(dir, sunDir), -1.0, 1.0);
    float ang    = acos(sunCos);
    float radius = AL_SUN_ANGULAR_RADIUS * SUN_DISC_SIZE;
    if (ang < radius) {
        float x    = ang / max(radius, 1e-4);            // 0 centre .. 1 rim
        float mu   = sqrt(max(1.0 - x * x, 0.0));        // cos of disc position
        float limb = 0.40 + 0.60 * pow(mu, 0.5);         // limb darkening
        float above = smoothstep(-0.02, 0.06, sunDir.y); // fade at/under horizon
        // Warm sun colour from the same atmosphere-driven direct term the
        // lighting uses, so the disc matches the light on the terrain.
        vec3 discCol = alDirectColor(sunDir);
        sky += discCol * (limb * SUN_DISC_BRIGHTNESS * above);
    }

    // Guard against any stray non-finite value reaching the HDR buffer.
    if (!all(greaterThanEqual(sky, vec3(0.0))) || !all(lessThan(sky, vec3(1e5)))) {
        sky = vec3(0.0);
    }

    outColor = vec4(sky, 1.0);
}
