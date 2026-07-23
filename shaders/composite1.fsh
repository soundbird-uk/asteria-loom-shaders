#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/space.glsl"
#ifdef VOLUMETRIC_CLOUDS
#include "/lib/clouds.glsl"
#endif

/*
 composite1 (fragment) — volumetric clouds + scene composite + AO-history copy.

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

    // Cloud mid-plane intersection distance along the ray — reused for BOTH the
    // temporal reprojection AND the aerial distance-dissolve below. > 0 means the
    // ray meets the cumulus mid-plane ahead of the camera (i.e. cloud may exist).
    float midAlt  = 0.5 * (AL_CLOUD_CUMULUS_BOT + AL_CLOUD_CUMULUS_TOP);
    bool  planeOk = abs(worldDir.y) > 1e-3;
    float tmRaw   = planeOk ? (midAlt - cameraPosition.y) / worldDir.y : -1.0;
    float tm      = (tmRaw > 0.0) ? min(tmRaw, AL_CLOUD_MAX_DIST) : -1.0;

    // ---- Temporal accumulation (BUG-1 hardened) ---------------------------
    // Clouds live only on SKY pixels. Blending history onto TERRAIN pixels was
    // the "dark box" veil (a reprojected cloud transmittance < 1 darkening a
    // pixel that has no cloud), so temporal blend is GATED to sky pixels;
    // terrain keeps the current, near-identity march. On sky pixels the blend
    // is admitted only through STRICT gates that garbage/edge reads cannot pass.
    vec3  outScatter = curScatter;
    float outTrans   = curTrans;
    bool  isSky      = depth1 >= 1.0;

    if (isSky && tm > 0.0) {
        {
            vec3 cloudPlayer = worldDir * tm;
            vec3 prevView    = alPlayerToPrevView(cloudPlayer);
            if (prevView.z < 0.0) {                    // in front of prev camera
                vec3  prevScr = alPrevViewToScreen(prevView);
                float m = AL_CLOUD_REPROJ_MARGIN;
                // STRICT off-screen rejection with margin — NO edge clamping.
                // Newly revealed regions fall through to the current frame.
                if (prevScr.x > m && prevScr.x < 1.0 - m &&
                    prevScr.y > m && prevScr.y < 1.0 - m) {
                    vec4 hist = texture(colortex7, prevScr.xy);
                    // Validity: finite range (NaN fails every compare) AND the
                    // alpha sentinel — real writes are floored to
                    // AL_CLOUD_TRANS_EPS, so alpha below it is uninitialised
                    // (Apple-GL clear=false) garbage and is rejected.
                    bool valid = (hist.r >= 0.0) && (hist.r < AL_CLOUD_HDR_MAX) &&
                                 (hist.g >= 0.0) && (hist.g < AL_CLOUD_HDR_MAX) &&
                                 (hist.b >= 0.0) && (hist.b < AL_CLOUD_HDR_MAX) &&
                                 (hist.a >= AL_CLOUD_TRANS_EPS) && (hist.a <= 1.0);
                    if (valid) {
                        outScatter = mix(curScatter, hist.rgb, AL_CLOUD_HISTORY_BLEND);
                        outTrans   = mix(curTrans,   hist.a,   AL_CLOUD_HISTORY_BLEND);
                    }
                }
            }
        }
    }

    // FAIL-SAFE: a bad blend reverts to the CURRENT frame (never a dark veil);
    // garbage transmittance -> 1.0 (transparent, never darker).
    outScatter = alFiniteRGB(outScatter, curScatter);
    outTrans   = (outTrans >= 0.0 && outTrans <= 1.0) ? outTrans : 1.0;
    // Store with transmittance floored to the validity epsilon so a real write
    // is never mistaken for the invalid sentinel next frame. HISTORY IS RAW (no
    // distance fade) — the fade is view-dependent and must not enter reprojection.
    outCloud   = vec4(outScatter, max(outTrans, AL_CLOUD_TRANS_EPS));

    // ---- Aerial distance-dissolve (post-temporal; 0.3.3 field fix) --------
    // Distant clouds DISSOLVE: both opacity and scattering fade toward zero,
    // revealing the background atmosphere sky — which equals lib/fog.glsl's own
    // far-fade target — so cloud and terrain fog converge with NO seam. Reuses
    // fog.glsl's optical-depth model (not duplicated) with a cloud density boost;
    // for clouds above the fog layer that depth is ~linear in distance, giving a
    // dreamy distance haze. No-op where there is no cloud (outTrans==1).
    float dispTrans   = outTrans;
    vec3  dispScatter = outScatter;
    if (tm > 0.0) {
        float beta0 = AL_FOG_SEA_DENSITY * max(FOG_DENSITY, 0.0)
                    * AL_CLOUD_AERIAL_DENSITY
                    * mix(1.0, AL_CLOUD_AERIAL_RAINBOOST, alSaturate(rainStrength));
        float extFog = exp(-alFogOpticalDepth(cameraPosition.y, worldDir, tm, beta0));
        dispTrans   = 1.0 - (1.0 - outTrans) * extFog;   // opacity dissolves
        dispScatter = outScatter * extFog;               // in-scatter fades to 0
    }

    // Composite over the scene: background shows through by the (dissolved)
    // transmittance, plus the (distance-faded) in-scattered radiance.
    vec3 composited = scene * dispTrans + dispScatter;
#if DEBUG_VIEW == 0
    outColor = vec4(max(composited, vec3(0.0)), 1.0);
#else
    // Debug: leave colortex0 = raw scene so the deferred1 pipeline probes
    // (DEBUG_VIEW 7/8) survive to final unmodified.
    outColor = vec4(scene, 1.0);
#endif
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
