#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/nightsky.glsl"
// world1 End: procedural black-hole sky (must stay a bare include line — the
// pack's include-flattener only matches `#include "..."` with nothing trailing).
#include "/lib/blackhole.glsl"

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
    // END (world1): the full procedural black-hole sky is painted fullscreen in
    // world1/composite2 (per-pixel view ray -> reliable coverage). Here we only
    // suppress the vanilla End stars/void and lay down the purple haze as a cheap
    // fallback for any sky pixel composite2 might not reach; composite2 overwrites
    // it with the black hole + starfield everywhere depth == 1.
    if (renderStage == MC_RENDER_STAGE_STARS) discard;
    outColor = vec4(alEndHaze(normalize(worldDir)), 1.0);
    return;

    vec3 dir    = normalize(worldDir);
    vec3 sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);

    // --- Base atmosphere (baked LUT) --------------------------------------
    vec3 sky = alSkySample(dir);

#ifdef AL_DBG_FLATSKY
    // DIAGNOSTIC: replace the whole sky with a flat dark grey. If the "horizon
    // band" disappears with this on, the band IS the atmosphere sky LUT (and the
    // other-dimension bleed is the overworld LUT drawn everywhere -> world folders).
    outColor = vec4(vec3(0.03, 0.03, 0.05), 1.0);
    return;
#endif

#ifndef AL_DBG_NO_SKYFILL
    // --- Ground / horizon haze fill (ISSUE 13: "void under the horizon") --
    // Below the horizon the analytic atmosphere goes dim (ground-scattered), which
    // reads as a dark VOID band under the world and a hard seam behind distant
    // terrain. Fill the below-horizon hemisphere with the haze sampled AT the
    // horizon so the world sits against continuous atmosphere (not a void) and the
    // horizon line sits BEHIND terrain, melting into the aerial fog. It tracks time
    // of day for free (the horizon sample darkens at night), so it never glows.
    if (dir.y < 0.0) {
        // Sample the haze just ABOVE the horizon and fill the whole below-horizon
        // hemisphere with it, fully by ~9 deg down, so the world sits against a
        // continuous haze band (no dark void) and the horizon sits behind terrain.
        // Tracks time of day for free (dark at night). 0.4.4: strengthened to a
        // full seal (was 0.9 partial) so the void is never visible.
        vec3  horizonHaze = alSkySample(vec3(dir.x, 0.02, dir.z));
        float below = smoothstep(0.0, -0.16, dir.y);      // 0 at horizon -> 1 down
        sky = mix(sky, horizonHaze, below);
    }
#endif // AL_DBG_NO_SKYFILL

    // --- Horizon-band softening (0.4.5b — confirmed via Debug View 11) -----
    // Tame the harsh, over-bright, yellow-green astronomical-horizon band into a
    // soft haze so it no longer cuts a hard line across the scene above distant
    // terrain. Strongest exactly at the horizon (|dir.y| ~ 0), gone by ~11 deg up.
    // The DESAT (neutralise the yellow-green) is gated to HIGH sun so sunrise /
    // sunset keep their warm glow; the DIM applies at all times. Applied to the
    // SKY only (terrain is shaded elsewhere), before the additive night sky / sun
    // disc so those stay bright.
    {
        float horizonBand = 1.0 - smoothstep(0.0, AL_SKY_HORIZON_WIDTH, abs(dir.y));
        float sunHigh     = smoothstep(0.12, 0.35, sunDir.y);   // 1 at midday
        sky = mix(sky, vec3(alLuminance(sky)),
                  horizonBand * AL_SKY_HORIZON_DESAT * sunHigh);
        sky *= mix(1.0, AL_SKY_HORIZON_DIM, horizonBand);
    }

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
