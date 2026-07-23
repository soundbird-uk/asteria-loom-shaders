#ifndef AL_LIB_BLACKHOLE
#define AL_LIB_BLACKHOLE

/*
 lib/blackhole.glsl — the End's procedural black-hole sky (Phase 5, world1).

 A fully procedural, stylised black hole rendered for the End's sky pixels (in
 world1/gbuffers_skybasic). NO geodesic integration (Mac-GL4.1, per contract):
 gravitational lensing is an impact-parameter approximation that bends the
 background sample around the hole (Einstein-ring compression of the starfield).
 Features: pure-black event horizon, a bright photon ring at the capture
 threshold, a tilted glowing accretion disc with an inner→outer temperature
 gradient and Doppler brightening on the approaching side, a dense procedural
 starfield (reuses lib/nightsky.glsl) and a purple End haze rising from the
 horizon. All pure math, NaN-safe (every acos/sqrt/divisor guarded).

 Direction: the hole sits at a FIXED high-elevation azimuth (documented below).
 Size: END_BLACKHOLE_SIZE scales its apparent angular radius.

 Include order note: this pulls in lib/nightsky.glsl (which owns the
 frameTimeCounter uniform), so it must only be included by a program that does
 NOT also pull frameTimeCounter from lib/clouds_common.glsl (i.e. skybasic, not
 the deferred lighting pass) — see the world1 pass-chain header.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/nightsky.glsl"

// Fixed black-hole direction: LOW in the End sky (~23 deg elevation) so it hangs
// near where the player naturally looks and dominates the view, slightly off
// the forward axis so the tilted disc reads. Azimuth ~21 deg. Normalised.
#define AL_BH_DIR normalize(vec3(0.80, 0.36, 0.30))

// Purple End haze: a moody violet sky that DEEPENS toward the black hole (a dark
// halo of drained sky around it) and glows a little brighter low on the horizon.
vec3 alEndHaze(vec3 dir) {
    float up = alSaturate(dir.y * 0.5 + 0.5);
    vec3  base = mix(AL_END_SPACE_LOW, AL_END_SPACE_HIGH, alSmooth(smoothstep(0.10, 0.95, up)));
    // Drain the sky toward black as it nears the hole -> a dark gravitational halo.
    float toHole = alSaturate(dot(dir, AL_BH_DIR));
    base *= mix(1.0, 0.30, smoothstep(0.80, 0.998, toHole));
    return base;
}

// Accretion-disc colour from a normalised temperature t (0 = cool outer red,
// 1 = hot inner blue-white). A cheap blackbody-ish ramp.
vec3 alBhDiscColor(float t) {
    t = alSaturate(t);
    vec3 cool = vec3(0.75, 0.14, 0.06);   // deep red (outer)
    vec3 mid  = vec3(1.00, 0.55, 0.20);   // orange
    vec3 hot  = vec3(1.00, 0.93, 0.85);   // near-white (inner)
    return (t > 0.5) ? mix(mid, hot, (t - 0.5) * 2.0)
                     : mix(cool, mid, t * 2.0);
}

// End light-shaft mask — broad soft vertical beams as a function of world XZ
// ONLY (constant in world-Y, so a vertical column of air shares one value and
// reads as a vertical beam), drifting slowly. Returns 0..1. Used by the End fog
// pass (world1/composite2) to add violet aurora-like shafts through the haze.
float alEndShaftMask(vec2 wxz, float time) {
    vec2 p = wxz * AL_END_SHAFT_SCALE;
    p.x += time * AL_END_SHAFT_DRIFT;
    float n = alFbm3(vec3(p, time * 0.02));        // seamless value-noise FBM
    return smoothstep(0.50, 0.82, n);               // sharpen into discrete beams
}

/*
 Full End sky for a world-space view direction. `size` = END_BLACKHOLE_SIZE,
 `time` = frameTimeCounter (disc turbulence animation).
*/
vec3 alEndBlackHoleSky(vec3 dir, float size, float time) {
    dir = normalize(dir);
    vec3 bh = AL_BH_DIR;

    // --- Local geometry around the hole ---
    float cosA = clamp(dot(dir, bh), -1.0, 1.0);
    float ang  = acos(cosA);                          // angular distance (rad)
    vec3  tang = dir - bh * cosA;                     // tangent (perp to bh)
    float tl   = length(tang);
    tang = (tl > 1.0e-5) ? tang / tl : vec3(1.0, 0.0, 0.0);
    // Azimuth around the hole axis (for Doppler + disc turbulence).
    vec3  refA = normalize(cross(bh, vec3(0.0, 1.0, 0.0)) + vec3(1.0e-5));
    vec3  refB = normalize(cross(bh, refA));
    float phi  = atan(dot(tang, refB), dot(tang, refA));

    // --- Angular scale (radians) ---
    // rEH ~4.6 deg at size 1.0 so the hole DOMINATES the End sky; the accretion
    // disc's horizontal wings reach out to ~8x that (~37 deg). Everything else is
    // measured in "horizon units" rN = ang / rEH (1.0 == the event horizon).
    float rEH = 0.080 * max(size, 0.01);

    // --- Gravitationally-lensed background ---
    // Push the background sample OUTWARD near the hole (compresses the starfield
    // into an Einstein ring). Stylised deflection ~ Rs^2 / b^2, capped.
    float defl  = (rEH * rEH * 2.4) / max(ang * ang, rEH * rEH * 0.20);
    defl        = min(defl, 1.3);
    float bgAng = ang + defl;
    vec3  bgDir = normalize(bh * cos(bgAng) + tang * sin(bgAng));
    vec3  stars = alStarfield(bgDir) * 1.4;            // denser/brighter in the End
    vec3  col   = alEndHaze(bgDir) + stars;

    // Vertical aurora streaks in the sky BACKDROP — bright AND dark violet columns
    // (function of azimuth only -> vertical), drifting slowly, stronger higher up.
    // Applied to the backdrop before the disc is drawn.
    {
        float az     = atan(dir.z, dir.x);
        float sm     = sin(az * 6.0 + time * 0.05) + 0.5 * sin(az * 13.0 - time * 0.031);
        float streak = sm * 0.5;                        // ~ -0.75 .. 0.75
        float upf    = alSaturate(dir.y * 0.5 + 0.5);
        col += AL_END_SHAFT_COLOR * (max(streak, 0.0) * 0.10 * upf);
        col *= 1.0 - max(-streak, 0.0) * 0.22 * upf;
    }

    // --- Accretion disc: silky SPINNING filaments (Interstellar Gargantua) --
    // The dust rides log-spiral orbits, rotating with time and FASTER near the
    // hole (differential rotation) so the disc visibly spins in 3D. A bright disc
    // base — horizontal WINGS plus a lensed WRAP HALO arcing OVER the top and
    // UNDER the bottom — is carved by MANY ultra-fine sheared strands (silky cream
    // with hair-fine darker gaps), with per-side Doppler, a radial temperature
    // ramp and a glare hotspot. HDR so the hot side blooms to white.
    float rN   = ang / rEH;                          // radius in horizon units
    float phiT = phi + 0.23;                          // disc tilt
    float ca   = cos(phiT);
    float wN   = rN * sin(phiT);                      // vertical offset (EH units)

    // Disc shape: horizontal wings + lensed wrap halo.
    float hd    = (rN - 1.32) / 0.52;
    float halo  = exp(-hd * hd);
    float bandV = exp(-(wN * wN) / (2.0 * 0.16 * 0.16));
    float wingR = alSaturate((rN - 1.0) / 0.28) * exp(-max(rN - 1.0, 0.0) / 2.7);
    float shape = max(halo, 1.15 * bandV * wingR);
    float discBase = shape * clamp(1.25 / (rN + 0.30), 0.0, 2.0);

    // Spinning fine spiral strands (differential rotation — inner sweeps faster).
    float omega  = 1.0 / (rN * 0.6 + 0.45);
    float spin   = time * omega;
    float spiral = rN * 66.0 - phi * 3.0 + spin * 3.0;
    float striae = (0.70 + 0.30 * sin(spiral)) * (0.85 + 0.15 * sin(spiral * 2.7 + 1.0));
    float broad  = 0.68 + 0.32 * sin(phi * 2.0 - spin * 1.5 + rN * 0.5);
    float discA  = discBase * striae * broad;

    // Doppler: the approaching (+refA) side is brighter and whiter.
    float dopp = 0.32 + 1.05 * alSaturate((ca + 0.4) / 1.4);
    // Temperature: white-cream near the hole -> amber outside.
    vec3  dcol = mix(vec3(0.93, 0.62, 0.30), vec3(1.00, 0.92, 0.74),
                     alSaturate(1.0 - (rN - 1.0) / 3.0));
    col += dcol * (discA * dopp * 5.5);

    // Bright glare hotspot on the approaching side, near the ring.
    float hotR = (rN - 1.18) / 0.42;
    float hot  = exp(-hotR * hotR) * pow(max(ca, 0.0), 4.0);
    col += vec3(1.0, 0.95, 0.85) * (hot * 3.5);

    // --- Photon ring (thin, very bright, hugs the horizon) ---
    float prx = (rN - 1.05) / 0.05;
    float pr  = exp(-prx * prx);                    // direct square (no pow neg-base)
    col += vec3(1.0, 0.96, 0.90) * (pr * 7.0);

    // --- Event horizon: pure black inside ---
    float eh = smoothstep(1.0, 0.95, rN);           // 1 inside, 0 outside
    col = mix(col, vec3(0.0), eh);

    // NaN/negative guard.
    if (!all(greaterThanEqual(col, vec3(0.0))) || !all(lessThan(col, vec3(1.0e4)))) {
        col = alEndHaze(dir);
    }
    return max(col, vec3(0.0));
}

#endif // AL_LIB_BLACKHOLE
