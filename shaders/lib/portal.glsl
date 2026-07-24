#ifndef AL_LIB_PORTAL
#define AL_LIB_PORTAL

/*
 lib/portal.glsl — revamped Nether + End portal looks (Phase 5 extra).

 Self-contained (own value noise, no external noise dependency) so it can be
 included by the forward gbuffers programs without dragging in the night-sky /
 cloud libs. Pure GLSL 3.30 math, NaN-safe.

   alNetherPortal — a DEEP swirling violet portal: layered parallax swirl (a
     sense of looking into it), emissive glow, and a Fresnel edge sheen (a fake
     reflection at grazing angles).
   alEndPortal    — a 3D parallax STARFIELD in the portal surface (revamped
     vanilla look) with an ethereal glow, replacing the flat black.
*/

#include "/lib/common.glsl"

float alPortHash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float alPortNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(alPortHash(i),               alPortHash(i + vec2(1.0, 0.0)), f.x),
               mix(alPortHash(i + vec2(0.0,1.0)), alPortHash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float alPortFbm(vec2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * alPortNoise(p); p *= 2.02; a *= 0.5; }
    return s;
}

// Deep swirling Nether portal. planePos = coords in the portal plane; parallax =
// view offset in the plane (drives the depth illusion); fres = Fresnel 0..1.
// Returns linear HDR colour + alpha.
//
// 5.0.8 REWORK ("too opaque, no reflections, needs water-like tricks"): more
// parallax DEPTH (4 layers, larger view-driven offsets => a real look INTO the
// portal), a lower & swirl-driven ALPHA so the deep interior reads see-through
// while the bright veins stay solid, and a stronger Fresnel-driven "reflection"
// sheen (a specular-like violet rim at grazing angles, the water trick) plus a
// bright inner core so the veins glow like molten light.
vec4 alNetherPortal(vec2 planePos, vec2 parallax, float fres, float time) {
    float swirl = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float depth = 0.18 + 0.55 * fi;                       // deeper parallax layers
        vec2 sc = planePos * 0.7 + parallax * depth
                + vec2(0.03 * time, -time * (0.06 + 0.05 * fi));   // rising swirl
        swirl += (0.6 / (fi + 1.0)) * alPortFbm(sc + fi * 3.1);
    }
    swirl = alSaturate(swirl * 1.25);
    // Fine bright filaments threading through the swirl (molten veins).
    float veins = alSaturate(pow(swirl, 3.0) * 1.6);

    // 5.0.10 ("not see-through, not pretty like water"): a DEEP dark-violet body
    // (low emissive so it no longer reads as a flat glowing sheet), with only the
    // veins genuinely glowing, and a LOW base alpha so you look INTO the depth like
    // water — the veins/edges stay solid. The Fresnel sheen is the grazing
    // "reflection" (water trick).
    vec3 deep   = vec3(0.05, 0.012, 0.16);                    // very dark violet depth
    vec3 mids   = vec3(0.38, 0.11, 0.70);
    vec3 bright = vec3(0.85, 0.48, 1.00);
    vec3 col = mix(deep, mids, swirl * swirl);                // deep body, NOT overbright
    col += bright * (veins * 0.9);                            // glowing molten filaments
    // Fresnel "reflection" sheen — a grazing-angle violet specular (water trick),
    // moderate so the swirl still reads through it.
    float f = fres * fres;
    col += vec3(0.55, 0.40, 1.00) * (f * 0.9);
    // Alpha: SEE-THROUGH in the dark deep (look into it), solid on the veins/edges.
    float alpha = alSaturate(mix(0.30, 0.85, max(veins, f)) + swirl * 0.08);
    return vec4(col, alpha);
}

// Revamped End portal — a deep parallax starfield with ethereal glow. planePos =
// coords in the portal plane; parallax offsets the deeper star layers for a real
// 3D-into-the-floor look. Returns linear HDR colour.
//
// 5.0.8 REWORK ("end portal is completely black; needs more particles"): a richer
// violet base + a swirling nebula glow so it is NEVER black, MORE and denser star
// particles across 6 parallax layers (lower threshold + brighter twinkle), and a
// soft additive purple bloom base. Even with zero stars in view the base + nebula
// keep it clearly a glowing deep-space portal.
vec3 alEndPortal(vec2 planePos, vec2 parallax, float time) {
    // Swirling violet nebula base (guarantees it is never black, adds depth).
    vec2  nb  = planePos * 0.9 + parallax * 0.25 + vec2(0.02 * time, -0.015 * time);
    float neb = alPortFbm(nb);
    vec3  col = mix(vec3(0.10, 0.03, 0.24), vec3(0.42, 0.18, 0.78), neb * neb);

    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float depth = 0.10 + 0.50 * fi;
        vec2 sc   = planePos * (2.0 + fi * 1.3) + parallax * depth;
        vec2 cell = floor(sc);
        float h   = alPortHash(cell + fi * 7.3);
        if (h > 0.86) {                                        // denser stars per layer
            vec2  f  = fract(sc) - 0.5;
            float d  = 1.0 - alSaturate(length(f) * 2.4);
            float tw = 0.55 + 0.45 * sin(time * (0.8 + h * 3.0) + h * 30.0);
            vec3  sc2 = mix(vec3(0.55, 0.35, 1.00), vec3(1.00, 0.92, 1.00), h);
            col += sc2 * (d * d * tw * (0.55 + 0.75 / (fi + 1.0)));
        }
    }
    col += vec3(0.26, 0.10, 0.52) * 1.15;                      // ethereal purple bloom
    return max(col * 1.35, vec3(0.0));                         // overall luminance lift
}

#endif // AL_LIB_PORTAL
