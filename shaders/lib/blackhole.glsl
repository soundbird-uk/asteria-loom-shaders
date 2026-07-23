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
    vec3  horizon = vec3(0.20, 0.05, 0.30);      // deep magenta-violet low
    vec3  zenith  = vec3(0.045, 0.02, 0.10);     // near-black violet high
    vec3  base    = mix(horizon, zenith, alSmooth(smoothstep(0.20, 0.95, up)));
    // Drain the sky toward black as it nears the hole -> a dark gravitational halo.
    float toHole  = alSaturate(dot(dir, AL_BH_DIR));
    base *= mix(1.0, 0.35, smoothstep(0.80, 0.998, toHole));
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
    vec3  stars = alStarfield(bgDir) * 1.7;            // denser/brighter in the End
    vec3  col   = alEndHaze(bgDir) + stars;

    // --- Accretion disc: Interstellar "Gargantua" silhouette --------------
    // The disc is a thin annulus seen nearly edge-on. Two ingredients build the
    // iconic shape: HORIZONTAL WINGS (the disc plane — thin, reaching far out
    // left/right) PLUS a LENSED WRAP RING hugging the photon sphere (the far side
    // of the disc bent up over the top and down under the bottom). A slight tilt,
    // per-side Doppler, a radial temperature ramp and slow swirling wisps finish
    // it, all HDR-bright so the hot side blooms to white in composite4/5.
    float rN   = ang / rEH;                        // radius in horizon units
    float phiT = phi - 0.32;                        // tilt the whole disc ~18 deg
    float ca   = cos(phiT);
    float wN   = rN * sin(phiT);                    // vertical offset (EH units)

    // Swirling wisps flowing around the disc (slow animation).
    float swirl = phiT * 3.0 - rN * 2.2 + time * 0.12;
    float wisp  = 0.55 + 0.45 * sin(swirl) * sin(swirl * 1.7 + 1.1);
    wisp        = clamp(wisp * (0.7 + 0.5 * sin(swirl * 5.0 + rN * 3.0)), 0.15, 1.30);

    // (1) Horizontal wings: thin bright band along the disc plane (wN~0).
    float thick = 0.55 + 0.30 * wisp;               // vertical half-thickness (EH)
    float bandV = exp(-(wN * wN) / (2.0 * thick * thick));
    float wingR = smoothstep(1.02, 1.45, rN) * (1.0 - smoothstep(5.0, 8.5, rN));
    float wings = bandV * wingR;

    // (2) Lensed wrap ring: bright loop hugging the photon sphere at all angles
    //     — this is what arcs OVER the top and UNDER the bottom of the horizon.
    float dW   = (rN - 1.5) / 0.5;
    float wrap = exp(-dW * dW);

    float discA = max(wings, wrap * 0.95) * wisp;

    // Doppler: the approaching (+refA) side is far brighter and whiter.
    float dopp  = 0.30 + 1.05 * smoothstep(-0.5, 0.75, ca);
    // Temperature: white-hot near the hole -> amber outside.
    vec3  dcol  = alBhDiscColor(alSaturate(1.0 - (rN - 1.0) / 5.0));

    col += dcol * (discA * dopp * 6.5);

    // --- Photon ring (thin, very bright, hugs the horizon) ---
    float prx = (rN - 1.06) / 0.05;
    float pr  = exp(-prx * prx);                    // direct square (no pow neg-base)
    col += vec3(1.0, 0.92, 0.82) * (pr * 9.0);

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
