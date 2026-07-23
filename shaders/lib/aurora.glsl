#ifndef AL_LIB_AURORA
#define AL_LIB_AURORA

/*
 lib/aurora.glsl — woven-band aurora (Phase 5, world0). LOOM agent.

 A soft aurora borealis rendered additively over the atmosphere in the sky pass
 (gbuffers_skybasic), next to the procedural night sky. It appears ONLY on clear
 cold nights — the Loom motif "woven curtains" of light:
   - a few flowing vertical curtains localized in azimuth, drifting slowly;
   - each curtain shaped by seamless FBM folds + thin vertical striations (the
     "rays" of the curtain) — the woven look;
   - a height-graded colour: green-teal core low, violet fringe up high;
   - kept BELOW the moon/star brightness so it reads dreamy, never neon.

 GATING (all three required, each a soft ramp):
   - DEEP NIGHT   : nightFactor high (well after sunset);
   - COLD BIOME   : Iris `temperature` low (snowy/cold) — aurora ~= polar;
   - CLEAR SKY    : rainStrength ~ 0 (no rain/snowfall veiling the sky).
 Fades out at the horizon and toward the zenith (curtains hang in a mid arc).

 Reuses lib/nightsky.glsl's seamless 3D value-noise FBM (alFbm3) and its
 frameTimeCounter declaration (the undulation clock) — nightsky is include-guard
 safe, so including it here is free wherever skybasic already pulled it in.

 Public interface:
     vec3 alAurora(vec3 worldDir, float nightFactor, float temperature, float rain)
 Returns ADDITIVE linear HDR radiance (vec3(0.0) when off / out of band).
 Pure math, no samplers, NaN-safe (guarded normalize / seamless dir-sampled FBM
 so no azimuth-seam discontinuity / final range guard). Behind `#ifdef AURORA`.
*/

#include "/lib/common.glsl"
// nightsky provides alFbm3 (seamless FBM) + the frameTimeCounter declaration.
// Keep this a bare include line — the flattener only matches `#include "..."`
// with nothing after the closing quote.
#include "/lib/nightsky.glsl"

vec3 alAurora(vec3 worldDir, float nightFactor, float temperature, float rain) {
#ifdef AURORA
    float len = length(worldDir);
    if (len < 1.0e-6) return vec3(0.0);
    vec3 dir = worldDir / len;

    // --- Gating: deep, cold, clear -------------------------------------------
    float night = smoothstep(0.35, 0.85, clamp(nightFactor, 0.0, 1.0));
    float cold  = smoothstep(0.30, 0.12, temperature);      // 1 in snowy/cold biomes
    float clear = 1.0 - alSaturate(rain);
    float gate  = night * cold * clear;
    if (gate <= 0.001) return vec3(0.0);

    // --- Elevation band: curtains hang in a mid arc --------------------------
    float el = dir.y;
    if (el <= 0.03) return vec3(0.0);                       // above horizon only
    float band = smoothstep(0.03, 0.22, el)
               * (1.0 - smoothstep(0.55, 0.90, el));
    if (band <= 0.001) return vec3(0.0);

    float t  = frameTimeCounter;
    float az = atan(dir.z, dir.x);                          // -pi..pi (periodic)

    // --- Curtains: a few flowing azimuthal lobes with woven vertical rays ----
    float curtains = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);

        // Slowly drifting curtain centre azimuth.
        float centre = (fi * 2.4 - 2.4) + 0.25 * sin(t * (0.03 + 0.008 * fi) + fi);
        float da = az - centre;
        da = mod(da + AL_PI, AL_TAU) - AL_PI;               // wrap to (-pi,pi]
        float lobe = exp(-(da * da) / (2.0 * 0.35 * 0.35)); // soft azimuthal lobe
        if (lobe < 0.002) continue;

        // Seamless folds: FBM sampled on the DIRECTION (no azimuth seam), drifting
        // in time via a z offset — the slow undulation of the curtain body.
        float fold = alFbm3(dir * 5.0 + vec3(fi * 11.0, 0.0, t * 0.04));

        // Thin vertical striations (the woven rays). Integer angular frequencies
        // (7*fi added to 26) stay continuous across the az = +/-pi seam.
        float ray = 0.5 + 0.5 * sin(az * (26.0 + 6.0 * fi) + fold * 6.0 + t * 0.2);
        ray = pow(ray, 4.0);                                // thin bright ridges

        curtains += lobe * mix(0.35, 1.0, fold) * ray;
    }
    curtains /= 3.0;

    // --- Height-graded colour: green-teal core -> violet fringe --------------
    float up = alSaturate((el - 0.10) / 0.50);
    vec3  core   = vec3(0.10, 0.85, 0.55);                  // green-teal
    vec3  fringe = vec3(0.45, 0.20, 0.85);                  // violet
    vec3  col    = mix(core, fringe, smoothstep(0.25, 0.90, up));

    col *= curtains * band * gate * AL_AURORA_STRENGTH;

    // NaN/negative guard (comparisons, not isnan — Apple-GL friendly).
    col = max(col, vec3(0.0));
    if (!(col.r <= 1.0e4) || !(col.g <= 1.0e4) || !(col.b <= 1.0e4)) return vec3(0.0);
    return col;
#else
    return vec3(0.0);
#endif
}

#endif // AL_LIB_AURORA
