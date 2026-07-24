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
vec4 alNetherPortal(vec2 planePos, vec2 parallax, float fres, float time) {
    float swirl = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float depth = 0.20 + 0.32 * fi;                       // deeper layers
        vec2 sc = planePos * 0.7 + parallax * depth
                + vec2(0.03 * time, -time * (0.06 + 0.05 * fi));   // rising swirl
        swirl += (0.6 / (fi + 1.0)) * alPortFbm(sc + fi * 3.1);
    }
    swirl = alSaturate(swirl * 1.2);
    vec3 deep   = vec3(0.16, 0.03, 0.34);
    vec3 bright = vec3(0.82, 0.34, 1.00);
    vec3 col = mix(deep, bright, swirl * swirl) * 1.8;          // emissive glow
    col += vec3(0.55, 0.40, 1.00) * (fres * fres * 1.0);        // fresnel sheen
    return vec4(col, mix(0.82, 0.98, swirl));
}

// Revamped End portal — a deep parallax starfield with ethereal glow. planePos =
// coords in the portal plane; parallax offsets the deeper star layers for a real
// 3D-into-the-floor look. Returns linear HDR colour.
vec3 alEndPortal(vec2 planePos, vec2 parallax, float time) {
    vec3 col = vec3(0.010, 0.0, 0.030);                        // deep near-black base
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float depth = 0.10 + 0.55 * fi;
        vec2 sc   = planePos * (2.0 + fi * 1.4) + parallax * depth;
        vec2 cell = floor(sc);
        float h   = alPortHash(cell + fi * 7.3);
        if (h > 0.93) {                                        // sparse stars per layer
            vec2  f  = fract(sc) - 0.5;
            float d  = 1.0 - alSaturate(length(f) * 2.6);
            float tw = 0.55 + 0.45 * sin(time * (0.8 + h * 3.0) + h * 30.0);
            vec3  sc2 = mix(vec3(0.55, 0.35, 1.00), vec3(1.00, 0.92, 1.00), h);
            col += sc2 * (d * d * tw * (0.35 + 0.65 / (fi + 1.0)));
        }
    }
    col += vec3(0.16, 0.05, 0.34) * 0.55;                      // ethereal purple glow
    return max(col, vec3(0.0));
}

#endif // AL_LIB_PORTAL
