#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/encoding.glsl"
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
   3. Copy this frame's AO (colortex4) VERBATIM into the persistent history
      buffer colortex5 (tagged with opaque linear eye depth from depthtex1).

      The AO is deliberately NOT spatially filtered here. colortex5 is the input
      to deferred's GTAO temporal accumulator, which blends it back into
      colortex4 next frame (ceiling AL_AO_MAX_BLEND = 0.9), which this pass then
      copies back into colortex5 — a closed feedback loop. Putting a bilateral
      blur INSIDE that loop re-filters an already-filtered signal every frame, so
      the blur compounds without bound: an edge-stopped filter iterated to
      convergence flattens each surface to a piecewise-constant patch, washing out
      exactly the within-surface contact gradient AO exists to draw (corner and
      crease darkening). Spatial denoise therefore happens ONCE, at READ time, in
      deferred1 (AL_AO_DENOISE) where it shades the frame but never re-enters the
      history. That also halves the AO filtering cost per frame.

      The AO term occupies rgb; colortex5.a is PRESERVED byte-exact (see below).

   4. PRESERVE colortex5.a — the persistent auto-exposure slot. composite14 stores
      the frame's adapted exposure in colortex5.a at texel (0,0); this pass runs
      BEFORE it, so it must pass the stored .a through unchanged instead of the old
      constant 1.0, otherwise the exposure integrator can never read last frame's
      value. .a is not part of the AO history (deferred uses r/g/b only), so this
      is free: we texelFetch this pixel's stored .a and re-emit it (range-guarded
      to keep the persistent buffer finite — see main()).

 IRIS BUFFER CONTRACT: this pass WRITES colortex5 (AO history) AND now READS it
 back to PRESERVE its alpha channel. colortex5.a at texel (0,0) is the persistent
 auto-exposure slot: composite14 writes last frame's adapted exposure there, and
 this pass must NOT clobber it — it is the single value the exposure integrator
 reprojects from (see composite14's header). We therefore texelFetch this pixel's
 stored .a and re-emit it UNCHANGED; the AO term (rgb) is rebuilt from colortex4
 as before. Reading-and-writing colortex5 is the documented read-while-write rule:
 Iris' automatic ping-pong supplies last frame's contents on read (the same rule
 colortex0/colortex7 rely on). We still write EVERY texel (fullscreen, no skips),
 so the flipped buffer is never left with stale content. depthtex0/depthtex1/
 colortex2 are read-only.

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

 Sampler count (worst case, clouds ON):
   base: colortex0, colortex3, colortex4, colortex5, depthtex1 = 5
   clouds: + colortex7 + noisetex + colortex6 (sky LUT, via the
           lib/atmosphere.glsl include) = 8   (<= 16 Mac hard limit / validator).
*/

uniform sampler2D colortex0;   // scene HDR
uniform sampler2D colortex3;   // G-buffer matID .r (player/hand cloud occlusion)
uniform sampler2D colortex4;   // this frame's AO (r), confidence (g)
uniform sampler2D colortex5;   // AO history (rgb) + persistent exposure in .a (preserved)
uniform sampler2D depthtex1;   // opaque-only depth (stored history depth + cloud far bound)

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

    // ISSUE 2 ("night clouds too bright/white"): darken + cool the cloud radiance
    // at night so clouds read as dark, moody, moonlit masses (dark undersides)
    // instead of glowing daytime white. Gated by the sun-elevation day factor so
    // NOON is provably untouched (dayF==1 -> factor 1.0). Applied POST-temporal so
    // the history stays view/time-independent and converges cleanly across dusk.
    float cloudDayF  = smoothstep(-0.06, 0.16, sunDir.y);
    vec3  nightCloud = mix(AL_CLOUD_NIGHT_TINT, vec3(1.0), cloudDayF)
                     * mix(AL_CLOUD_NIGHT_BRIGHT, 1.0, cloudDayF);
    dispScatter *= nightCloud;

    // Clouds must NEVER draw over the player body (3rd person) or the held item /
    // hand (1st person). Those surfaces are tagged ENTITY / HAND; the player's
    // translucent skin layers (hat, jacket) are excluded from depthtex1, so without
    // this the cloud march runs past them and clouds show THROUGH the player. Force
    // full occlusion (scene, no cloud) on those pixels.
    int pmat = alDecodeMatID(texture(colortex3, texcoord).r);
    if (pmat == AL_MATID_ENTITY || pmat == AL_MATID_HAND) {
        dispTrans   = 1.0;
        dispScatter = vec3(0.0);
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

    // ---- AO history copy (VERBATIM — no spatial filter) --------------------
    // r = AO, g = confidence, b = linear eye depth of this sample. Range tests,
    // not clamp() — NaN fails every comparison and falls through to the safe
    // default so colortex5 can never carry a non-finite value forward.
    // The AO is stored RAW: colortex5 feeds deferred's temporal accumulator,
    // which feeds colortex4, which this pass copies back — filtering inside that
    // loop compounds every frame and flattens the AO. The single spatial denoise
    // lives at read time in deferred1. See the file header (job 3).
    vec2  ao    = texture(colortex4, texcoord).rg;
    float depth = texture(depthtex1, texcoord).r;   // opaque depth -> stored history depth
    float aoR   = (ao.r >= 0.0 && ao.r <= 1.0) ? ao.r : 1.0;
    float aoG   = (ao.g >= 0.0 && ao.g <= 1.0) ? ao.g : 0.0;

    float linZ  = (depth >= 1.0) ? 0.0
                                 : alLinearEyeDepth(alScreenToView(texcoord, depth));
    linZ = (linZ >= 0.0 && linZ < 65000.0) ? linZ : 0.0;

    // PRESERVE the persistent auto-exposure slot: colortex5.a at texel (0,0) is
    // last frame's adapted exposure (written by composite14, which runs after this
    // pass). Passing the stored .a through unchanged keeps a SINGLE authoritative
    // writer of the exposure value, so composite14's integrator reads the TRUE
    // previous exposure. Range-guarded [0.2,5.0] -> 1.0 so the persistent buffer
    // stays finite (clear=false: the undefined first frame self-heals to 1.0);
    // this only touches .a and never the AO history rgb.
    float prevExp = texelFetch(colortex5, ivec2(gl_FragCoord.xy), 0).a;
    prevExp = (prevExp >= 0.2 && prevExp <= 5.0) ? prevExp : 1.0;
    outHistory = vec4(aoR, aoG, linZ, prevExp);
}
