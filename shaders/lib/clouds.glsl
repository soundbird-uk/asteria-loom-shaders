#ifndef AL_LIB_CLOUDS
#define AL_LIB_CLOUDS

/*
 lib/clouds.glsl — 2-layer volumetric cloud raymarch (composite pass only).

 Cumulus: a genuinely 3D layer. A 2D FBM coverage field (shared with the cloud
 shadow, lib/clouds_common.glsl) sets WHERE clouds are; a height gradient gives
 flat-ish bases and billowy tops; a 3D FBM erosion field carves the edges at a
 second, higher frequency. Marched with view-adaptive primary steps, 3-4
 exponential light steps toward the sun, and a Wrenninge-style multiple-
 scattering octave sum (per-octave extinction / phase / brightness decay) plus
 a powder term for dark undersides. Ambient fill comes from the sky-view LUT
 (alSkySample), the sun colour from alDirectColor (both lib/atmosphere.glsl).

 Cirrus: a cheap thin high 2D sheet, single sample per ray, HG-lit.

 This file is included by composite.fsh ONLY, and only when VOLUMETRIC_CLOUDS is
 defined (composite guards the include), so it may freely depend on the
 atmosphere LUT API. All emissions are finite (the caller additionally
 sanitises before writing history).

 Step budgets (primary x light density evaluations, worst case per pixel):
   VC_QUALITY 1 : 12 primary, 3 light, 2 MS octaves ->  12*(1+3) =  48 evals
   VC_QUALITY 2 : 20 primary, 4 light, 3 MS octaves ->  20*(1+4) = 100 evals
   VC_QUALITY 3 : 32 primary, 4 light, 3 MS octaves ->  32*(1+4) = 160 evals
 Empty-space skipping (coverage/height early-outs) cuts the average far below
 these worst cases; temporal accumulation (colortex7) amortises the rest.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/clouds_common.glsl"
// lib/atmosphere.glsl exposes alSkySample(dir) and alDirectColor().
#include "/lib/atmosphere.glsl"
// lib/fog.glsl (read-only reuse): alFogOpticalDepth + AL_FOG_* constants, so the
// cloud distance-fade matches terrain fog's RATE exactly (BUG 3 convergence). We
// do not edit it; we only call alFogOpticalDepth. Included AFTER atmosphere so
// its alSkySample references resolve.
#include "/lib/fog.glsl"

// --- Quality tiers ----------------------------------------------------------
#if VC_QUALITY == 1
    #define AL_VC_PRIMARY 12
    #define AL_VC_LIGHT   3
    #define AL_VC_MS      2
#elif VC_QUALITY == 3
    #define AL_VC_PRIMARY 32
    #define AL_VC_LIGHT   4
    #define AL_VC_MS      3
#else   // VC_QUALITY == 2 (default)
    #define AL_VC_PRIMARY 20
    #define AL_VC_LIGHT   4
    #define AL_VC_MS      3
#endif

// --- 3D value-noise hash + FBM (erosion detail) -----------------------------
float alCloudHash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.zyx + 31.32);
    return fract((p.x + p.y) * p.z);
}

float alCloudValue3D(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    vec3 u = f * f * (3.0 - 2.0 * f);
    float n000 = alCloudHash13(i + vec3(0.0, 0.0, 0.0));
    float n100 = alCloudHash13(i + vec3(1.0, 0.0, 0.0));
    float n010 = alCloudHash13(i + vec3(0.0, 1.0, 0.0));
    float n110 = alCloudHash13(i + vec3(1.0, 1.0, 0.0));
    float n001 = alCloudHash13(i + vec3(0.0, 0.0, 1.0));
    float n101 = alCloudHash13(i + vec3(1.0, 0.0, 1.0));
    float n011 = alCloudHash13(i + vec3(0.0, 1.0, 1.0));
    float n111 = alCloudHash13(i + vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, u.x), mix(n010, n110, u.x), u.y),
               mix(mix(n001, n101, u.x), mix(n011, n111, u.x), u.y), u.z);
}

float alCloudFbm3D(vec3 p) {
    float f = 0.0, amp = 0.5, freq = 1.0, norm = 0.0;
    for (int i = 0; i < AL_CLOUD_DETAIL_OCTAVES; i++) {
        f    += amp * alCloudValue3D(p * freq);
        norm += amp;
        freq *= 2.0;
        amp  *= 0.5;
    }
    return f / max(norm, 1e-4);
}

float alCloudRemap(float v, float lo, float hi, float nlo, float nhi) {
    return nlo + (v - lo) * (nhi - nlo) / max(hi - lo, 1e-4);
}

// Henyey-Greenstein phase.
float alCloudHG(float c, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * AL_PI * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

// --- Cumulus density at a world position ------------------------------------
// coverageThresh is precomputed (weather aware) by the caller.
float alCloudDensity(vec3 wpos, float coverageThresh) {
    float cov  = alCloudCoverage2D(wpos.xz);
    float lo   = 1.0 - coverageThresh;
    float base = smoothstep(lo, lo + AL_CLOUD_EDGE, cov);
    if (base <= 0.001) return 0.0;               // empty column -> skip 3D noise

    float h  = alSaturate((wpos.y - AL_CLOUD_CUMULUS_BOT)
                        / (AL_CLOUD_CUMULUS_TOP - AL_CLOUD_CUMULUS_BOT));
    float hg = smoothstep(0.0, AL_CLOUD_BOTTOM_ROUND, h)
             * smoothstep(1.0, AL_CLOUD_TOP_ROUND, h);
    float shape = base * hg;
    if (shape <= 0.001) return 0.0;

    // 3D erosion at a second frequency, drifting with the wind and slowly
    // boiling upward so cloud detail evolves over time. The boil is scaled by
    // CLOUD_SPEED (and kept gentle) so it slows together with the drift.
    vec2  wind = alCloudWind();
    float boil = frameTimeCounter * 0.006 * CLOUD_SPEED;
    vec3 dp = wpos * AL_CLOUD_DETAIL_SCALE
            + vec3(wind.x * 0.7 + boil, boil * 0.5, wind.y * 0.7 + boil);
    float det = alCloudFbm3D(dp);

    float d = alCloudRemap(shape, det * AL_CLOUD_EROSION, 1.0, 0.0, 1.0);
    return alSaturate(d) * AL_CLOUD_DENSITY;
}

// Optical depth of the cumulus toward the sun (exponential light steps).
float alCloudLightOD(vec3 wpos, vec3 sunDir, float coverageThresh) {
    float od   = 0.0;
    float t    = 0.0;
    float step = AL_CLOUD_LIGHT_STEP;
    for (int i = 0; i < AL_VC_LIGHT; i++) {
        t += step;
        od += alCloudDensity(wpos + sunDir * t, coverageThresh) * step;
        step *= AL_CLOUD_LIGHT_GROWTH;
    }
    return od;
}

// Cumulus in-scatter + transmittance between t0..t1 along the ray.
// Returns vec4(scatter.rgb, transmittance). `dither` in [0,1) offsets the march
// start so temporal accumulation converges (no fixed banding).
vec4 alCumulus(vec3 camPos, vec3 worldDir, vec3 sunDir, vec3 sunColor,
               float t0, float t1, float dither, float coverageThresh) {
    if (t1 <= t0) return vec4(0.0, 0.0, 0.0, 1.0);

    float span    = t1 - t0;
    float stepLen = span / float(AL_VC_PRIMARY);
    float cosT    = dot(worldDir, sunDir);

    vec3  ambient = alSkySample(normalize(vec3(worldDir.x * 0.3, 1.0,
                                               worldDir.z * 0.3)));

    vec3  scatter = vec3(0.0);
    float trans   = 1.0;

    for (int i = 0; i < AL_VC_PRIMARY; i++) {
        if (trans < 0.02) break;                 // saturated -> stop

        float t   = t0 + (float(i) + dither) * stepLen;
        vec3  sp  = camPos + worldDir * t;
        float dens = alCloudDensity(sp, coverageThresh);
        if (dens <= 0.001) continue;

        float lightOD = alCloudLightOD(sp, sunDir, coverageThresh);

        // Wrenninge multiple-scattering octaves: per-octave extinction (a),
        // phase-g (b) and brightness (c) decay.
        float lightEnergy = 0.0;
        float a = 1.0, b = 1.0, c = 1.0;
        for (int o = 0; o < AL_VC_MS; o++) {
            float ph = alCloudHG(cosT, AL_CLOUD_HG_G * b);
            lightEnergy += c * exp(-lightOD * AL_CLOUD_EXTINCTION * a) * ph;
            a *= AL_CLOUD_MS_EXT;
            b *= AL_CLOUD_MS_PHASE;
            c *= AL_CLOUD_MS_BRIGHT;
        }

        // Powder (dark-edge) term.
        float powder = 1.0 - exp(-dens * stepLen * AL_CLOUD_POWDER * 2.0);
        float powApply = mix(1.0, powder, AL_CLOUD_POWDER_STR);

        vec3 direct = sunColor * (AL_CLOUD_SUN * lightEnergy * powApply);

        // Ambient: more at the top of the cloud, less in the shaded base.
        float hFrac = alSaturate((sp.y - AL_CLOUD_CUMULUS_BOT)
                              / (AL_CLOUD_CUMULUS_TOP - AL_CLOUD_CUMULUS_BOT));
        vec3 amb = ambient * (AL_CLOUD_AMBIENT * (0.35 + 0.65 * hFrac));

        vec3  src = direct + amb;                // source radiance at this sample
        float ext = dens * AL_CLOUD_EXTINCTION;
        float tr  = exp(-ext * stepLen);
        // Energy-conserving integration: ∫ T σs L ds = L (1 - e^{-σt Δ}),
        // assuming single-scatter albedo ~1 (σs ≈ σt).
        scatter += trans * src * (1.0 - tr);
        trans   *= tr;
    }

    return vec4(scatter, trans);
}

// Cheap thin cirrus sheet at a fixed high altitude (single sample per ray).
vec4 alCirrus(vec3 camPos, vec3 worldDir, vec3 sunDir, vec3 sunColor,
              float maxDist, out float tHit) {
    tHit = AL_CLOUD_MAX_DIST;
    float dy = worldDir.y;
    if (abs(dy) < 1e-4) return vec4(0.0, 0.0, 0.0, 1.0);

    float t = (AL_CLOUD_CIRRUS_ALT - camPos.y) / dy;
    if (t <= 0.0 || t > maxDist) return vec4(0.0, 0.0, 0.0, 1.0);
    tHit = t;

    vec2 xz = (camPos + worldDir * t).xz;
    // Stretch the domain for wind-blown wisps, drift a bit faster than cumulus.
    vec2 p  = xz * AL_CIRRUS_SCALE + alCloudWind() * 1.7;
    p.x *= 0.35;                                  // anisotropic -> streaky wisps
    float n = 0.0, amp = 0.5, freq = 1.0, norm = 0.0;
    for (int i = 0; i < 3; i++) {
        n    += amp * alCloudValue2D(p * freq);
        norm += amp;
        freq *= 2.0;
        amp  *= 0.5;
    }
    n /= max(norm, 1e-4);

    float lo  = 1.0 - AL_CIRRUS_COVER;
    float cov = smoothstep(lo, 1.0, n);
    if (cov <= 0.001) return vec4(0.0, 0.0, 0.0, 1.0);

    float dens  = cov * AL_CIRRUS_DENSITY;
    float trans = exp(-dens);
    float cosT  = dot(worldDir, sunDir);
    float ph    = alCloudHG(cosT, AL_CIRRUS_HG);
    vec3  amb   = alSkySample(normalize(vec3(worldDir.x * 0.3, 1.0,
                                             worldDir.z * 0.3)));
    vec3  scat  = (sunColor * (ph * AL_CIRRUS_SUN) + amb * AL_CIRRUS_AMB)
                * (1.0 - trans);
    return vec4(scat, trans);
}

/*
 Full 2-layer cloud render for one view ray. Returns the RAW cloud
 vec4(in-scattered radiance, transmittance) with NO distance fade — the aerial
 dissolve is applied in composite.fsh AFTER temporal accumulation, so the history
 buffer stores view-independent cloud (a view-dependent fade must not be baked
 into reprojected history). Layers are composited front-over-back by entry
 distance so camera-above-cloud still orders right.
   camPos      : world-space camera position (cameraPosition)
   worldDir    : normalised world-space view direction
   sunDir      : world-space dominant-light direction (sun by day / moon night)
   sunColor    : dominant-light colour (alDirectColor)
   terrainDist : world distance to the nearest opaque surface (sky = huge)
   dither      : [0,1) march-start offset for temporal convergence
*/
vec4 alCloudsRender(vec3 camPos, vec3 worldDir, vec3 sunDir, vec3 sunColor,
                    float terrainDist, float dither) {
    float maxDist = min(AL_CLOUD_MAX_DIST, terrainDist);
    float coverageThresh = clamp(VC_COVERAGE + rainStrength * AL_CLOUD_STORM_BOOST,
                                 0.0, 0.95);

    // --- Cumulus slab intersection ---------------------------------------
    float dy = worldDir.y;
    float tCumNear = AL_CLOUD_MAX_DIST;
    vec4  cumulus  = vec4(0.0, 0.0, 0.0, 1.0);
    if (abs(dy) > 1e-4) {
        float ta = (AL_CLOUD_CUMULUS_BOT - camPos.y) / dy;
        float tb = (AL_CLOUD_CUMULUS_TOP - camPos.y) / dy;
        float tn = max(min(ta, tb), 0.0);
        float tf = min(max(ta, tb), maxDist);
        tf = min(tf, tn + AL_CLOUD_MAX_SPAN);        // bound step size at horizon
        if (tf > tn) { tCumNear = tn;
            cumulus = alCumulus(camPos, worldDir, sunDir, sunColor,
                                tn, tf, dither, coverageThresh); }
    } else if (camPos.y > AL_CLOUD_CUMULUS_BOT && camPos.y < AL_CLOUD_CUMULUS_TOP) {
        // Inside the slab looking (near-)horizontal.
        tCumNear = 0.0;
        cumulus = alCumulus(camPos, worldDir, sunDir, sunColor,
                            0.0, min(maxDist, AL_CLOUD_MAX_SPAN), dither,
                            coverageThresh);
    }

    // --- Cirrus sheet -----------------------------------------------------
    float tCir;
    vec4  cirrus = alCirrus(camPos, worldDir, sunDir, sunColor, maxDist, tCir);

    // --- Composite front-over-back by entry distance ----------------------
    // (Aerial distance-dissolve is applied post-temporal in composite.fsh.)
    vec4 nearL, farL;
    if (tCir < tCumNear) { nearL = cirrus; farL = cumulus; }
    else                 { nearL = cumulus; farL = cirrus; }

    vec3  scatter = nearL.rgb + nearL.a * farL.rgb;
    float trans   = nearL.a * farL.a;
    return vec4(scatter, alSaturate(trans));
}

#endif // AL_LIB_CLOUDS
