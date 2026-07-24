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

    vec3 deep   = vec3(0.10, 0.02, 0.26);                     // dark violet depth
    vec3 mids   = vec3(0.55, 0.16, 0.92);
    vec3 bright = vec3(0.95, 0.55, 1.00);
    vec3 col = mix(deep, mids, swirl * swirl) * 1.7;          // emissive body
    col += bright * (veins * 1.4);                            // glowing filaments
    // Fresnel "reflection" sheen — a grazing-angle violet specular, the water trick.
    // Kept moderate so the swirl/veins still read through it at grazing angles.
    float f = fres * fres;
    col += vec3(0.60, 0.42, 1.00) * (f * 1.15);
    // Alpha: see-through in the dark deep, solid on the bright veins/edges — so the
    // portal reads DEEP (you see into it) rather than a flat opaque sheet.
    float alpha = alSaturate(mix(0.55, 0.95, max(veins, f)) + swirl * 0.10);
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
    vec3  col = mix(vec3(0.045, 0.010, 0.11), vec3(0.22, 0.08, 0.42), neb * neb);

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
    col += vec3(0.20, 0.07, 0.40) * 0.85;                      // ethereal purple bloom
    return max(col, vec3(0.0));
}

#endif // AL_LIB_PORTAL
