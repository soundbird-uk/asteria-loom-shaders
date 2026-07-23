#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/tonemap.glsl"
#include "/lib/grade.glsl"

/*
 final (fragment) — output to the screen.

 Pipeline (Phase 4): colortex0 (HDR scene, post bloom-combine)
   -> auto-exposure multiply  (adapted value from colortex5.a texel (0,0),
      metered+smoothed by composite5) x EXPOSURE user bias
   -> AgX tonemap             (lib/tonemap.glsl — soft-filmic, calibrated to
      carry the field-approved noon/night levels within ~10%; replaces the old
      placeholder ACES fit)
   -> biome + weather grade    (lib/grade.glsl — subtle biome-adaptive nudges
      and rain/thunder/wetness/lightning storytelling, <=10% shifts)
   -> linear -> sRGB
 with an optional DEBUG_VIEW that bypasses ALL grading to inspect raw G-buffer
 channels. final writes to the default framebuffer, so it carries NO
 RENDERTARGETS directive (it is the documented exception, alongside shadow).

 Sampler count: 7 (colortex0, colortex1, colortex2, colortex3, colortex4,
 colortex5, depthtex0). colortex4 is read only by DEBUG_VIEW 6 (AO); colortex5
 is read only for the exposure scalar at texel (0,0).

 ==========================================================================
 CANONICAL BUFFER-FORMAT DECLARATIONS
 --------------------------------------------------------------------------
 Iris reads the colortexNFormat / shadowcolorNFormat declarations as TEXT,
 and they MUST stay inside a comment: the format tokens (RGBA16F, RGBA8,
 RGBA16, ...) are NOT valid GLSL identifiers, so a real driver (confirmed on
 macOS GL 4.1) rejects them as "undeclared identifier" if they appear as live
 code. Commenting them is the documented Iris idiom — the loader still parses
 them, the GLSL compiler never sees them. Per the Phase-1 contract these live
 HERE and nowhere else; this comment block is the single source of truth.

   colortex0    RGBA16F  HDR scene colour (sky + lit scene + translucents)
   colortex1    RGBA8    albedo.rgb, a = vanilla AO / spare
   colortex2    RGBA16   octahedral normal .rg, lightmap (block,sky) .ba
   colortex3    RGBA8    matID/255 .r, flags/255 .g, ba spare
   colortex4    RG16F    GTAO: r = AO (1 = unoccluded), g = confidence. Cleared.
   colortex5    RGBA16F  AO history: r = AO, g = confidence, b = linear depth,
                         a = ADAPTED EXPOSURE (at texel (0,0) only — written by
                         composite5, read here; elsewhere .a is AO-history spare
                         and preserved byte-exact). `clear.colortex5 = false`
                         (persists across frames for temporal accumulation — set
                         in shaders.properties).
   colortex6    RGBA16F  Sky-view LUT: top-left 256x128 tile = analytic
                         atmosphere radiance (azimuth x horizon-biased
                         elevation, mapping documented in lib/atmosphere_common
                         .glsl). Rest of the buffer unused. Baked once per frame
                         by the prepare pass. `clear.colortex6 = false` (set in
                         shaders.properties) -> reads are NaN-proof range-
                         validated with an analytic fallback.
   colortex7    RGBA16F  Cloud history (CLOUDS agent): rgb = in-scattered
                         radiance, a = transmittance. `clear.colortex7 = false`.
   colortex8    RGBA16F  TAA history (TAA agent): rgb = resolved scene colour,
                         a = blend confidence. `clear.colortex8 = false`
                         (persists across frames for temporal reprojection) ->
                         reads are NaN-proof range-validated in composite3.fsh.
   colortex9    RGBA16F  Bloom tile atlas (BLOOM agent): mip chain packed as
                         tiles (layout in lib/bloom.glsl). Cleared. Format
                         declared here on the BLOOM agent's behalf per contract
                         §2 (TAA agent owns the colortex8/9 format consts).
   shadowcolor0 RGBA8    reserved for Phase 2 (coloured/translucent shadows);
                         Phase 1's shadow pass is depth-only, so nothing is
                         allocated yet — this only reserves the format.
 ==========================================================================
*/

/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA8;
const int colortex2Format = RGBA16;
const int colortex3Format = RGBA8;
const int colortex4Format = RG16F;
const int colortex5Format = RGBA16F;
const int colortex6Format = RGBA16F;
const int colortex7Format = RGBA16F;
const int colortex8Format = RGBA16F;
const int colortex9Format = RGBA16F;
const int shadowcolor0Format = RGBA8;
*/

// Shadow-map sizing (shadowMapResolution / shadowDistance) is declared in
// settings.glsl as literal-valued const GUI options — Iris' ConstDirectiveParser
// reads their literal text with no macro expansion, so the option must BE the
// constant. They are NOT redeclared here (settings.glsl is already included
// above) to avoid a duplicate directive.

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;   // GTAO term (DEBUG_VIEW 6)
uniform sampler2D colortex5;   // .a(0,0) = adapted exposure (from composite5)
uniform sampler2D depthtex0;

uniform float near;
uniform float far;

// Weather storytelling (verified Iris uniforms — see composite2.fsh header for
// provenance of rainStrength/wetness/thunderStrength/biome_category/temperature
// /rainfall). Drive the biome/weather grade in lib/grade.glsl.
uniform float rainStrength;
uniform float wetness;
uniform float thunderStrength;
uniform int   biome_category;
uniform float temperature;
uniform float rainfall;

// Lightning bolt position (Iris). .w > 0.5 when a bolt currently exists in the
// world — used for a brief cool-white full-frame flash lift (deferred1 stays
// untouched; the flash is approximated here in the grade, per contract §6).
uniform vec4 lightningBoltPosition;

in vec2 texcoord;

layout(location = 0) out vec4 fragColor;

// Linearise hardware depth to [0,1] over the view frustum (debug view 4).
float alLinearizeDepth(float d) {
    float z = d * 2.0 - 1.0;
    float lin = (2.0 * near * far) / (far + near - z * (far - near));
    return alSaturate(lin / far);
}

// The full display pipeline for ONE pixel: exposure -> AgX -> grade -> sRGB.
// Factored out so FXAA can evaluate it at neighbour UVs (FXAA must run on the
// final DISPLAY image, not HDR — that is why the old HDR FXAA "did nothing":
// Reinhard-compressed HDR edge deltas fell under the threshold).
vec3 alFinalColor(vec2 uv) {
    vec3 hdr = texture(colortex0, uv).rgb;
    float adaptedExp = texelFetch(colortex5, ivec2(0, 0), 0).a;
    adaptedExp = (adaptedExp >= 0.2 && adaptedExp <= 5.0) ? adaptedExp : 1.0;
    hdr *= adaptedExp * EXPOSURE;
    hdr = max(hdr, vec3(0.0));
    vec3 mapped = alTonemapAgX(hdr);
    mapped = alGradeBiome(mapped, biome_category, temperature, rainfall);
    float flash = alSaturate((lightningBoltPosition.w - 0.5) * 2.0);
    mapped = alGradeWeather(mapped, rainStrength, thunderStrength, wetness, flash);
    return alLinearToSrgb(mapped);
}

#ifdef AL_FXAA_ON
// FXAA (Timothy Lottes console version, reimplemented) on the DISPLAY image.
float alFxaaLuma(vec3 c) { return sqrt(dot(c, vec3(0.299, 0.587, 0.114))); }
vec3 alFXAA(vec2 uv, vec2 rcp) {
    vec3  cM  = alFinalColor(uv);
    float lM  = alFxaaLuma(cM);
    float lNW = alFxaaLuma(alFinalColor(uv + vec2(-1.0, -1.0) * rcp));
    float lNE = alFxaaLuma(alFinalColor(uv + vec2( 1.0, -1.0) * rcp));
    float lSW = alFxaaLuma(alFinalColor(uv + vec2(-1.0,  1.0) * rcp));
    float lSE = alFxaaLuma(alFinalColor(uv + vec2( 1.0,  1.0) * rcp));

    float lMin = min(lM, min(min(lNW, lNE), min(lSW, lSE)));
    float lMax = max(lM, max(max(lNW, lNE), max(lSW, lSE)));
    if (lMax - lMin < max(AL_FXAA_EDGE_MIN, lMax * AL_FXAA_EDGE_MUL)) return cM;

    vec2 dir = vec2(-((lNW + lNE) - (lSW + lSE)),
                     ((lNW + lSW) - (lNE + lSE)));
    float dirReduce = max((lNW + lNE + lSW + lSE) * 0.25 * AL_FXAA_REDUCE_MUL,
                          AL_FXAA_REDUCE_MIN);
    float rcpMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = clamp(dir * rcpMin, vec2(-AL_FXAA_SPAN), vec2(AL_FXAA_SPAN)) * rcp;

    vec3 rgbA = 0.5 * (alFinalColor(uv + dir * (1.0 / 3.0 - 0.5))
                     + alFinalColor(uv + dir * (2.0 / 3.0 - 0.5)));
    vec3 rgbB = rgbA * 0.5 + 0.25 * (alFinalColor(uv + dir * -0.5)
                                   + alFinalColor(uv + dir *  0.5));
    float lB = alFxaaLuma(rgbB);
    return (lB < lMin || lB > lMax) ? rgbA : rgbB;
}
#endif

void main() {
    // ---- Debug views (bypass grading) -----------------------------------
#if DEBUG_VIEW == 1
    // Albedo (as stored, sRGB).
    fragColor = vec4(texture(colortex1, texcoord).rgb, 1.0);
    return;
#elif DEBUG_VIEW == 2
    // World normal, remapped to [0,1] for display.
    vec3 n = alDecodeNormal(texture(colortex2, texcoord).rg);
    fragColor = vec4(n * 0.5 + 0.5, 1.0);
    return;
#elif DEBUG_VIEW == 3
    // Lightmap: block in red, sky in green.
    vec2 lm = texture(colortex2, texcoord).ba;
    fragColor = vec4(lm.x, lm.y, 0.0, 1.0);
    return;
#elif DEBUG_VIEW == 4
    // Linear depth as greyscale.
    float ld = alLinearizeDepth(texture(depthtex0, texcoord).r);
    fragColor = vec4(vec3(ld), 1.0);
    return;
#elif DEBUG_VIEW == 5
    // Material ID scaled into a visible grey ramp.
    int id = alDecodeMatID(texture(colortex3, texcoord).r);
    fragColor = vec4(vec3(float(id) / 8.0), 1.0);
    return;
#elif DEBUG_VIEW == 6
    // Ambient occlusion term as greyscale (white = unoccluded). With AO off the
    // pass doesn't run and colortex4 is cleared to 0 (shows black).
    float ao = texture(colortex4, texcoord).r;
    fragColor = vec4(vec3(ao), 1.0);
    return;
#elif DEBUG_VIEW == 7 || DEBUG_VIEW == 8 || DEBUG_VIEW == 9 || DEBUG_VIEW == 10 || DEBUG_VIEW == 11
    // Pipeline probes A/B (7/8) and the horizon-diagnosis views (9/10/11, written
    // by composite2): show colortex0 exactly as the upstream pass wrote it, with
    // NO exposure/tonemap/grade so the raw diagnostic values read true.
    fragColor = vec4(texture(colortex0, texcoord).rgb, 1.0);
    return;
#else
    // ---- Normal path: exposure -> AgX -> grade -> sRGB (+ FXAA) ----------
#ifdef AL_FXAA_ON
    vec2 texel = 1.0 / vec2(textureSize(colortex0, 0));
    vec3 srgb  = alFXAA(texcoord, texel);
#else
    vec3 srgb  = alFinalColor(texcoord);
#endif

    // Final NaN guard — a non-finite result falls back to mid-grey rather than
    // flashing a black/NaN frame to the screen.
    bool ok = (srgb.r >= 0.0) && (srgb.g >= 0.0) && (srgb.b >= 0.0);
    fragColor = vec4(ok ? srgb : vec3(0.5), 1.0);
    return;
#endif
}
