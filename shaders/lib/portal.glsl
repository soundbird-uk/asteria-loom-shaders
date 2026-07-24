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
// 5.0.12 REWORK ("too bright/opaque; want a DARK purple 3D particle effect, not a
// flat set texture; reflective like water"). The body is now a DARK, near-black
// violet driven by remastered multi-layer swirls (like the vanilla end-portal
// swirl but nether-toned), with animated SPARKLE PARTICLES rising through parallax
// depth layers so it reads as a living 3D volume rather than a static texture.
// Emissive is kept low and the alpha is low (see-through); the water-like
// REFLECTIONS are added by the composite SSR pass (colortex3.b), not baked here.
vec4 alNetherPortal(vec2 planePos, vec2 parallax, float fres, float time) {
    // Remastered swirl — layered parallax FBM (deeper layers drift faster).
    float swirl = 0.0;
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float depth = 0.15 + 0.50 * fi;
        vec2 sc = planePos * 0.7 + parallax * depth
                + vec2(0.02 * time, -time * (0.05 + 0.045 * fi));
        swirl += (0.6 / (fi + 1.0)) * alPortFbm(sc + fi * 3.1);
    }
    swirl = alSaturate(swirl * 1.2);

    // DARK violet body — near-black in the deep, a muted violet in the swirl peaks.
    vec3 deep = vec3(0.015, 0.004, 0.055);                    // near-black violet
    vec3 mid  = vec3(0.170, 0.050, 0.360);                    // muted violet
    vec3 col  = mix(deep, mid, swirl * swirl);

    // 3D SPARKLE PARTICLES — sparse points rising through parallax depth layers,
    // twinkling; the "particle effect" that replaces a flat texture look.
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float dp = 0.30 + 0.70 * fi;
        vec2 sc = planePos * (3.2 + fi * 2.1) + parallax * dp
                + vec2(0.0, -time * (0.14 + 0.10 * fi));      // rising
        vec2 cell = floor(sc);
        float h = alPortHash(cell + fi * 11.0);
        if (h > 0.90) {
            vec2  f = fract(sc) - 0.5;
            float d = 1.0 - alSaturate(length(f) * 2.6);
            float tw = 0.5 + 0.5 * sin(time * (1.0 + h * 4.0) + h * 30.0);
            col += vec3(0.52, 0.26, 0.92) * (d * d * tw * 0.55);  // violet sparkle
        }
    }

    // Subtle grazing rim (most reflection now comes from composite SSR).
    float f = fres * fres;
    col += vec3(0.35, 0.24, 0.62) * (f * 0.45);
    // LOW, swirl-driven alpha so you look INTO the dark depth like water; the
    // sparkle particles and swirl peaks read a touch more solid.
    float alpha = alSaturate(0.26 + swirl * 0.30 + f * 0.20);
    return vec4(col, alpha);
}

// Revamped End portal — MOSTLY BLACK deep space with beige + green particles at
// depth (the Eye-of-Ender palette), in a 3D parallax effect. planePos = coords in
// the portal plane; parallax offsets the deeper particle layers for a real
// 3D-into-the-floor look. Returns linear HDR colour.
//
// 5.0.12 REWORK ("make it much darker, basically black in most of it, with beige
// and green particles deep within like the eye of ender"). The base is near-black;
// beige/green particles twinkle across parallax depth layers; the water-like deep
// REFLECTIONS are added by the composite SSR pass (colortex3.b), not baked here.
vec3 alEndPortal(vec2 planePos, vec2 parallax, float time) {
    // NEAR-BLACK base (stays "basically black" as requested) — a faint FBM adds
    // only a whisper of depth so it isn't a dead flat black.
    vec2  nb  = planePos * 0.8 + parallax * 0.20 + vec2(0.015 * time, -0.012 * time);
    float neb = alPortFbm(nb);
    vec3  col = mix(vec3(0.003, 0.004, 0.005), vec3(0.006, 0.012, 0.009), neb * neb);

    // Beige + green particles deep within, across parallax layers (eye of ender).
    // A SEPARATE hash picks the colour so the beige/green split is even (not tied
    // to the sparsity threshold, which otherwise skews everything green).
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float depth = 0.12 + 0.55 * fi;
        vec2 sc   = planePos * (2.2 + fi * 1.5) + parallax * depth;
        vec2 cell = floor(sc);
        float h   = alPortHash(cell + fi * 7.3);
        if (h > 0.92) {                                        // sparse deep particles
            vec2  f  = fract(sc) - 0.5;
            float d  = 1.0 - alSaturate(length(f) * 2.6);
            float tw = 0.5 + 0.5 * sin(time * (0.7 + h * 3.0) + h * 30.0);
            float ch = alPortHash(cell + fi * 3.7);           // independent colour pick
            vec3  pcol = mix(vec3(0.86, 0.78, 0.52), vec3(0.32, 0.84, 0.46), ch);
            col += pcol * (d * d * tw * (0.45 + 0.55 / (fi + 1.0)));
        }
    }
    // A very faint teal depth glow so it reads as a portal, not a dead black —
    // kept tiny so it stays mostly black.
    col += vec3(0.004, 0.009, 0.007);
    return max(col, vec3(0.0));
}

#endif // AL_LIB_PORTAL
