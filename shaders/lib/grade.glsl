#ifndef AL_LIB_GRADE
#define AL_LIB_GRADE

/*
 lib/grade.glsl — biome-adaptive grading + weather storytelling (brief §3, §6).

 Applied in final.fsh AFTER AgX, in display-linear [0,1] space (so the shifts
 are perceptual and gentle). Everything here is deliberately SUBTLE — the pack's
 identity and the field-approved levels come from lighting/atmosphere/tonemap;
 the grade only nudges mood by biome and weather (<=10% shifts, contract §6).
 Pure GLSL 3.30, no samplers — all driven by Iris uniforms passed in.

 Biome categories: the biome_category uniform is BiomeCategories.ordinal()
 (verified in lib/fog.glsl's header against Iris BiomeUniforms.java). We keep a
 local copy of the ordinals (AL_GCAT_*) so this file is include-independent of
 lib/fog.glsl (final.fsh does not pull the fog/atmosphere chain).
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"

// biome_category ordinals (see lib/fog.glsl header for provenance).
#define AL_GCAT_TAIGA   1
#define AL_GCAT_JUNGLE  3
#define AL_GCAT_MESA    4
#define AL_GCAT_SAVANNA 6
#define AL_GCAT_ICY     7
#define AL_GCAT_DESERT  12
#define AL_GCAT_SWAMP   14

// Master gate — same rationale as AL_FOG_BIOME_UNIFORMS: if the biome uniforms
// ever change semantics, flip this off and the grade degrades to weather-only.
#define AL_GRADE_BIOME_UNIFORMS

// Saturation about Rec.709 luminance. amount<1 desaturates, >1 boosts.
vec3 alGradeSaturation(vec3 c, float amount) {
    float l = alLuminance(c);
    return max(mix(vec3(l), c, amount), vec3(0.0));
}

// Gentle shadow lift: raises the toe without touching highlights (adds `amt` to
// darks, feathered out by ~0.5). Used by rain (softer, lifted-shadow mood).
vec3 alGradeLiftShadows(vec3 c, float amt) {
    vec3 t = alSaturate(1.0 - c * 2.0);   // 1 in blacks -> 0 by mid-grey
    return c + amt * t * t;
}

/*
 Biome grade. Category picks a signature nudge; temperature/rainfall add a
 smooth continuous cold->cool / hot-arid->warm bias so biomes without a special
 case still read subtly. All multipliers stay within ~[0.92, 1.08].
*/
vec3 alGradeBiome(vec3 c, int cat, float temperature, float rainfall) {
#ifdef AL_GRADE_BIOME_UNIFORMS
    vec3  tint = vec3(1.0);
    float sat  = 1.0;

    if (cat == AL_GCAT_DESERT || cat == AL_GCAT_MESA || cat == AL_GCAT_SAVANNA) {
        // Golden, sun-baked.
        tint = vec3(1.05, 1.01, 0.94);
        sat  = 1.03;
    } else if (cat == AL_GCAT_SWAMP) {
        // Mossy, murky green — slightly desaturated + green-lifted.
        tint = vec3(0.97, 1.02, 0.96);
        sat  = 0.94;
    } else if (cat == AL_GCAT_ICY || cat == AL_GCAT_TAIGA) {
        // Crisp cool — cool tint + a touch more saturation for a clean look.
        tint = vec3(0.96, 0.99, 1.06);
        sat  = 1.04;
    } else if (cat == AL_GCAT_JUNGLE) {
        // Lush — richer greens, gentle saturation lift.
        tint = vec3(0.98, 1.03, 0.97);
        sat  = 1.06;
    }

    // Continuous fallback bias (applies to ALL biomes, small). Uses the same
    // temperature/rainfall drivers as the fog agent for a consistent world tone.
    float cold = alSaturate((0.30 - temperature) / 0.60);            // up to ~0.5
    float arid = alSaturate((0.30 - rainfall) / 0.40)
               * alSaturate((temperature - 0.80) / 0.60);            // hot & dry
    tint *= mix(vec3(1.0), vec3(0.97, 0.99, 1.04), cold * 0.6);      // cool
    tint *= mix(vec3(1.0), vec3(1.05, 1.01, 0.95), arid * 0.6);      // warm

    c = alGradeSaturation(c, sat);
    c *= tint;
    return alSaturate(c);
#else
    return c;
#endif
}

/*
 Weather storytelling.
   rainStrength   : desaturate ~15%, cool tint, lift shadows, soften contrast.
   thunderStrength: darker, steelier (on top of rain).
   wetness        : post-rain "afterglow" — as wetness decays after the rain has
                    stopped (wetness high, rainStrength falling), a small
                    saturation + warmth lift makes the world read freshly-washed.
   lightningFlash : [0,1] full-frame cool-white lift (~+15% at full), driven by
                    lightningBoltPosition.w in final.
*/
vec3 alGradeWeather(vec3 c, float rainStrength, float thunderStrength,
                    float wetness, float lightningFlash) {
    float rain = alSaturate(rainStrength);
    float thunder = alSaturate(thunderStrength);

    if (rain > 0.001) {
        // Desaturate up to 15%, cool tint, softly lift shadows.
        c = alGradeSaturation(c, mix(1.0, 0.85, rain));
        c *= mix(vec3(1.0), vec3(0.96, 0.99, 1.05), rain);
        c = alGradeLiftShadows(c, 0.03 * rain);
    }
    if (thunder > 0.001) {
        // Steely and darker — pull toward a cool grey, dim slightly.
        vec3 steel = vec3(0.85, 0.88, 0.95);
        c = mix(c, c * steel, thunder);
    }

    // Afterglow: strongest when it JUST stopped raining (wetness high, rain low).
    float afterglow = alSaturate(wetness) * (1.0 - rain);
    if (afterglow > 0.001) {
        c = alGradeSaturation(c, 1.0 + 0.06 * afterglow);
        c *= mix(vec3(1.0), vec3(1.02, 1.01, 0.99), afterglow);
    }

    // Lightning flash — brief cool-white full-frame lift.
    float flash = alSaturate(lightningFlash);
    if (flash > 0.001) {
        c = mix(c, c + vec3(0.13, 0.14, 0.17), flash);
    }

    return alSaturate(c);
}

#endif // AL_LIB_GRADE
