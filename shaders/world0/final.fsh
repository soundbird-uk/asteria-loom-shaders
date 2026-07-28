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
      metered+smoothed by composite14) x EXPOSURE user bias
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
                         composite14, read here; elsewhere .a is AO-history spare
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
   colortex10   RGBA16F  SSR temporal history (5.3.0): rgb = accumulated
                         reflection radiance, a = the reflective surface's eye
                         depth when it was written (the reprojection test).
                         `clear.colortex10 = false`; composite.fsh reads it
                         ('main') and writes it ('alt') in the same pass, which
                         Iris allows for composite-style programs.
   colortex11   RGBA16F  Shadow-visibility temporal history (5.3.0): r = resolved
                         visibility, g = confidence, b = eye depth.
                         `clear.colortex11 = false`; written by deferred1.
   colortex12   R8       SSR temporal CONFIDENCE (5.3.0): r = the history ceiling
                         the pixel has earned, raised one AL_SSR_T_CONF_STEP per
                         consecutively accepted frame. R8 is deliberate: it is a
                         [0,1] scalar the hardware clamps, so this clear=false
                         buffer can never hold a NaN. Read+written by composite
                         alongside colortex10.
   colortex13   R11F_G11F_B10F
                         COLOURED BLOCK LIGHT (5.4.0): rgb = the screen-space
                         gather of nearby emitters' colour (emissive albedo x
                         light level x distance weight), written by deferred2 and
                         consumed by deferred1 via lib/lighting.glsl as a HUE
                         only. HALF RESOLUTION (`size.buffer.colortex13 = 0.5 0.5`
                         in shaders.properties). The packed 11/11/10 float format
                         is chosen deliberately: this is a positive-only, purely
                         chromatic signal at half res, so 32 bits per texel is
                         ample and it halves the bandwidth of an RGBA16F. It has
                         NO alpha, which is why the confidence term is derived
                         from the gather's peak channel rather than stored.
                         `const bool colortex13Clear = false;` — deferred1 runs
                         BEFORE deferred2, so it reads the PREVIOUS frame's
                         gather; a cleared buffer would hand it black every frame
                         and the feature would silently do nothing.
   colortex14   RGBA16F  Coloured block-light HISTORY (5.4.0): rgb = accumulated
                         gather, a = the eye depth when it was written (the
                         reprojection test). RGBA16F rather than 11/11/10 exactly
                         because it needs that alpha. Same half-res scaling as
                         colortex13 (an MRT pass requires all its targets to
                         share a size). `const bool colortex14Clear = false;`
                         -> reads are NaN-proof range-validated in deferred2.fsh.
   shadowcolor0 RGBA8    VOXEL EMITTER / OCCUPANCY MAP (5.5.0): written by the
                         one-texel splats shadow.gsh emits into the reserved
                         atlas strip of the shadow buffer. rgb = the block's own
                         albedo as sampled (sRGB), a = (1 + lightLevel)/32, a
                         band chosen so that BOTH plausible shadow-buffer clear
                         values (0.0 and opaque white) read as "empty" — see
                         lib/voxel.glsl. CLEARED every frame, deliberately: a
                         broken torch must stop existing.
   shadowcolor1 R11F_G11F_B10F
                         THE VOXEL LIGHT FIELD (5.5.0): rgb = flood-filled
                         coloured block light, one texel per voxel of a
                         128x64x128 grid centred on the camera, flattened as
                         16x4 tiles of 128x128 = 2048x512 texels in the top
                         strip of the shadow buffer. Written by shadowcomp1,
                         read by next frame's shadowcomp and by deferred1 (as a
                         HUE only — the intensity stays with vanilla's lm.x).
                         `const bool shadowcolor1Clear = false;` — it is the
                         accumulator the whole flood fill lives in; clearing it
                         would restart the diffusion from black every frame and
                         the light would never propagate anywhere at all.
                         No alpha: occupancy is re-read fresh from shadowcolor0
                         each pass rather than stored one frame stale.
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
const int colortex10Format = RGBA16F;
const int colortex11Format = RGBA16F;
const int colortex12Format = R8;
const int colortex13Format = R11F_G11F_B10F;
const int colortex14Format = RGBA16F;
const int shadowcolor0Format = RGBA8;
const int shadowcolor1Format = R11F_G11F_B10F;
*/

/* ==========================================================================
   BUFFER PERSISTENCE  (clear=false) — CANONICAL DECLARATION SITE
   --------------------------------------------------------------------------
   These MUST be live GLSL `const bool`s, NOT `clear.colortexN = false` keys in
   shaders.properties. Iris parses buffer clearing ONLY as a shader const
   directive (`const bool <buffer>Clear = <bool>;`) — its ShaderProperties
   parser has no `clear.` key at all, so the properties form is silently
   IGNORED. The pack shipped the properties form for seven buffers, so every
   one of them was being cleared to vec4(0) every frame and NO temporal
   accumulation in the pack actually accumulated: the TAA resolve had no
   history to reproject, GTAO/SSR/shadow histories reset every frame, the
   cloud history never built up, and the auto-exposure integrator re-read 0
   and restarted instead of converging over AL_EXPOSURE_TAU. Every read of
   these buffers is already NaN-proof and range-validated (the standing law for
   clear=false buffers), which is exactly why the breakage was SILENT — the
   validated reads fell back to "current frame only" instead of erroring.

   Unlike the *Format directives above these are valid GLSL, so they are live
   code rather than a parsed comment block. Declared once per dimension here,
   alongside the formats, so persistence and format never drift apart.
   ========================================================================== */
const bool colortex5Clear  = false;   // AO history (rgb) + exposure slot in .a
const bool colortex6Clear  = false;   // sky-view LUT tile (rebuilt by prepare)
const bool colortex7Clear  = false;   // cloud history
const bool colortex8Clear  = false;   // TAA history
const bool colortex10Clear = false;   // SSR history
const bool colortex11Clear = false;   // shadow-visibility history
const bool colortex12Clear = false;   // SSR temporal confidence
const bool colortex13Clear = false;   // coloured block light (read a frame late)
const bool colortex14Clear = false;   // coloured block-light history
// VOXEL LIGHT (5.5.0). shadowcolor1 is the flood fill's accumulator: each frame's
// two propagation steps build on the previous frame's field, so persistence is
// not an optimisation here, it is the mechanism. A cleared shadowcolor1 would
// restart every frame from black and light would never travel more than two
// voxels from a source — the feature would appear to do almost nothing while
// costing full price. The ping-pong intermediate is shadowcolor1's own alt
// buffer (Iris double-buffers each shadowcolor), not a third target; it is
// declared non-clearing purely to skip a pointless full-buffer clear, and every
// read of both is NaN-proof range-validated in lib/voxel.glsl.
// shadowcolor0 (the emitter/occupancy map) is deliberately NOT listed: it MUST
// be re-cleared every frame or a torch that has been broken would haunt the grid.
const bool shadowcolor1Clear = false;   // voxel light field (the accumulator)

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
uniform sampler2D colortex5;   // .a(0,0) = adapted exposure (from composite14)
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
