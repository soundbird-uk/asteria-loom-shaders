#ifndef AL_LIB_BLACKHOLE
#define AL_LIB_BLACKHOLE

/*
 lib/blackhole.glsl — the End's sky (Phase 5, world1).

 NOTE (5.0.5): the procedural black hole was removed per field feedback ("get rid
 of it for now, it looks bad"). This file now renders the End sky as a DARK purple
 space with a procedural starfield and a flowing AURORA BOREALIS — curtains of
 lighter/darker purple that undulate and drift over time. The aurora is exposed
 (alEndAurora) so the fog pass can also veil it over the scene, so it reads
 "all around" — in the sky and in front of / behind geometry. The END_BLACKHOLE_*
 option is kept dormant for a possible future return of the hole.

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
 Flowing aurora borealis for a world-space view direction. Curtains hang in a
 mid-elevation arc, drift and undulate over time (warped by seamless FBM), with
 fine vertical striations (the "rays"). Colour runs from a deep violet in the
 faint parts to a lighter magenta-violet in the dense bright folds. Returns
 ADDITIVE linear HDR radiance; 0 outside the curtain band. Used for the sky AND
 (faintly) as a veil over the scene in world1/composite2.
*/
vec3 alEndAurora(vec3 dir, float time) {
    dir = normalize(dir);
    float el = dir.y;
    // Curtains occupy a mid arc: fade out below the horizon and toward the zenith.
    float env = smoothstep(-0.08, 0.12, el) * (1.0 - smoothstep(0.55, 0.95, el));
    if (env <= 0.001) return vec3(0.0);

    float az = atan(dir.z, dir.x);

    float amt   = 0.0;   // total curtain intensity (with thin bright rays)
    float dense = 0.0;   // curtain body density (drives light-vs-dark colour)
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        // Seamless flow warp (direction-sampled FBM), drifting with time.
        float warp = alFbm3(dir * (2.0 + fi)
                            + vec3(time * (0.03 + 0.015 * fi), fi * 5.0, time * 0.01));
        // Broad flowing curtain body.
        float body = 0.5 + 0.5 * sin(az * (1.5 + 0.6 * fi) + warp * 4.0
                                     + time * (0.05 + 0.02 * fi) + fi * 2.1);
        // Fine vertical striations (the moving rays of the curtain).
        float ray = 0.5 + 0.5 * sin(az * (24.0 + 9.0 * fi) + warp * 6.0 + time * 0.12);
        ray = ray * ray * ray;                       // thin bright rays
        amt   += body * ray;
        dense += body;
    }
    amt   = (amt / 3.0) * env;
    dense = alSaturate(dense / 3.0);

    // Lighter and darker purples.
    vec3 darkP  = vec3(0.22, 0.06, 0.42);
    vec3 lightP = vec3(0.62, 0.34, 1.00);
    vec3 col = mix(darkP, lightP, dense);
    return max(col * (amt * AL_END_AURORA_STR), vec3(0.0));
}

/*
 Full End sky for a world-space view direction. `size` is the dormant
 END_BLACKHOLE_SIZE (kept for call-site/option compatibility; unused while the
 hole is disabled). `time` = frameTimeCounter (aurora + twinkle animation).
*/
vec3 alEndBlackHoleSky(vec3 dir, float size, float time) {
    dir = normalize(dir);
    vec3 col = alEndHaze(dir);
    col += alStarfield(dir) * 1.1;
    col += alEndAurora(dir, time);

    // NaN/negative guard (comparisons, not isnan — Apple-GL friendly).
    if (!all(greaterThanEqual(col, vec3(0.0))) || !all(lessThan(col, vec3(1.0e4)))) {
        col = alEndHaze(dir);
    }
    return max(col, vec3(0.0));
}

#endif // AL_LIB_BLACKHOLE
