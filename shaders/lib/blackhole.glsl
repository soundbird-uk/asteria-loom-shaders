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

    // --- Angular scales (radians) ---
    // Bigger than a pinpoint so the hole DOMINATES the End sky (the brief's
    // centrepiece). rEH ~4.6 deg at size 1.0; the disc reaches out to ~37 deg.
    float rEH      = 0.080 * max(size, 0.01);         // event horizon
    float rPhoton  = rEH * 1.30;                       // photon ring
    float rDiscIn  = rEH * 1.9;
    float rDiscOut = rEH * 8.0;

    // --- Gravitationally-lensed background ---
    // Push the background sample OUTWARD near the hole (compresses the starfield
    // into an Einstein ring). Stylised deflection ~ Rs^2 / b^2, capped.
    float defl  = (rEH * rEH * 2.4) / max(ang * ang, rEH * rEH * 0.20);
    defl        = min(defl, 1.3);
    float bgAng = ang + defl;
    vec3  bgDir = normalize(bh * cos(bgAng) + tang * sin(bgAng));
    vec3  stars = alStarfield(bgDir) * 1.7;            // denser/brighter in the End
    vec3  col   = alEndHaze(bgDir) + stars;

    // --- Accretion disc (tilted annulus) ---
    // Fake the tilt by scaling the effective radius with the azimuth so the
    // annulus reads as an ellipse; a brighter arc near the top hints at the
    // lensed far side. Doppler brightens phi~0 (approaching), dims phi~pi.
    float tilt    = 0.45;
    float rEff    = ang * (1.0 + tilt * cos(phi));     // elliptical annulus
    float inBand  = smoothstep(rDiscIn, rDiscIn * 1.25, rEff)
                  * (1.0 - smoothstep(rDiscOut * 0.75, rDiscOut, rEff));
    float tParam  = 1.0 - alSaturate((rEff - rDiscIn) / max(rDiscOut - rDiscIn, 1e-4));
    float doppler = 0.35 + 0.65 * (0.5 + 0.5 * cos(phi));
    float turb    = 0.7 + 0.3 * sin(phi * 5.0 + time * 0.25 + rEff * 60.0);
    float arc     = 1.0 + 0.6 * smoothstep(0.4, 1.0, cos(phi)); // lensed top arc hint
    vec3  disc    = alBhDiscColor(tParam)
                  * (inBand * doppler * turb * arc * 4.5);       // brighter -> blooms
    col += disc;

    // --- Photon ring (thin bright ring at the capture threshold) ---
    float prx = (ang - rPhoton) / max(rEH * 0.12, 1e-4);
    float pr  = exp(-prx * prx);                        // squared directly (no pow neg-base)
    col += vec3(1.0, 0.88, 0.75) * (pr * 5.0);          // hot bright ring

    // --- Event horizon: pure black, nothing escapes ---
    float eh = smoothstep(rEH, rEH * 0.82, ang);       // 1 inside, 0 outside
    col = mix(col, vec3(0.0), eh);

    // NaN/negative guard.
    if (!all(greaterThanEqual(col, vec3(0.0))) || !all(lessThan(col, vec3(1.0e4)))) {
        col = alEndHaze(dir);
    }
    return max(col, vec3(0.0));
}

#endif // AL_LIB_BLACKHOLE
