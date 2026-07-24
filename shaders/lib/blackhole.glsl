#ifndef AL_LIB_BLACKHOLE
#define AL_LIB_BLACKHOLE

/*
 lib/blackhole.glsl — the End's sky (Phase 5, world1).

 NOTE (5.0.6): the procedural black hole was removed per field feedback. The End
 SKY is now just a DARK purple space + starfield (alEndBlackHoleSky, sky pixels
 only). The aurora lives in the WORLD as VOLUMETRIC WHISPS (alEndWhispDensity /
 alEndWhispMarch) — glowing violet vertical whisps raymarched in 3D space and
 bounded by the scene depth so terrain/pillars occlude them (no phasing). The
 END_BLACKHOLE_* option is kept dormant for a possible future return of the hole.

 Pure math, NaN-safe. Reuses lib/nightsky.glsl for the starfield + seamless FBM
 (which also owns the guarded frameTimeCounter declaration).
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/nightsky.glsl"

// Dark purple End space: a smooth gradient, darker toward the zenith.
vec3 alEndHaze(vec3 dir) {
    float up = alSaturate(dir.y * 0.5 + 0.5);
    return mix(AL_END_SPACE_LOW, AL_END_SPACE_HIGH, alSmooth(smoothstep(0.10, 0.95, up)));
}

/*
 Volumetric WHISPS — glowing violet whisps living in the End's 3D world space
 (NOT the skybox). alEndWhispDensity is the density (0..1) at a world position:
 sparse vertical columns (whisps) placed by seamless FBM in XZ, with a rising
 vertical structure so they travel upward and drift, undulating ethereally.
*/
float alEndWhispDensity(vec3 p, float time) {
    vec3 q = p * AL_END_WHISP_SCALE;
    q.xz += vec2(time * 0.015, time * 0.011);        // slow ethereal drift
    // Sparse vertical columns from an XZ noise field.
    float columns = alFbm3(vec3(q.xz, 17.0));
    columns = smoothstep(0.52, 0.82, columns);
    if (columns <= 0.001) return 0.0;
    // Rising vertical structure (animate along Y so whisps travel upward).
    float vert = alFbm3(vec3(q.xz * 1.7, q.y - time * AL_END_WHISP_RISE));
    return columns * smoothstep(0.42, 0.86, vert);
}

/*
 Raymarch the whisps from the camera along `dir`, BOUNDED by `marchDist` (the
 scene distance for terrain pixels, or the max reach for sky) so the End pillars
 and terrain correctly OCCLUDE whisps behind them — they no longer phase through.
 Pure additive glow (no extinction) for an ethereal look. `dither` offsets the
 first step to hide banding.
*/
vec3 alEndWhispMarch(vec3 camPos, vec3 dir, float marchDist, float time, float dither) {
    marchDist = min(marchDist, AL_END_WHISP_MAXDIST);
    if (marchDist <= 1.0) return vec3(0.0);
    const int STEPS = 14;
    float dt = marchDist / float(STEPS);
    float t  = dt * dither;
    float acc = 0.0;
    for (int i = 0; i < STEPS; i++) {
        acc += alEndWhispDensity(camPos + dir * t, time) * dt;
        t += dt;
    }
    return AL_END_WHISP_COLOR * (acc * AL_END_WHISP_GLOW);
}

/*
 Full End SKY for a world-space view direction (sky pixels only): dark purple
 space + a starfield. The aurora now lives in the world as volumetric whisps
 (alEndWhispMarch), NOT here. `size` is the dormant END_BLACKHOLE_SIZE (kept for
 call-site/option compatibility). `time` = frameTimeCounter (twinkle).
*/
vec3 alEndBlackHoleSky(vec3 dir, float size, float time) {
    dir = normalize(dir);
    vec3 col = alEndHaze(dir);
    col += alStarfield(dir) * 1.1;

    // NaN/negative guard (comparisons, not isnan — Apple-GL friendly).
    if (!all(greaterThanEqual(col, vec3(0.0))) || !all(lessThan(col, vec3(1.0e4)))) {
        col = alEndHaze(dir);
    }
    return max(col, vec3(0.0));
}

#endif // AL_LIB_BLACKHOLE
