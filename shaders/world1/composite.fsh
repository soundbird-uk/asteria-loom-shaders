#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/clouds_common.glsl"
#include "/lib/water.glsl"
#include "/lib/pbr.glsl"

/*
============================================================================
 composite (fragment) — WATER EFFECTS. Runs AFTER translucents, BEFORE the
 clouds pass (composite1) and fog pass (composite2).
----------------------------------------------------------------------------
 gbuffers_water tagged every water pixel: colortex3.r = matID WATER, colortex2
 = ripple normal (.rg) + lightmap (.ba). For those pixels this pass:

   1. SSR — reconstruct the water surface view position from depthtex0, decode
      the ripple normal, reflect the view ray and RAYMARCH it in VIEW SPACE
      against depthtex0 (16/24/32 steps by SSR_QUALITY, binary-search refined,
      dithered start, normal-biased origin, screen-edge + thickness rejection).
      Hit -> sample the post-translucent scene (colortex0); miss/off-screen ->
      the analytic IN-FILL (sky for up rays, the water's own depth-tinted body
      colour for horizon/downward rays — NEVER black). Blended over the water via
      Schlick Fresnel (f0=0.02). Gated INTERNALLY by SSR so absorption + caustics
      still run with SSR off.

   1b. SSR TEMPORAL ACCUMULATION (colortex10) — the reflection resolved above is
      reprojected through the motion vector (lib/space.glsl alMotionVector) and
      blended with the previous frame's result, clipped to mean +/- gamma*sigma of
      this frame's glossy ring taps. That converts the per-pixel ray/ripple noise
      into a stable, SHARP reflection instead of a grainy one. Iris flip rule: a
      composite program reads the 'main' buffer and writes the 'alt' buffer, so
      reading colortex10 here while also listing it in RENDERTARGETS is legal and
      returns last frame's content (nothing else writes it); `clear.colortex10 =
      false` keeps it alive across frames. colortex12 (R8) carries the matching
      per-pixel CONFIDENCE so a freshly disoccluded pixel ramps up to the history
      ceiling over several frames instead of locking onto one noisy frame.

   2. ABSORPTION — where an opaque surface sits behind the water (depthtex1 >
      depthtex0), tint the pixel by Beer-Lambert over the water PATH LENGTH
      between the two linearized depths (green-blue: red absorbed most). HONEST
      APPROXIMATION (documented): colortex0 here already blended the translucent
      water over the scene, so we cannot isolate the transmitted term — we apply
      absorption as a MULTIPLICATIVE darkening of the pixel, weighted by
      (1 - Fresnel) so it reads as depth-dependent water colour and vanishes into
      the reflection at grazing.

   3. CAUSTICS (behind WATER_CAUSTICS) — an animated 2-octave voronoi network
      (pure math, lib/water.glsl) evaluated at the SUBMERGED surface position
      (reconstructed from depthtex1) and projected along the sun direction
      (alSunDirWorld, sampler-free). Modulates the submerged contribution ±~28%,
      scaled by water-depth falloff, the water surface's sky lightmap, and the
      day factor. Soft, dreamy, slow.

   4. REFLECTIVE BLOCKS (REFLECTIVE_BLOCKS) — a full micro-facet GGX reflection
      (lib/pbr.glsl): F0 = albedo for metals / 0.04 for dielectrics, weighted by
      the split-sum environment BRDF so a ROUGH metal reflects a dim, blurred
      environment instead of a chrome mirror, and energy-conserving against the
      forward-lit base.

 The pass ALWAYS runs (NOT gated on SSR — that would kill absorption/caustics
 with SSR off, contract §6). Non-water pixels take a one-line early-out — but
 they still WRITE BOTH render targets: Iris documents that a buffer listed in
 RENDERTARGETS and not written by an invocation receives GARBAGE data.

 SAMPLER BUDGET (recount): 10 of 16 (Mac GL 4.1 limit; the pack's own <=14) —
   1 colortex0  (scene, SSR hit colour + base)
   2 colortex2  (water ripple normal .rg + lightmap .ba)
   3 colortex3  (matID mask)
   4 depthtex0  (translucent-inclusive = water surface depth; SSR march target)
   5 depthtex1  (opaque-only depth = scene behind the water)
   6 noisetex   (declared by lib/water.glsl's includes; SSR itself uses IGN)
   7 colortex6  (sky-view LUT, via lib/atmosphere.glsl alSkySample)
   8 colortex10 (SSR temporal history)
   9 colortex12 (SSR temporal confidence)
  10 colortex1  (albedo, only under REFLECTIVE_BLOCKS)
 lib/space.glsl, lib/pbr.glsl and lib/clouds_common.glsl add only matrices/plain
 uniforms (no samplers). NaN-law: every clear=false read (colortex6, colortex10)
 is range-validated before use; reconstruction is guarded; the result falls back
 to the untouched scene on any non-finite value (fail toward the plain scene).
 colortex12 is R8, so the hardware clamps it to [0,1] and it can never hold a NaN
 even on its undefined first frame — the worst an uncleared texel can do is grant
 a full history ceiling for one frame.
============================================================================
*/

// SSR step count from the quality tier (16 / 24 / 32).
#if SSR_QUALITY == 1
    #define AL_SSR_STEPS 16
#elif SSR_QUALITY == 3
    #define AL_SSR_STEPS 32
#else
    #define AL_SSR_STEPS 24
#endif

uniform sampler2D colortex0;   // scene HDR (opaque + translucents blended)
uniform sampler2D colortex2;   // water surface: normal .rg, lightmap .ba
uniform sampler2D colortex3;   // matID .r, reflectivity .b, metalness .a
uniform sampler2D depthtex0;   // translucent-inclusive depth (water surface)
uniform sampler2D depthtex1;   // opaque-only depth (behind the water)
uniform sampler2D noisetex;    // blue-ish noise for the dithered SSR start
uniform sampler2D colortex10;  // SSR temporal history: rgb = reflection, a = eye depth
uniform sampler2D colortex12;  // SSR temporal confidence: r = earned history ceiling
#ifdef REFLECTIVE_BLOCKS
uniform sampler2D colortex1;   // albedo — metal F0 IS the block's own colour
#endif

// Forward matrices for the view-space raymarch projection. lib/space.glsl owns
// the INVERSE matrices + cameraPosition/previous* (do not redeclare those);
// these two are declared nowhere else, so declaring them here is collision-free.
uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

uniform int frameCounter;      // Iris: frame index (wraps) for the R2 dither

in vec2 texcoord;

// The SSR history targets are bound UNCONDITIONALLY (not behind
// #ifdef AL_SSR_TEMPORAL): the RENDERTARGETS directive is a comment the pipeline
// parses BEFORE preprocessing, so the declared `out` set must not depend on an
// option. With accumulation disabled the pass simply writes a neutral reset.
/* RENDERTARGETS: 0,10,12 */
layout(location = 0) out vec4 outColor;   // -> colortex0 (water-reflected scene)
layout(location = 1) out vec4 outSSR;     // -> colortex10 (SSR history: rgb + eye depth)
layout(location = 2) out vec4 outSSRConf; // -> colortex12 (SSR history: r = confidence)

// View-space linear eye distance in front of the camera (positive).
float alEyeZ(vec3 viewPos) { return -viewPos.z; }

/*
 SSR raymarch in view space against depthtex0. `origin` is the reflective
 surface's view position, `normalV` its view-space normal and `dir` the reflected
 view direction (unit). Returns true + the hit UV when the ray crosses behind a
 thin surface on-screen; false otherwise.
 Standard scheme: fixed-length steps with a dithered start, detect the crossing
 (rayPos passes behind the sampled surface: rayPos.z < sceneZ), reject when the
 gap exceeds a thickness tolerance (ray slipped behind a foreground object), and
 binary-search between the last in-front and first behind sample to refine.

 RAY HYGIENE (5.3.0) — two rejections that the old trace lacked:
  * INTO-SURFACE rays. reflect() can return a direction pointing back into the
    geometry when the (rippled / interpolated) normal disagrees with the visible
    surface. Such a ray immediately marches behind the surface it started on,
    the very first sample "crosses", and the trace returns the surface's own
    screen colour — which, for a near-horizontal reflection, is the bright sky
    horizon band pasted INSIDE the block ("as if you are looking through them").
    dot(dir, normalV) <= AL_SSR_MIN_DOT is rejected outright.
  * SELF-INTERSECTION. The march now starts offset ALONG THE NORMAL (scaled with
    view distance, where a depth texel spans more world), so the first steps
    cannot re-hit the origin pixel and produce a false, angle-dependent hit —
    the cause of reflections that only appeared at certain specific angles.
*/
bool alTraceSSR(vec3 origin, vec3 normalV, vec3 dir, float dither, out vec2 hitUV) {
    hitUV = vec2(0.0);

    // A reflected ray must leave the surface, never enter it.
    if (dot(dir, normalV) <= AL_SSR_MIN_DOT) return false;

    float stepLen = AL_SSR_MAX_DIST / float(AL_SSR_STEPS);
    // Normal bias grows with distance: one depth texel covers more world there.
    float nBias   = AL_SSR_NORMAL_BIAS + length(origin) * AL_SSR_NORMAL_DISTK;
    vec3  rayPos  = origin + normalV * nBias + dir * stepLen * (0.5 + dither);

    for (int i = 0; i < AL_SSR_STEPS; i++) {
        rayPos += dir * stepLen;

        vec4 clip = gbufferProjection * vec4(rayPos, 1.0);
        if (clip.w <= 0.0) return false;                       // behind camera
        vec2 uv = (clip.xy / clip.w) * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) return false;

        float sd = texture(depthtex0, uv).r;
        if (sd >= 1.0) continue;                               // sky here, no hit
        vec3 scene = alScreenToView(uv, sd);

        // Both z are negative (view forward = -z). rayPos behind surface => more
        // negative than scene.z => (rayPos.z - scene.z) < 0.
        if (rayPos.z - scene.z < 0.0) {
            float thick = scene.z - rayPos.z;                  // positive gap
            if (thick < AL_SSR_THICKNESS + stepLen) {
                // Binary-search refine between the previous (in-front) sample and
                // this (behind) sample.
                vec3 a = rayPos - dir * stepLen;
                vec3 b = rayPos;
                for (int r = 0; r < AL_SSR_REFINE; r++) {
                    vec3 m = (a + b) * 0.5;
                    vec4 mc = gbufferProjection * vec4(m, 1.0);
                    vec2 muv = (mc.xy / mc.w) * 0.5 + 0.5;
                    float msd = texture(depthtex0, muv).r;
                    vec3 ms = alScreenToView(muv, msd);
                    if (m.z - ms.z < 0.0) b = m; else a = m;
                }
                vec4 bc = gbufferProjection * vec4(b, 1.0);
                hitUV = (bc.xy / bc.w) * 0.5 + 0.5;
                return true;
            }
            return false;   // crossed but too thick -> behind an object, reject
        }
    }
    return false;
}

// Glossy pre-filter of an SSR hit colour. Averages colortex0 over a small
// golden-angle ring around the hit UV so the high-frequency per-pixel variance
// from micro-ripple normals + the frozen SSR dither (the "grid grain" on water
// from above) resolves into a smooth gloss. Deterministic — no history, no
// motion — so it cannot flicker or jitter with the camera. Radius grows with
// view distance where the ripple pattern aliases hardest. Off-screen and
// HDR-garbage taps are dropped so it can never smear the screen edge or bloom.
// Interleaved Gradient Noise — a fine, NON-TILING per-pixel value. Replaces the
// old `texture(noisetex, gl_FragCoord/256)` SSR ray-start dither, which repeated
// every 256 px and printed a stable grid onto water reflections (the grid grain).
// IGN is spatially coherent between neighbours, so adjacent rays march together
// and hit/miss coherently instead of checkerboarding.
float alIGN(vec2 p) {
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec3 alGlossyReflSample(vec2 hitUV, float viewDist, out vec3 ringMean, out vec3 ringSigma) {
    vec2  texel  = 1.0 / vec2(textureSize(colortex0, 0));
    float radius = AL_SSR_GLOSS_RADIUS + viewDist * AL_SSR_GLOSS_DISTK;

    vec3  acc = vec3(0.0);
    vec3  acc2 = vec3(0.0);          // second moment, for the temporal clip box
    float wsum = 0.0;
    // Centre tap.
    {
        vec3 c = texture(colortex0, hitUV).rgb;
        if (all(greaterThanEqual(c, vec3(0.0))) && all(lessThan(c, vec3(65000.0)))) {
            acc += c; acc2 += c * c; wsum += 1.0;
        }
    }
    for (int i = 0; i < AL_SSR_GLOSS_TAPS; i++) {
        float a = float(i) * 2.399963230;                 // golden angle
        vec2  o = vec2(cos(a), sin(a)) * radius * texel;
        vec2  suv = hitUV + o;
        if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;
        vec3  c = texture(colortex0, suv).rgb;
        if (!(all(greaterThanEqual(c, vec3(0.0))) && all(lessThan(c, vec3(65000.0))))) continue;
        acc += c; acc2 += c * c; wsum += 1.0;
    }
    vec3 result = (wsum > 0.5) ? (acc / wsum) : texture(colortex0, hitUV).rgb;
    // Mean/sigma over the SAME taps: the local reflection distribution this
    // frame. The temporal pass clips its history into mean +/- gamma*sigma, the
    // statistical box composite3's TAA uses — it keeps accumulation sharp and
    // ghost-free instead of degenerating into a temporal blur.
    ringMean  = result;
    ringSigma = vec3(0.0);
    if (wsum > 1.5) {
        vec3 m1 = acc / wsum;
        vec3 var = max(acc2 / wsum - m1 * m1, vec3(0.0));
        ringMean  = m1;
        ringSigma = sqrt(var);
    }
    return result;
}

#ifdef AL_SSR_TEMPORAL
/*
 SSR TEMPORAL ACCUMULATION (colortex10).

 `current` is this frame's resolved reflection for a pixel whose reflective
 surface sits at view position `viewPos`; `mean`/`sigma` describe the local
 reflection distribution measured this frame (the glossy ring statistics, or a
 zero sigma for a purely analytic in-fill, which needs no accumulation).

 Reprojection uses the shared motion vector (lib/space.glsl). History is accepted
 only when the reprojected pixel is on-screen AND its recorded eye depth agrees
 with the depth we now predict, so a disocclusion resets instead of smearing.
 `outHistory` is the value to store back (rgb = accumulated reflection, a = the
 CURRENT eye depth, which is what the NEXT frame will predict and compare) and
 `outConf` is the matching confidence for colortex12.

 Two independent terms gate how much history survives:
   CEILING — the confidence earned so far, read from colortex12 and raised by
             AL_SSR_T_CONF_STEP on every consecutively accepted frame. A pixel
             that just disoccluded starts at one step (~1/7th of the ceiling), so
             it converges over several frames instead of instantly locking onto a
             single noisy frame — the shadow history (deferred1) works the same way.
   TRUST   — how far the history had to be statistically clipped THIS frame. A
             stable reflection is barely clipped and keeps its full ceiling; a
             changing one is clipped hard and drops back to reactive immediately,
             which is what keeps the result sharp rather than ghosted.

 NaN law: every acceptance test is a comparison, so a poisoned history texel
 (colortex10 has clear=false, and its first-frame contents are undefined) fails
 every one of them and falls through to `current`. colortex12 is R8, so it cannot
 hold a NaN at all; its undefined first frame is clamped into [0,1] and can only
 ever grant a ceiling the TRUST term still has to agree with.
*/
vec3 alAccumulateSSR(vec3 current, vec3 viewPos, vec3 mean, vec3 sigma,
                     out vec4 outHistory, out float outConf) {
    float eyeZ = alLinearEyeDepth(viewPos);
    vec3  result = current;
    // A rejected history resets the ramp to its first step, so the NEXT frame
    // may blend at most AL_SSR_T_CONF_STEP of it.
    float conf   = AL_SSR_T_CONF_STEP;

    vec2 prevUV; float prevEyeZ;
    if (alMotionVector(viewPos, texcoord, prevUV, prevEyeZ)) {
        vec4 hist = texture(colortex10, prevUV);
        bool ok = all(greaterThanEqual(hist.rgb, vec3(0.0)))
               && all(lessThan(hist.rgb, vec3(65000.0)))
               && alHistoryDepthOK(hist.a, prevEyeZ, AL_SSR_T_DEPTH_REJECT);
        if (ok) {
            // Statistical clip: only the part of the history that still agrees
            // with this frame's local reflection distribution survives.
            vec3 lo = mean - AL_SSR_T_CLIP_GAMMA * sigma;
            vec3 hi = mean + AL_SSR_T_CLIP_GAMMA * sigma;
            vec3 clipped = clamp(hist.rgb, min(lo, hi), max(lo, hi));
            float drift = length(clipped - hist.rgb) / (length(mean) + 1.0e-3);
            float trust = alSaturate(1.0 - drift);
            // Ceiling earned so far (clamped: colortex12's undefined first frame
            // is in-range garbage, never more than the ceiling we allow anyway).
            float earned = clamp(texture(colortex12, prevUV).r,
                                 0.0, AL_SSR_T_MAX_BLEND);
            float blend  = min(earned, AL_SSR_T_MAX_BLEND * trust);
            result = mix(current, clipped, blend);
            conf   = min(earned + AL_SSR_T_CONF_STEP, AL_SSR_T_MAX_BLEND);
        }
    }

    bool good = all(greaterThanEqual(result, vec3(0.0)))
             && all(lessThan(result, vec3(65000.0)));
    result = good ? result : current;
    outHistory = vec4(result, (eyeZ > 0.0 && eyeZ < 65000.0) ? eyeZ : 0.0);
    outConf    = good ? conf : AL_SSR_T_CONF_STEP;
    return result;
}
#endif

#ifdef REFLECTIVE_BLOCKS
/*
 Material-dependent reflection for a SOLID reflective block (ice / metal / polished)
 or reflective translucent ice. reflAmt (colortex3.b) is the surface reflectivity,
 metal (colortex3.a) selects the model. 5.3.0 rewrite — full micro-facet PBR:

   F0        = albedo for a METAL, 0.04 for a DIELECTRIC (lib/pbr.glsl
               alF0FromAlbedo). A metal's reflection colour IS its F0; the old
               code used a flat achromatic 0.75 for metals, which is why an iron
               block read as chrome.
   ENV BRDF  = the split-sum DFG integral (alEnvBRDFApprox), NOT a bare Fresnel.
               This is the term that makes reflectivity fall with roughness and
               rise with grazing angle: rough iron reflects ~0.45 of F0 head-on
               and more at glancing angles, so it looks like brushed metal that
               still catches the light, never a mirror.
   ENERGY    = the specular replaces the fraction of the base it reflects
               (base * (1 - dfg) + env * dfg), so the block cannot end up
               brighter than the light it receives.

 The environment itself is the sky LUT blurred toward the zenith ambient by the
 roughness lobe (the pack has no pre-filtered env mip chain), with the occluded-
 horizon fade for near-horizontal rays. SSR (sharp, on-screen) is layered in only
 while the surface is smooth enough for it to be meaningful. NaN-safe: any
 non-finite result falls back to `base`.
*/
vec3 alReflectiveBlock(vec3 base, float reflAmt, float metal,
                       out vec4 histOut, out float confOut) {
    histOut = vec4(0.0);
    confOut = 0.0;

    float d0 = texture(depthtex0, texcoord).r;
    vec3  P0 = alScreenToView(texcoord, d0);
    float dist0 = length(P0);
    if (!(dist0 >= 0.0) || dist0 > 1.0e7) return base;

    vec3  Nw = alDecodeNormal(texture(colortex2, texcoord).rg);
    vec3  Nv = normalize(mat3(gbufferModelView) * Nw);
    vec3  I  = normalize(P0);
    vec3  V  = -I;                                  // surface -> eye
    float NoV = max(dot(V, Nv), 1.0e-4);

    // Roughness: iron/gold BLOCKS are rough metal, not chrome.
    float rough = mix(AL_REFL_ROUGH_DIELECTRIC, AL_REFL_ROUGH_METAL, metal);
    float lobe  = alEnvLobeBlend(rough);            // 0 = mirror, 1 = fully diffuse env

    vec3  albedo = texture(colortex1, texcoord).rgb;
    vec3  F0     = alF0FromAlbedo(albedo, metal, AL_REFL_F0_DIELECTRIC);

    float skyLm   = alSaturate(texture(colortex2, texcoord).a);
    float skyGate = smoothstep(0.0, 0.35, skyLm);
    vec3  Rv = reflect(I, Nv);
    vec3  Rw = normalize(alViewDirToWorld(Rv));

    // OCCLUDED-HORIZON FIX ("horizon bar reflected INSIDE the block"): a near-
    // horizontal reflected ray almost always hits terrain, not the bright sky
    // horizon band. Fade it to the soft zenith ambient as Rw nears the horizon.
    float upCut    = smoothstep(0.0, 0.20, Rw.y);
    vec3  skySharp = alSkySample(Rw);
    vec3  ambient  = alSkySample(vec3(0.0, 1.0, 0.0));   // soft zenith env (rough blur)
    vec3  envRefl  = mix(skySharp, ambient, lobe);       // rough -> blurred env
    envRefl = mix(ambient * 0.4, envRefl, upCut);        // occluded horizon -> dim ambient
    // NO-SKY (indoor) FALLBACK. A metal has (almost) no diffuse lobe, so if its
    // environment collapsed to a near-black constant indoors the block would read
    // as a black hole — physically "correct" and visually broken. Instead the
    // environment falls back to the block's OWN forward-lit colour, which is a
    // cheap but energy-sane stand-in for the room's radiance: an indoor iron block
    // then reflects the light it is actually standing in.
    envRefl = mix(base * AL_REFL_INDOOR_ENV, envRefl, skyGate);

    vec3 ringMean  = envRefl;
    vec3 ringSigma = vec3(0.0);

#ifdef SSR
    // Sharp SSR only meaningfully contributes for SMOOTH surfaces; a mirror-sharp
    // reflection on rough iron reads as chrome, so weight it by the lobe and drop
    // it entirely past AL_REFL_SSR_MAX_ROUGH.
    float ssrW = (rough < AL_REFL_SSR_MAX_ROUGH) ? (1.0 - lobe) : 0.0;
    if (ssrW > 0.05) {
        float dither = alIGN(gl_FragCoord.xy);
    #if defined(AL_TAA) || defined(AL_SSR_TEMPORAL)
        // The dither must ADVANCE per frame for the temporal pass to have new
        // samples to average; with neither TAA nor SSR accumulation it stays
        // frozen (a static pattern beats a crawling one when nothing resolves it).
        dither = fract(dither + float(frameCounter) * 0.61803398875);
    #endif
        vec2 hitUV;
        if (alTraceSSR(P0, Nv, Rv, dither, hitUV)) {
            // Glossy pre-filter, widened by roughness so rough metal never chromes
            // and the SSR grain averages out. dist0*(1+rough) grows the kernel.
            vec3 mean, sigma;
            vec3 hitCol = alGlossyReflSample(hitUV, dist0 * (1.0 + rough * 4.0), mean, sigma);
            vec2 e = smoothstep(vec2(0.0), vec2(AL_SSR_EDGE_FADE), hitUV)
                   * (1.0 - smoothstep(vec2(1.0 - AL_SSR_EDGE_FADE), vec2(1.0), hitUV));
            float edgeFade = e.x * e.y * ssrW;
            bool okHit = all(greaterThanEqual(hitCol, vec3(0.0)))
                      && all(lessThan(hitCol, vec3(65000.0)));
            if (okHit) {
                // Both mixes must start from the SAME in-fill reference: reading
                // the already-updated envRefl here would blend it twice and drag
                // the temporal clip box toward hitCol near the screen edges
                // (where edgeFade is partial), letting stale history survive.
                vec3 infill = envRefl;
                envRefl   = mix(infill, hitCol, edgeFade);
                ringMean  = mix(infill, mean,   edgeFade);
                ringSigma = sigma * edgeFade;
            }
        }
    }
#endif

#ifdef AL_SSR_TEMPORAL
    envRefl = alAccumulateSSR(envRefl, P0, ringMean, ringSigma, histOut, confOut);
#endif

    // --- Micro-facet composition ------------------------------------------
    // dfg is the split-sum environment BRDF: the fraction (and colour) of the
    // environment this micro-surface actually reflects toward the eye.
    vec3 dfg = alEnvBRDFApprox(F0, rough, NoV)
             * alSaturate(reflAmt * REFLECTIVE_STRENGTH);

    // Metals have (almost) no diffuse lobe; dielectrics keep theirs in full.
    vec3 diffuseKeep = base * mix(1.0, AL_REFL_METAL_DIFFUSE, alSaturate(metal));
    // Energy conservation: what is reflected is not also transmitted/diffused.
    vec3 result = diffuseKeep * (vec3(1.0) - dfg) + envRefl * dfg;

    bool ok = all(greaterThanEqual(result, vec3(0.0)));
    return ok ? min(result, vec3(65000.0)) : base;
}
#endif

void main() {
    vec3 base = texture(colortex0, texcoord).rgb;
    // Iris: a buffer listed in RENDERTARGETS but not written by an invocation
    // receives GARBAGE. Every early-out below therefore leaves a valid history
    // value; vec4(0.0) is the "no reflection here" reset (depth 0 fails the next
    // frame's alHistoryDepthOK test, so it can never be blended in).
    outSSR     = vec4(0.0);
    outSSRConf = vec4(0.0);

#if DEBUG_VIEW != 0
    // Keep the debug probes / raw-channel views exactly as upstream wrote them —
    // water FX must never colour a debug view (matches composite2's pattern).
    outColor = vec4(base, 1.0);
    return;
#endif

    vec4 m3  = texture(colortex3, texcoord);
    int  mat = alDecodeMatID(m3.r);

#ifdef REFLECTIVE_BLOCKS
    // Reflective solid blocks (ice / metal / polished) and reflective translucent
    // ice — tagged with reflectivity in colortex3.b (+ metalness in .a). Not water.
    if (mat != AL_MATID_WATER && m3.b > 0.01) {
        vec4  blockHist;
        float blockConf;
        vec3 blockCol = alReflectiveBlock(base, m3.b, m3.a, blockHist, blockConf);
        outColor   = vec4(blockCol, 1.0);
        outSSR     = blockHist;
        outSSRConf = vec4(blockConf);
        return;
    }
#endif

    // Non-water pixels: untouched.
    if (mat != AL_MATID_WATER) {
        outColor = vec4(base, 1.0);
        return;
    }

    float d0 = texture(depthtex0, texcoord).r;

    // Reconstruct the water surface view position; guard degenerate math.
    vec3 P0 = alScreenToView(texcoord, d0);
    float dist0 = length(P0);
    if (!(dist0 >= 0.0) || dist0 > 1.0e7) {
        outColor = vec4(base, 1.0);
        return;
    }

    // Decode the ripple normal (world) -> view space for the raymarch.
    vec3 Nw = alDecodeNormal(texture(colortex2, texcoord).rg);
    vec3 Nv = normalize(mat3(gbufferModelView) * Nw);
    vec3 I  = normalize(P0);                       // camera -> surface (view)

    // The transmitted-vs-reflected SPLIT is driven by the GEOMETRIC water-plane
    // angle (view vs world-up), NOT the rippled normal. Using the rippled normal
    // let every wave tilt raise Fresnel, so the surface reflected the blue sky
    // everywhere and hid the bottom even looking straight down (field report). The
    // flat-plane Fresnel keeps water see-through when you look down and reflective
    // only at true grazing angles; the rippled normal still steers the reflection
    // DIRECTION (Rv/Rw below) and the sun glint, so ripples still sparkle.
    vec3  Iw     = normalize(alViewDirToWorld(I));
    float cosGeo = alSaturate(-Iw.y);              // 1 looking straight down, 0 grazing
    float fres = AL_WATER_F0 + (1.0 - AL_WATER_F0) * pow(1.0 - cosGeo, 5.0);
    fres = min(alSaturate(fres), AL_WATER_REFLECT_MAX);

    // Crest foam (baked into `base` by gbuffers_water, amount in colortex3.b) must
    // stay MATTE — kill its reflection so the whitecap doesn't chrome over.
    float foamAmt = alSaturate(m3.b);
    fres *= (1.0 - foamAmt);

    // --- Reflection colour ---------------------------------------------------
    // Sky-access gate: water with no open sky above it (caves, covered flowing
    // water) must NOT reflect the sky — otherwise the bright horizon band shows in
    // the water underground (field report). Fade the sky fallback to a dark cave
    // reflection as the water's sky lightmap falls.
    float wSkyLm  = alSaturate(texture(colortex2, texcoord).a);
    float skyGate = smoothstep(0.0, 0.35, wSkyLm);
    vec3 Rv = reflect(I, Nv);
    vec3 Rw = normalize(alViewDirToWorld(Rv));
    // OCCLUDED-HORIZON FIX: a near-horizontal reflected ray almost always hits shore
    // terrain / mountains, not open sky — but the sky LUT has a bright horizon band
    // there that SSR-misses would paint onto the water as a jarring bright line.
    // Fade the reflected SKY toward a dark water tone as the ray nears the horizon
    // (Rw.y small); only up-pointing rays show real sky. SSR overrides below with
    // actual on-screen geometry where it hits.
    float upCut = smoothstep(AL_WATER_REFL_HORIZON_LO, AL_WATER_REFL_HORIZON_HI, Rw.y);

    // --- SSR IN-FILL (the fix for the griddy dark patches, image_6af8bc.jpg) --
    // A screen-space ray can only hit what is on screen. Seen from above, the
    // sharp Gerstner crests scatter reflected rays toward the horizon and below
    // it, where the march has no data at all — and the old fallback for those
    // directions was a near-black constant, so the misses printed a dark, uniform
    // grain GRID over the water. The in-fill gives every direction a plausible,
    // never-black reflection instead:
    //   * up-pointing rays        -> the real sky LUT sample,
    //   * horizon/downward rays   -> the water's OWN body colour (AL_WATER_TINT,
    //                                the same tint the Beer-Lambert absorption
    //                                below drives toward), lit by the ambient sky
    //                                and floored so it can never resolve to black.
    // Because the fallback is a smooth analytic function of the reflected
    // direction, neighbouring hit and miss pixels differ by a soft amount rather
    // than by "scene colour vs black" — the grid cannot form even where the
    // hit/miss pattern itself is high frequency.
    vec3  skyAmb   = alSkySample(vec3(0.0, 1.0, 0.0));
    float ambLum   = max(alLuminance(skyAmb), 0.0);
    // NIGHT-AWARE IN-FILL: the occluded-ray body tone and the fixed floor must
    // scale with ambient light, otherwise at night the water holds an unrealistic
    // persistent bright-blue glow from AL_WATER_REFL_OCCLUDED and the fixed
    // AL_WATER_INFILL_FLOOR regardless of actual sky brightness. nightK goes
    // from 0 at deep night to 1 at full day; a small floor keeps a hint of tone
    // visible even under the moon so the surface never reads as pure black.
    float nightK   = alSaturate(ambLum * 7.0);
    float inFillFloor = AL_WATER_INFILL_FLOOR * max(nightK, 0.04);
    vec3  occluded = AL_WATER_REFL_OCCLUDED   * max(nightK, 0.12);
    vec3  bodyTone = max(AL_WATER_TINT * max(ambLum * AL_WATER_INFILL_BODY_K,
                                             inFillFloor),
                         occluded);
    vec3  skyR  = mix(bodyTone, alSkySample(Rw), upCut);
    vec3 refl = mix(vec3(0.015, 0.020, 0.035), skyR, skyGate);  // in-fill + cave gate
    vec3 ringMean  = refl;      // analytic in-fill: noise-free, so sigma stays 0
    vec3 ringSigma = vec3(0.0);

#ifdef SSR
    // Non-tiling IGN ray-start (was a 256px-tiling noisetex lookup -> grid grain).
    // Coherent between neighbours so adjacent rays hit/miss together. Advanced per
    // frame whenever something downstream resolves it (TAA, or this pass's own
    // temporal accumulation); frozen otherwise so it cannot crawl.
    float dither = alIGN(gl_FragCoord.xy);
#if defined(AL_TAA) || defined(AL_SSR_TEMPORAL)
    dither = fract(dither + float(frameCounter) * 0.61803398875);
#endif

    vec2 hitUV;
    if (alTraceSSR(P0, Nv, Rv, dither, hitUV)) {
        // Glossy pre-filter: average a small ring around the hit so the SSR
        // "grid grain" (per-pixel ripple/dither divergence) reads as smooth gloss.
        vec3 mean, sigma;
        vec3 hitCol = alGlossyReflSample(hitUV, dist0, mean, sigma);
        // Fade the reflection to the in-fill near the screen edges (the march
        // has no data past them) so reflections don't clip hard. AL_WATER_INFILL_SOFT
        // additionally softens EVERY hit into the in-fill, so a hit pixel and its
        // missing neighbour differ gradually instead of forming a hard cell edge.
        vec2 e = smoothstep(vec2(0.0), vec2(AL_SSR_EDGE_FADE), hitUV)
               * (1.0 - smoothstep(vec2(1.0 - AL_SSR_EDGE_FADE), vec2(1.0), hitUV));
        float edgeFade = e.x * e.y * (1.0 - AL_WATER_INFILL_SOFT);
        bool okHit = all(greaterThanEqual(hitCol, vec3(0.0)))
                  && all(lessThan(hitCol, vec3(65000.0)));
        if (okHit) {
            // Same in-fill reference for both mixes (see the block path above):
            // reading the updated refl would double-blend the clip-box centre.
            vec3 infill = refl;
            refl      = mix(infill, hitCol, edgeFade);
            ringMean  = mix(infill, mean,   edgeFade);
            ringSigma = sigma * edgeFade;
        }
    }
#endif

#ifdef AL_SSR_TEMPORAL
    // Temporal accumulation of the resolved reflection (see alAccumulateSSR).
    // This is what removes the residual per-frame graininess that no spatial
    // filter can: the stochastic ray start + micro-ripple normals average out
    // over ~12 frames while the statistical clip keeps the result sharp.
    float waterConf;
    refl = alAccumulateSSR(refl, P0, ringMean, ringSigma, outSSR, waterConf);
    outSSRConf = vec4(waterConf);
#endif

    // SUN GLINT: the sun disc is not in the depth buffer, so SSR can never reflect
    // it. Add an analytic specular toward the sun so open water sparkles with the
    // sun (a tight core + a soft glossy lobe), day-factor scaled and gated to open
    // sky. This is the "reflect the sun" the field report asked for.
    {
        vec3  sunDirW = alSunDirWorld();
        float sd      = max(dot(Rw, sunDirW), 0.0);
        float glint   = pow(sd, AL_WATER_SUN_SPEC_POW) + 0.12 * pow(sd, 8.0);
        float dayF    = alSmooth(smoothstep(-0.06, 0.16, sunDirW.y));
        refl += alDirectColor(sunDirW) * (glint * AL_WATER_SUN_SPEC
                                          * mix(0.12, 1.0, dayF) * skyGate);
    }

    // --- Refraction + absorption + caustics on the submerged scene -----------
    vec3  transmitted = base;
    float d1 = texture(depthtex1, texcoord).r;
    float skyLm = alSaturate(texture(colortex2, texcoord).a);
    float contactFoam = 0.0;

    if (d1 > d0 && d1 < 1.0) {
        vec3 P1 = alScreenToView(texcoord, d1);
        float waterPath = max(alEyeZ(P1) - alEyeZ(P0), 0.0);   // metres through water

        // SCREEN-SPACE REFRACTION: bend the submerged sample by the surface normal
        // (view xy), subtle + distance-faded, and FADE THE OFFSET TO ZERO near the
        // screen edges (plus a hard clamp) so a distorted UV can never sample off-
        // screen and smear/black-edge when the camera moves fast.
        // DEPTH FIX ("block duplicates"): also fade the offset to zero when the water
        // column is very shallow. When a block sits on or right next to the water
        // surface waterPath ≈ 0, so the refracted UV would shift onto the block's own
        // screen pixels and create a visible duplicate. Scaling by alSaturate(waterPath
        // / 0.45) suppresses refraction to zero at zero depth and restores it over the
        // first ~0.45 m of water column so the effect only appears where there is
        // actually water to distort through.
        float refrFade  = 1.0 / (1.0 + dist0 * 0.08);
        float refrDepth = alSaturate(waterPath / 0.45);
        float edgeK    = min(min(texcoord.x, 1.0 - texcoord.x),
                             min(texcoord.y, 1.0 - texcoord.y));
        float edgeFade = smoothstep(0.0, 0.06, edgeK);   // 0 at the very edge
        vec2  refrUV = clamp(texcoord + Nv.xy * (AL_WATER_REFRACT * refrFade * edgeFade * refrDepth),
                             vec2(0.002), vec2(0.998));
        vec3  submerged = texture(colortex0, refrUV).rgb;

        // Beer-Lambert extinction VECTOR: red absorbed fastest, then green, so water
        // shifts clear teal (shallow) -> deep navy/blue (deep). WATER_ABSORPTION
        // (GUI) scales how fast it deepens.
        vec3 absorb = exp(-AL_WATER_ABSORB
                          * (waterPath * AL_WATER_ABSORB_SCALE * WATER_ABSORPTION));

#ifdef WATER_CAUSTICS
        vec3  sunDir = alSunDirWorld();
        float dayF   = alSmooth(smoothstep(-0.06, 0.16, sunDir.y));   // == alDayFactor
        vec3  wposB  = alViewToPlayer(P1) + cameraPosition;
        float caus   = alWaterCaustic(wposB, sunDir, frameTimeCounter * AL_CAUSTIC_SPEED);
        float dfade  = exp(-waterPath / AL_CAUSTIC_DEPTH_FADE);       // shallow -> strong
        float gate   = skyLm * dayF * dfade;
        float cmod   = 1.0 + AL_CAUSTIC_STRENGTH * (caus * 2.0 - 1.0) * gate;
        absorb *= max(cmod, 0.0);
#endif

        // Weight by (1 - Fresnel): depth tint fades into the reflection at grazing.
        transmitted = submerged * mix(vec3(1.0), absorb, 1.0 - fres);

#ifdef WATER_FOAM
        // CONTACT (EDGE) FOAM: foam where the water column is shallow — i.e.
        // against shorelines and around any block the water meets. The depth
        // proximity is only the DRIVE; on its own it is a smooth gradient, which
        // is exactly the "uniform bright white band" in the field report.
        contactFoam = (1.0 - smoothstep(0.0, AL_WATER_FOAM_CONTACT, waterPath))
                    * skyLm * AL_WATER_FOAM_CONTACT_STR;
        // The drive is ERODED through the domain-warped ridged noise field, so the
        // band is chewed into chaotic whiskers with holes and torn edges that
        // follow the block boundary rather than tracing it uniformly.
        vec2 foamWP = (alViewToPlayer(P0) + cameraPosition).xz;
        contactFoam = alWaterFoamErode(contactFoam,
                                       alWaterFoamNoise(foamWP, frameTimeCounter));
#endif
    }

    // Reflection over the (absorbed/refracted) water colour.
    vec3 result = mix(transmitted, refl, fres);

#ifdef WATER_FOAM
    // Shoreline/edge foam on top (matte). PHYSICALLY LIT, not a painted white:
    // foam is a bright but ordinary diffuse albedo, so its radiance is the sky
    // ambient it receives plus a Lambert-weighted share of the direct sun/moon —
    // the same radiometric quantities the rest of the frame is exposed against.
    // That is what stops it "glowing" white: at night the ambient collapses and
    // the foam goes moonlit grey on its own, with no magic night constant needed
    // beyond a small floor for readability.
    if (contactFoam > 0.001) {
        vec3  sunDirW  = alSunDirWorld();
        // AL_WATER_FOAM_NIGHT is now a FLOOR on the ambient share (so foam under
        // a covered edge, or at night, stays faintly readable) rather than a
        // separate brightness fudge: the day/night response comes from the sky
        // radiance itself.
        vec3  ambient  = skyAmb * max(0.35 + 0.65 * skyLm, AL_WATER_FOAM_NIGHT);
        vec3  direct   = alDirectColor(sunDirW) * (max(sunDirW.y, 0.0) * skyLm * 0.35);
        vec3  foamCol  = AL_WATER_FOAM_COLOR * (ambient + direct);
        result = mix(result, foamCol, contactFoam);
    }
#endif

    // NaN-law: any non-finite channel -> fall back to the untouched scene.
    bool ok = all(greaterThanEqual(result, vec3(0.0)));
    outColor = vec4(ok ? min(result, vec3(65000.0)) : base, 1.0);
}
