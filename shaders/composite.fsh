#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/space.glsl"
#ifdef VOLUMETRIC_CLOUDS
#include "/lib/clouds.glsl"
#endif

/*
 composite (fragment) — volumetric clouds + scene composite + AO-history copy.

 Three jobs:
   1. VOLUMETRIC CLOUDS (when VOLUMETRIC_CLOUDS is on): raymarch the 2-layer
      cloud volume (lib/clouds.glsl) for this view ray, temporally accumulate it
      through colortex7, and composite the result over the scene colour. With
      the option off this whole path compiles out and colortex0 passes through
      unchanged — Minecraft's forward clouds draw instead (VANILLA_CLOUDS).
   2. Pass colortex0 through (now = scene * cloudTransmittance + cloudScatter).
   3. Copy this frame's AO (colortex4) into the persistent history buffer
      colortex5, tagged with linear eye depth from depthtex1, EXACTLY as before
      (the GTAO pass consumed last frame's copy in `deferred`; no hazard).

 CLOUD RAY DOMAIN: only where the layers are actually visible. depthtex1 (NO
 translucents) gives the opaque terrain distance; the cumulus/cirrus march far
 bound is clamped to it, so near terrain (distance < cloud entry) yields an
 empty march (terrain occludes) while sky pixels (depthtex1 == 1.0 -> huge
 distance) march the full layer. This is the same opaque-depth source the AO
 history uses, so no extra sampler.

 TEMPORAL: planar reprojection at the cumulus MID-altitude. The current pixel's
 cloud is treated as a single point where the ray meets that plane; that point
 is reprojected into last frame via the gbufferPrevious* matrices + camera
 delta (lib/space.glsl) and colortex7 is sampled there. This is exact for cloud
 matter at the mid-plane and a small parallax approximation for matter above/
 below it (and for cirrus) — acceptable for a soft, slowly-evolving volume.
 colortex7 has clear=false, so its first-frame contents are UNDEFINED on Apple
 GL; every history gate below is a RANGE COMPARISON that NaN cannot pass, so
 garbage self-heals to the current frame (same discipline as deferred.fsh).
 A noisetex + golden-ratio march-start dither makes the accumulation converge.

 Sampler count: 3 base (colortex0, colortex4, depthtex1)
              + colortex7 + noisetex here + colortex6 (sky LUT, via the
                lib/atmosphere.glsl include) = 6 when clouds are on
   (<= 9 budget; <= 16 Mac hard limit.)
*/

uniform sampler2D colortex0;   // scene HDR
uniform sampler2D colortex4;   // this frame's AO (r), confidence (g)
uniform sampler2D depthtex1;   // opaque-only depth (matches the AO pass)

#ifdef VOLUMETRIC_CLOUDS
uniform sampler2D colortex7;   // cloud history: rgb = scatter, a = transmittance
uniform sampler2D noisetex;    // 256x256 blue-ish noise (march-start dither)
// colortex6 (the sky-view LUT) is declared by lib/atmosphere.glsl, pulled in via
// lib/clouds.glsl above — do NOT redeclare it here (duplicate-uniform error).
#endif

in vec2 texcoord;

/* RENDERTARGETS: 0,5,7 */
layout(location = 0) out vec4 outColor;     // -> colortex0 (scene + clouds)
layout(location = 1) out vec4 outHistory;   // -> colortex5 (AO history)
layout(location = 2) out vec4 outCloud;     // -> colortex7 (cloud history)

#ifdef VOLUMETRIC_CLOUDS
// Replace any non-finite / out-of-range component with a fallback. Range tests,
// not clamp()/isnan() — NaN fails every comparison, so poison can never survive
// into the persistent colortex7 (deferred.fsh's NaN-proof discipline).
vec3 alFiniteRGB(vec3 v, vec3 fb) {
    return vec3((v.x >= 0.0 && v.x < AL_CLOUD_HDR_MAX) ? v.x : fb.x,
                (v.y >= 0.0 && v.y < AL_CLOUD_HDR_MAX) ? v.y : fb.y,
                (v.z >= 0.0 && v.z < AL_CLOUD_HDR_MAX) ? v.z : fb.z);
}
#endif

void main() {
    // ---- Scene passthrough (clouds may overwrite outColor below) ----------
    vec3 scene = texture(colortex0, texcoord).rgb;
    outColor   = vec4(scene, 1.0);
    outCloud   = vec4(0.0, 0.0, 0.0, 1.0);   // neutral history when clouds off

#ifdef VOLUMETRIC_CLOUDS
    float depth1 = texture(depthtex1, texcoord).r;

    // View ray (direction only) -> world.
    vec3 viewDir  = normalize(alScreenToView(texcoord, 1.0));
    vec3 worldDir = normalize(alViewDirToWorld(viewDir));

    // Opaque terrain distance (sky -> huge). depthtex1 excludes translucents.
    float terrainDist = AL_CLOUD_MAX_DIST * 2.0;
    if (depth1 < 1.0) {
        terrainDist = length(alScreenToView(texcoord, depth1));
    }

    // March-start dither: blue noise per pixel advanced by the golden ratio per
    // frame (derived from frameTimeCounter — no frameCounter uniform, which
    // atmosphere.glsl may own — so temporal noise decorrelates and converges).
    float blue   = texture(noisetex, gl_FragCoord.xy / 256.0).r;
    float dither  = fract(blue + frameTimeCounter * 60.0 * 0.61803398875);

    // Dominant-light direction (approx, shared with the cloud shadow) + colour.
    vec3 sunDir   = alApproxSunDirWorld();
    vec3 sunColor = alDirectColor(sunDir);   // warm sun by day, cool moon at night

    vec4 cloud = alCloudsRender(cameraPosition, worldDir, sunDir, sunColor,
                                terrainDist, dither);

    vec3  curScatter = alFiniteRGB(cloud.rgb, vec3(0.0));
    float curTrans   = (cloud.a >= 0.0 && cloud.a <= 1.0) ? cloud.a : 1.0;

    // ---- Temporal reprojection at the cumulus mid-plane -------------------
    float midAlt = 0.5 * (AL_CLOUD_CUMULUS_BOT + AL_CLOUD_CUMULUS_TOP);
    float tRep   = AL_CLOUD_MAX_DIST;
    if (abs(worldDir.y) > 1e-4) {
        float tm = (midAlt - cameraPosition.y) / worldDir.y;
        if (tm > 0.0) tRep = min(tm, AL_CLOUD_MAX_DIST);
    }
    vec3 cloudPlayer = worldDir * tRep;               // relative to this camera
    vec3 prevView    = alPlayerToPrevView(cloudPlayer);
    vec3 prevScr     = alPrevViewToScreen(prevView);

    vec3  outScatter = curScatter;
    float outTrans   = curTrans;

    if (prevScr.x > 0.0 && prevScr.x < 1.0 &&
        prevScr.y > 0.0 && prevScr.y < 1.0 &&
        prevView.z < 0.0) {                            // in front of prev camera
        vec4 hist = texture(colortex7, prevScr.xy);
        // Range validation rejects NaN AND out-of-range first-frame garbage.
        bool valid = (hist.r >= 0.0) && (hist.r < AL_CLOUD_HDR_MAX) &&
                     (hist.g >= 0.0) && (hist.g < AL_CLOUD_HDR_MAX) &&
                     (hist.b >= 0.0) && (hist.b < AL_CLOUD_HDR_MAX) &&
                     (hist.a >= 0.0) && (hist.a <= 1.0);
        if (valid) {
            outScatter = mix(curScatter, hist.rgb, AL_CLOUD_HISTORY_BLEND);
            outTrans   = mix(curTrans,   hist.a,   AL_CLOUD_HISTORY_BLEND);
        }
    }

    // Sanitise before it enters the persistent buffer / the screen.
    outScatter = alFiniteRGB(outScatter, vec3(0.0));
    outTrans   = (outTrans >= 0.0 && outTrans <= 1.0) ? outTrans : 1.0;
    outCloud   = vec4(outScatter, outTrans);

    // Composite over the scene: background shows through by transmittance, plus
    // the cloud's in-scattered radiance.
    vec3 composited = scene * outTrans + outScatter;
    outColor = vec4(max(composited, vec3(0.0)), 1.0);
#endif

    // ---- AO history copy (PRESERVED verbatim — see original header) -------
    // r = AO, g = confidence, b = linear eye depth of this sample. Range tests,
    // not clamp() — NaN fails every comparison and falls through to the safe
    // default so colortex5 can never carry a non-finite value forward.
    vec2  ao    = texture(colortex4, texcoord).rg;
    float depth = texture(depthtex1, texcoord).r;
    float aoR   = (ao.r >= 0.0 && ao.r <= 1.0) ? ao.r : 1.0;
    float aoG   = (ao.g >= 0.0 && ao.g <= 1.0) ? ao.g : 0.0;
    float linZ  = (depth >= 1.0) ? 0.0
                                 : alLinearEyeDepth(alScreenToView(texcoord, depth));
    linZ = (linZ >= 0.0 && linZ < 65000.0) ? linZ : 0.0;
    outHistory = vec4(aoR, aoG, linZ, 1.0);
}
