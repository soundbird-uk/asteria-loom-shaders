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

// Purple End space: a clearly-visible smooth gradient — a richer violet along the
// horizon fading to a deep near-black purple at the zenith. The smoothstep spans
// the full visible dome (0.35..1.0 of the up factor, i.e. the horizon and above)
// so the gradient reads across the whole sky rather than only in a thin band.
vec3 alEndHaze(vec3 dir) {
    float up = alSaturate(dir.y * 0.5 + 0.5);
    return mix(AL_END_SPACE_LOW, AL_END_SPACE_HIGH, alSmooth(smoothstep(0.35, 1.0, up)));
}

/*
 Volumetric WHISPS — glowing violet whisps living in the End's 3D world space
 (NOT the skybox). TWO independent layers give the ethereal look:
   LARGE — wide, sparse, VERY see-through columns (medium purple).
   FINE  — tiny, thin, more numerous, lighter and MORE glowing whisps.
 Each is a sparse vertical column field placed by seamless FBM in XZ with a rising
 vertical structure (animate along Y so they drift upward, undulating ethereally).
 A vertical ENVELOPE fades them in above the base and out gently toward the top so
 they never abruptly stop high up.
*/

// Vertical fade: in above BASE, out gradually over TOP_FADE below TOP.
float alEndWhispEnv(float y) {
    float fadeIn  = smoothstep(AL_END_WHISP_BASE_Y, AL_END_WHISP_BASE_Y + 25.0, y);
    float fadeOut = 1.0 - smoothstep(AL_END_WHISP_TOP_Y - AL_END_WHISP_TOP_FADE,
                                     AL_END_WHISP_TOP_Y, y);
    return alSaturate(fadeIn * fadeOut);
}

float alEndWhispLarge(vec3 p, float time) {
    vec3 q = p * AL_END_WHISP_SCALE_L;
    q.xz += vec2(time * 0.015, time * 0.011);
    float col = alFbm3(vec3(q.xz, 17.0));
    col = smoothstep(0.56, 0.86, col);               // sparse wide columns
    if (col <= 0.001) return 0.0;
    float vert = alFbm3(vec3(q.xz * 1.6, q.y - time * AL_END_WHISP_RISE_L));
    return col * smoothstep(0.45, 0.90, vert);
}

float alEndWhispFine(vec3 p, float time) {
    vec3 q = p * AL_END_WHISP_SCALE_F;
    q.xz += vec2(-time * 0.020, time * 0.016);
    float col = alFbm3(vec3(q.xz, 41.0));
    col = smoothstep(0.70, 0.93, col);               // sparser + thinner
    if (col <= 0.001) return 0.0;
    float vert = alFbm3(vec3(q.xz * 2.4, q.y - time * AL_END_WHISP_RISE_F));
    return col * smoothstep(0.60, 0.96, vert);
}

/*
 Raymarch BOTH whisp layers from the camera along `dir`, BOUNDED by `marchDist`
 (scene distance for terrain, max reach for sky) so pillars/terrain OCCLUDE whisps
 behind them. Each layer accumulates emission-with-absorption independently (front-
 to-back), so its returned glow is BOUNDED to COL*GLOW (saturated purple, sub-1 =>
 never white) and LOW densities keep both layers very SEE-THROUGH. `dither` offsets
 the first step to hide banding.
*/
vec3 alEndWhispMarch(vec3 camPos, vec3 dir, float marchDist, float time, float dither) {
    marchDist = min(marchDist, AL_END_WHISP_MAXDIST);
    if (marchDist <= 1.0) return vec3(0.0);
    const int STEPS = 20;
    float dt = marchDist / float(STEPS);
    float t  = dt * dither;
    float transL = 1.0, transF = 1.0;    // per-layer transmittance
    float litL = 0.0, litF = 0.0;        // per-layer emission weight, each <= 1
    for (int i = 0; i < STEPS; i++) {
        vec3  sp  = camPos + dir * t;
        float env = alEndWhispEnv(sp.y);
        if (env > 0.001) {
            if (transL > 0.02) {
                float dL = alEndWhispLarge(sp, time) * env;
                if (dL > 0.001) {
                    float a = 1.0 - exp(-dL * AL_END_WHISP_DENS_L * dt);
                    litL += transL * a; transL *= (1.0 - a);
                }
            }
            if (transF > 0.02) {
                float dF = alEndWhispFine(sp, time) * env;
                if (dF > 0.001) {
                    float a = 1.0 - exp(-dF * AL_END_WHISP_DENS_F * dt);
                    litF += transF * a; transF *= (1.0 - a);
                }
            }
        }
        t += dt;
    }
    return AL_END_WHISP_COL_L * (litL * AL_END_WHISP_GLOW_L)
         + AL_END_WHISP_COL_F * (litF * AL_END_WHISP_GLOW_F);
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
