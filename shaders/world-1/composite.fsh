#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/atmosphere.glsl"
#include "/lib/clouds_common.glsl"
#include "/lib/water.glsl"

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
      dithered start, screen-edge + thickness rejection). Hit -> sample the
      post-translucent scene (colortex0); miss/off-screen -> alSkySample of the
      world reflected dir. Blended over the water via Schlick Fresnel (f0=0.02).
      Gated INTERNALLY by SSR so absorption + caustics still run with SSR off.

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

 The pass ALWAYS runs (NOT gated on SSR — that would kill absorption/caustics
 with SSR off, contract §6). Non-water pixels take a one-line early-out.

 SAMPLER BUDGET (recount): 7 of 8 max —
   1 colortex0  (scene, SSR hit colour + base)
   2 colortex2  (water ripple normal .rg + lightmap .ba)
   3 colortex3  (matID mask)
   4 depthtex0  (translucent-inclusive = water surface depth; SSR march target)
   5 depthtex1  (opaque-only depth = scene behind the water)
   6 noisetex   (SSR dither)
   7 colortex6  (sky-view LUT, via lib/atmosphere.glsl alSkySample)
 lib/space.glsl and lib/clouds_common.glsl add only matrices/plain uniforms
 (no samplers). <= 8. NaN-law: every clear=false read (colortex6) is range-
 validated in its accessor; reconstruction is guarded; the result falls back to
 the untouched scene on any non-finite value (fail toward the plain scene).
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
#ifdef REFLECTIVE_BLOCKS
uniform sampler2D colortex1;   // albedo — metal reflections tint by the block's own colour
#endif

// Forward matrices for the view-space raymarch projection. lib/space.glsl owns
// the INVERSE matrices + cameraPosition/previous* (do not redeclare those);
// these two are declared nowhere else, so declaring them here is collision-free.
uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;

uniform int frameCounter;      // Iris: frame index (wraps) for the R2 dither

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;   // -> colortex0 (water-reflected scene)

// View-space linear eye distance in front of the camera (positive).
float alEyeZ(vec3 viewPos) { return -viewPos.z; }

/*
 SSR raymarch in view space against depthtex0. `origin` is the water surface
 view position, `dir` the reflected view direction (unit). Returns true + the
 hit UV when the ray crosses behind a thin surface on-screen; false otherwise.
 Standard scheme: fixed-length steps with a dithered start, detect the crossing
 (rayPos passes behind the sampled surface: rayPos.z < sceneZ), reject when the
 gap exceeds a thickness tolerance (ray slipped behind a foreground object), and
 binary-search between the last in-front and first behind sample to refine.
*/
bool alTraceSSR(vec3 origin, vec3 dir, float dither, out vec2 hitUV) {
    float stepLen = AL_SSR_MAX_DIST / float(AL_SSR_STEPS);
    vec3  rayPos  = origin + dir * stepLen * (0.5 + dither);   // dithered start
    hitUV = vec2(0.0);

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

#ifdef REFLECTIVE_BLOCKS
/*
 Material-dependent reflection for a SOLID reflective block (ice / metal / polished)
 or reflective translucent ice. reflAmt (colortex3.b) is the surface reflectivity,
 metal (colortex3.a) selects the model:
   * DIELECTRIC (ice / polished stone, metal=0): Fresnel-shaped — subtle head-on,
     reflective at grazing; the reflection is neutral (untinted).
   * METAL (metal=1): strong at all angles and TINTED by the block's own albedo
     (iron silver, gold yellow, copper orange) — a proper metallic look.
 Reuses the water SSR raymarch against depthtex0, with a sky-access gate so indoor
 blocks reflect a dark tone instead of the bright sky. NaN-safe: falls back to base.
*/
vec3 alReflectiveBlock(vec3 base, float reflAmt, float metal) {
    float d0 = texture(depthtex0, texcoord).r;
    vec3  P0 = alScreenToView(texcoord, d0);
    float dist0 = length(P0);
    if (!(dist0 >= 0.0) || dist0 > 1.0e7) return base;

    vec3  Nw = alDecodeNormal(texture(colortex2, texcoord).rg);
    vec3  Nv = normalize(mat3(gbufferModelView) * Nw);
    vec3  I  = normalize(P0);
    float cosI = alSaturate(dot(-I, Nv));

    // Schlick Fresnel with a metal/dielectric F0 (metals reflect more head-on).
    float f0   = mix(0.04, 0.75, metal);
    float fres = f0 + (1.0 - f0) * pow(1.0 - cosI, 5.0);

    // Roughness: iron/gold BLOCKS are rough metal, not chrome. Roughness blurs the
    // environment (toward the soft zenith ambient) and weights DOWN the sharp SSR.
    float rough = mix(AL_REFL_ROUGH_DIELECTRIC, AL_REFL_ROUGH_METAL, metal);

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
    vec3  envRefl  = mix(skySharp, ambient, rough);      // rough -> blurred env
    envRefl = mix(ambient * 0.4, envRefl, upCut);        // occluded horizon -> dim ambient
    vec3  refl = mix(vec3(0.02, 0.03, 0.04), envRefl, skyGate);

#ifdef SSR
    // Sharp SSR only meaningfully contributes for SMOOTH surfaces; a mirror-sharp
    // reflection on rough iron reads as chrome, so weight it by (1-rough).
    float ssrW = 1.0 - rough;
    if (ssrW > 0.05) {
        vec2 noiseUV = gl_FragCoord.xy / 256.0;
    #ifdef AL_TAA
        float dither = fract(texture(noisetex, noiseUV).r + float(frameCounter) * 0.61803398875);
    #else
        float dither = texture(noisetex, noiseUV).r;
    #endif
        vec2 hitUV;
        if (alTraceSSR(P0, Rv, dither, hitUV)) {
            vec3 hitCol = texture(colortex0, hitUV).rgb;
            vec2 e = smoothstep(vec2(0.0), vec2(AL_SSR_EDGE_FADE), hitUV)
                   * (1.0 - smoothstep(vec2(1.0 - AL_SSR_EDGE_FADE), vec2(1.0), hitUV));
            float edgeFade = e.x * e.y * ssrW;
            bool okHit = all(greaterThanEqual(hitCol, vec3(0.0)))
                      && all(lessThan(hitCol, vec3(65000.0)));
            refl = mix(refl, okHit ? hitCol : refl, edgeFade);
        }
    }
#endif

    // Metal tints the reflection with its own albedo (F0 colour); dielectric neutral.
    vec3 albedo    = texture(colortex1, texcoord).rgb;
    vec3 reflColor = refl * mix(vec3(1.0), albedo, metal);

    // Strength: dielectric Fresnel-driven (subtle head-on); metal moderate + tinted
    // and capped by roughness so it reads as brushed metal, never a chrome mirror.
    float strength = mix(reflAmt * fres, reflAmt * (0.45 + 0.35 * fres), metal);
    strength = alSaturate(strength * REFLECTIVE_STRENGTH);

    vec3 result = mix(base, reflColor, strength);
    bool ok = all(greaterThanEqual(result, vec3(0.0)));
    return ok ? min(result, vec3(65000.0)) : base;
}
#endif

void main() {
    vec3 base = texture(colortex0, texcoord).rgb;

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
        outColor = vec4(alReflectiveBlock(base, m3.b, m3.a), 1.0);
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
    float cosI = alSaturate(dot(-I, Nv));

    // Schlick Fresnel, capped a touch below 1 so water never chromes out.
    float fres = AL_WATER_F0 + (1.0 - AL_WATER_F0) * pow(1.0 - cosI, 5.0);
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
    vec3  skyR  = mix(AL_WATER_REFL_OCCLUDED, alSkySample(Rw), upCut);
    vec3 refl = mix(vec3(0.015, 0.020, 0.035), skyR, skyGate);  // fallback + cave gate

#ifdef SSR
    // R2 low-discrepancy dither on the noisetex value. Advanced by frameCounter
    // ONLY under TAA (which temporally resolves it); under FXAA/Off it is frozen so
    // the water reflection doesn't crawl as grain (field report).
    vec2 noiseUV = gl_FragCoord.xy / 256.0;        // noisetex is 256x256
    float dither = texture(noisetex, noiseUV).r;
#ifdef AL_TAA
    dither = fract(dither + float(frameCounter) * 0.61803398875);
#endif

    vec2 hitUV;
    if (alTraceSSR(P0, Rv, dither, hitUV)) {
        vec3 hitCol = texture(colortex0, hitUV).rgb;
        // Fade the reflection to the sky sample near the screen edges (the march
        // has no data past them) so reflections don't clip hard.
        vec2 e = smoothstep(vec2(0.0), vec2(AL_SSR_EDGE_FADE), hitUV)
               * (1.0 - smoothstep(vec2(1.0 - AL_SSR_EDGE_FADE), vec2(1.0), hitUV));
        float edgeFade = e.x * e.y;
        bool okHit = all(greaterThanEqual(hitCol, vec3(0.0)))
                  && all(lessThan(hitCol, vec3(65000.0)));
        refl = mix(refl, okHit ? hitCol : refl, edgeFade);
    }
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
        float refrFade = 1.0 / (1.0 + dist0 * 0.08);
        float edgeK    = min(min(texcoord.x, 1.0 - texcoord.x),
                             min(texcoord.y, 1.0 - texcoord.y));
        float edgeFade = smoothstep(0.0, 0.06, edgeK);   // 0 at the very edge
        vec2  refrUV = clamp(texcoord + Nv.xy * (AL_WATER_REFRACT * refrFade * edgeFade),
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
        // CONTACT FOAM: soft shoreline foam where the water column is shallow (the
        // surface is close to the terrain behind it). Softened (STR) + gated to open
        // sky so it is not a jarring white band.
        contactFoam = (1.0 - smoothstep(0.0, AL_WATER_FOAM_CONTACT, waterPath))
                    * skyLm * AL_WATER_FOAM_CONTACT_STR;
        // WHISPY FRACTAL breakup: modulate by the same domain-warped foam noise so the
        // shoreline foam is chaotic whiskers, not a uniform white band.
        vec2 foamWP = (alViewToPlayer(P0) + cameraPosition).xz;
        contactFoam *= 0.15 + 0.85 * alWaterFoamNoise(foamWP, frameTimeCounter);
#endif
    }

    // Reflection over the (absorbed/refracted) water colour.
    vec3 result = mix(transmitted, refl, fres);

#ifdef WATER_FOAM
    // Shoreline foam on top (matte). Darkened at night (day factor) + by sky access
    // so it reads moonlit-grey after dark instead of glowing white (field report).
    if (contactFoam > 0.001) {
        float foamDayF = alSmooth(smoothstep(-0.06, 0.16, alSunDirWorld().y));
        vec3  foamCol  = AL_WATER_FOAM_COLOR * (0.25 + 0.55 * skyLm)
                       * mix(AL_WATER_FOAM_NIGHT, 1.0, foamDayF);
        result = mix(result, foamCol, contactFoam);
    }
#endif

    // NaN-law: any non-finite channel -> fall back to the untouched scene.
    bool ok = all(greaterThanEqual(result, vec3(0.0)));
    outColor = vec4(ok ? min(result, vec3(65000.0)) : base, 1.0);
}
