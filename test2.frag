#version 410 core
#define MC_OS_MAC 1
#define IS_IRIS 1
#ifndef AL_SETTINGS
#define AL_SETTINGS

/*
============================================================================
 ASTERIA LOOM — settings.glsl
----------------------------------------------------------------------------
 Single source of truth for every user-tunable option. Included by EVERY
 program (right after `#version 330 compatibility`). Two kinds of content
 live here:

   1. GUI OPTIONS — `#define NAME value // [allowed values]` (numeric/enum)
      and `#define NAME` / `//#define NAME` (boolean toggles). Iris parses
      these to build the in-game settings screens. Every GUI option here
      MUST appear in exactly one `screen.*` in shaders.properties and have
      `option.*` / `value.*` entries in lang/en_us.lang. This three-way
      consistency is contractually enforced.

   2. COLOUR IDENTITY CONSTANTS — plain `const vec3` values that define the
      pack's signature warm-sun / cool-sky look. These are file-tweakable
      (edit and hot-reload) but are NOT GUI options, so they need no screen
      or lang entries. They are the heart of the visual identity: change
      them and the whole mood shifts.

 Naming: user-facing GUI options are plain UPPER_CASE (e.g. SHADOWS).
 Everything pack-internal is prefixed AL_ (e.g. AL_SUN_TINT).

 Defaults below are the MEDIUM-profile values. shaders.properties profiles
 override a small subset (SHADOWS, shadowMapResolution, SHADOW_PCSS, ...).
============================================================================
*/


/* =========================================================================
   PROFILES NOTE
   -------------------------------------------------------------------------
   The five presets (POTATO/LOW/MEDIUM/HIGH/ULTRA) are defined in
   shaders.properties via `profile.*`. They only flip options declared in
   THIS file. Differentiators:
     - SHADOWS          (POTATO off; everyone else on)
     - shadowMapResolution(1024 / 1536 / 2048 / 2048 / 3072)
     - SHADOW_PCSS      (LOW off -> plain Vogel; MEDIUM+ on -> contact-hardening)
     - SHADOW_SAMPLES   (8 / 12 / 16 / 24)
     - CONTACT_SHADOWS  (HIGH/ULTRA on)
     - AO               (POTATO/LOW off; MEDIUM+ on)
     - AO_QUALITY       (MEDIUM 2, HIGH/ULTRA 3)
   Later phases add TAA / clouds / SSR quality knobs here.
   ========================================================================= */


/* =========================================================================
   LIGHTING
   -------------------------------------------------------------------------
   Global intensity trims for the Phase-1 lighting model (lib/lighting.glsl).
   These scale, but never override, the colour identity constants further
   down. 1.0 == the intended baseline.
   ========================================================================= */

// Direct sun / moon light strength.
#define SUN_INTENSITY 1.0 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Cool hemisphere sky-fill (ambient) strength. This is the cool half of the
// pack's signature warm/cool contrast — turn it up for softer shadows.
#define AMBIENT_INTENSITY 1.0 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Warm block-light (torches/lanterns) strength.
#define BLOCKLIGHT_INTENSITY 1.0 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Colour-temperature ramp on block light: candle-amber near a source fading to
// deep ember-orange at the dim edge of its reach. This is the Mac-path
// approximation of coloured light (true per-source colour is a later phase).
// Off = a single flat warm torch tint.
#define BLOCKLIGHT_TINT // [BLOCKLIGHT_TINT]

// --- Blocklight shaping (internal, not GUI) -------------------------------
// These scalars tune the falloff so a campfire warms a ~6-block radius at night
// while its peak stays at ~0.1.1's adjacent-torch brightness (the 0.2.0 field
// test found 0.2.0 too bright at night — the fix is to LIFT the mid/far reach
// without raising the peak). Edit + hot-reload.
//   BASE     overall lift; tuned so bl==1 luminance matches the old 0.1.1 peak
//   FALLOFF  perceptual power on the lightmap; lowered from 2.2 so the mid range
//            (grass a few blocks from the fire) reads instead of dying out
//   TAIL     blend toward a gentler quadratic so distant grass keeps a glow
#define AL_BLOCKLIGHT_BASE    0.92
#define AL_BLOCKLIGHT_FALLOFF 1.70
#define AL_BLOCKLIGHT_TAIL    0.35

// Night ambient floor — how readable open terrain stays after dark. Keeps a
// cool-blue minimum so nothing goes pitch black under the night sky.
#define NIGHT_BRIGHTNESS 1.0 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

// Fake indirect-bounce floor. A tiny lift so unlit coloured faces are never
// pure black (real GI arrives in a later phase).
#define BOUNCE_INTENSITY 1.0 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00]


/* =========================================================================
   SHADOWS  (provisional — PCSS + distortion land in Phase 2)
   ========================================================================= */

// Master shadow toggle. Also gates the shadow PASS itself via
// `program.shadow.enabled = SHADOWS` in shaders.properties, so POTATO
// genuinely skips rendering the shadow map.
#define SHADOWS // [SHADOWS]

// Shadow map resolution (square). Higher = crisper, more VRAM/fill.
// NOTE: this is a `const int` GUI option, NOT a #define. Iris' shadow-map
// sizing reads the buffer-directive constant `shadowMapResolution` by its
// literal value (its ConstDirectiveParser scans raw text and does NOT expand
// macros), so the option must BE that constant. Declared here (settings.glsl
// is included everywhere) it is simultaneously the GUI slider, the value Iris
// sizes the shadow map from, and a compile-time constant for lib/shadow.glsl.
const int shadowMapResolution = 2048; // [1024 1536 2048 3072 4096]

// Max distance (blocks) shadows are cast. Larger = more coverage, softer.
// Same const-option rationale as shadowMapResolution above (Iris reads the
// literal `shadowDistance` directive value directly).
const float shadowDistance = 128.0; // [64.0 96.0 128.0 192.0 256.0]

// Percentage-Closer Soft Shadows: penumbrae widen with distance from the
// occluder (contact-hardening) instead of a fixed blur. Needs a raw shadow
// depth read for the blocker search, so it is active only on the hardware-
// sampler path (SEPARATE_HARDWARE_SAMPLERS); the fallback uses a fixed-radius
// soft filter with the same tap budget. Off (LOW) = plain fixed-radius Vogel.
#define SHADOW_PCSS // [SHADOW_PCSS]

// Shadow filter tap count (Vogel disc). More = smoother penumbrae, more cost.
#define SHADOW_SAMPLES 12 // [8 12 16 24]

// Screen-space contact shadows: a short view-space raymarch that catches the
// fine contact detail the shadow map is too coarse for (block bases, tight
// gaps). Multiplies the shadow term. Off by default; on for HIGH/ULTRA.
//#define CONTACT_SHADOWS // [CONTACT_SHADOWS]

// --- Shadow shaping (internal, not GUI) -----------------------------------
// Distortion warp strength k in (0,1): factor = (1-k) + k*length(ndc.xy).
// Higher = more texels concentrated near the camera. 0.85 gives ~6.7x linear
// centre density (~3x useful average). See lib/shadow.glsl for the full maths
// and the guarantee that the map corners never leave [-1,1].
#define AL_SHADOW_DISTORT 0.85

// Sun angular radius (radians) driving the PCSS penumbra growth. The real sun
// is ~0.0047; enlarged here for the brief's deliberately soft, dreamy edges.
#define AL_SUN_ANGULAR_RADIUS 0.025
// Extra artistic widening multiplied onto the physical penumbra.
#define AL_SHADOW_SOFTNESS 2.5
// Penumbra clamp (in shadow texels) — min keeps contact crisp, max bounds blur.
#define AL_SHADOW_MIN_PEN_TEXELS 1.0
#define AL_SHADOW_MAX_PEN_TEXELS 48.0
// Fixed soft radius (world metres) for the non-PCSS / fallback path.
#define AL_SHADOW_FIXED_PEN_WORLD 0.30
// Blocker-search radius (world metres) for the PCSS occluder estimate.
#define AL_SHADOW_SEARCH_WORLD 2.0
// Depth bias (base + slope*(1-NdotL)), later scaled by the LOCAL warped texel.
#define AL_SHADOW_BIAS 0.00008
#define AL_SHADOW_SLOPE_BIAS 0.00040
// Normal offset growth (base + slope*(1-NdotL)) in LOCAL warped texels.
#define AL_SHADOW_NOFFSET_BASE 0.85
#define AL_SHADOW_NOFFSET_SLOPE 2.50

// --- Contact-shadow shaping (internal, not GUI) ---------------------------
#define AL_CONTACT_STEPS 14        // raymarch steps (12-16)
#define AL_CONTACT_LENGTH 0.75     // total march length, world metres
#define AL_CONTACT_THICKNESS 0.50  // max occluder thickness (view-space metres)
#define AL_CONTACT_BIAS 0.02       // ignore hits within this of the start


/* =========================================================================
   AMBIENT OCCLUSION  (GTAO — horizon-based, temporally accumulated)
   -------------------------------------------------------------------------
   Runs in the `deferred` pass (before lighting) and writes colortex4; the
   lighting pass multiplies it onto the AMBIENT / bounce / blocklight terms
   only (never the direct sun/moon). Gated as a whole pass via
   `program.deferred.enabled = AO` so POTATO/LOW skip it entirely.
   ========================================================================= */

// Master AO toggle. Also gates the AO pass itself (program.deferred.enabled).
// deferred1 reads colortex4 only behind `#ifdef AO` (cleared buffer = black).
#define AO // [AO]

// AO quality: slices x horizon steps per pixel. 1 = 2x3, 2 = 2x4, 3 = 3x4.
// More slices/steps = smoother, less noisy AO (temporal accumulation cleans up
// the rest) at higher cost.
#define AO_QUALITY 2 // [1 2 3]

// AO strength. Applied as pow(ao, AO_STRENGTH): >1 deepens crevices, <1 softens.
#define AO_STRENGTH 1.0 // [0.5 0.75 1.0 1.25 1.5]

// --- AO shaping (internal, not GUI) ---------------------------------------
// Effect radius in world metres — how far a crease reaches for occluders.
#define AL_AO_RADIUS 1.2
// Clamp on the projected search radius (UV) so near-camera pixels don't march
// the whole screen (and blow the cache) when AL_AO_RADIUS/depth explodes.
#define AL_AO_MAX_RADIUS_UV 0.15
// Temporal blend ceiling: max fraction of the accumulated history kept per
// frame (confidence-scaled up to this). 0.9 = strong smoothing, still reactive.
#define AL_AO_MAX_BLEND 0.9
// Confidence ramp: added each accepted frame, capped at MAX. A freshly
// disoccluded pixel starts at STEP and converges over ~1/STEP frames.
#define AL_AO_CONF_STEP 0.1
#define AL_AO_CONF_MAX  0.9
// History rejection: relative linear-depth mismatch above this discards the
// reprojected sample (disocclusion / a different surface). ~5%.
#define AL_AO_DEPTH_REJECT 0.05


/* =========================================================================
   CLOUDS  (volumetric 2-layer raymarch — cumulus 3D + cirrus 2D)
   -------------------------------------------------------------------------
   Rendered in `composite` (raymarch + temporal accumulation into colortex7)
   and composited over the scene. The cheap sampler-free cloud SHADOW that
   feeds the lighting pass lives in lib/clouds_common.glsl. Vanilla clouds are
   kept as a low-cost fallback (POTATO/LOW), gated the same way as before
   (gbuffers_clouds self-discards when VANILLA_CLOUDS is off).
   ========================================================================= */

// Master volumetric-cloud toggle. When on, the composite pass raymarches the
// two cloud layers; when off, composite is a pure passthrough and (if
// VANILLA_CLOUDS is on) Minecraft's forward clouds draw instead.
#define VOLUMETRIC_CLOUDS // [VOLUMETRIC_CLOUDS]

// Cloud raymarch quality. 1 = 12 primary steps, 2 = 20, 3 = 32 (light steps
// and multiple-scattering octaves scale with it too — see lib/clouds.glsl).
// Temporal accumulation + dithering keep even tier 1 grain-free.
#define VC_QUALITY 2 // [1 2 3]

// Base cloud coverage (fraction of sky filled in clear weather). Rain pushes
// this higher automatically (storm build-up). Lower = sparse fair-weather
// cumulus; higher = a brooding overcast.
#define VC_COVERAGE 0.45 // [0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70]

// Draw vanilla clouds (forward-lit) as a cheap fallback. Default OFF now that
// volumetric clouds exist; POTATO/LOW turn volumetric off and this back on.
// Also gates `program.gbuffers_clouds.enabled` (self-discards otherwise).
//#define VANILLA_CLOUDS // [VANILLA_CLOUDS]

// --- Cloud layer geometry (internal, not GUI — world Y in blocks) ----------
// Cumulus slab [BOT,TOP] gives the fluffy 3D layer; cirrus is a thin high sheet.
#define AL_CLOUD_CUMULUS_BOT 300.0
#define AL_CLOUD_CUMULUS_TOP 460.0
#define AL_CLOUD_CIRRUS_ALT  700.0
#define AL_CLOUD_MAX_DIST    30000.0   // far cap on the cloud march (blocks)
// Cap the marched span so grazing horizon rays keep a sane step size (a
// near-horizontal ray otherwise crosses the slab over many km, giving coarse,
// aliased steps -> a hard-looking horizon). Beyond this the cloud simply thins
// out into the distance (aerial fog then carries the horizon). Keeps the primary
// step length bounded to ~AL_CLOUD_MAX_SPAN / primary-steps.
#define AL_CLOUD_MAX_SPAN    5000.0

// --- Coverage field (2D FBM value noise; shared by render + shadow) ---------
#define AL_CLOUD_COVERAGE_SCALE   0.00028 // world XZ -> noise domain
#define AL_CLOUD_COVERAGE_OCTAVES 4       // FBM octaves for the coverage map
#define AL_CLOUD_WIND_SPEED       0.35    // coverage drift (noise units / sec)
#define AL_CLOUD_STORM_BOOST      0.22    // extra coverage added at full rain

// --- Cumulus 3D shaping -----------------------------------------------------
#define AL_CLOUD_DETAIL_SCALE   0.006  // 3D erosion-noise frequency
#define AL_CLOUD_DETAIL_OCTAVES 3      // 3D FBM octaves (billow erosion)
#define AL_CLOUD_EDGE           0.30   // coverage->density remap softness
#define AL_CLOUD_BOTTOM_ROUND   0.18   // flat-ish base rise (first 18% of slab)
#define AL_CLOUD_TOP_ROUND      0.55   // billowy top erodes over the upper 45%
#define AL_CLOUD_EROSION        0.55   // how hard detail carves cloud edges
#define AL_CLOUD_DENSITY        1.40   // overall optical density multiplier
#define AL_CLOUD_EXTINCTION     0.045  // extinction per block per unit density

// --- Sun light march + scattering ------------------------------------------
#define AL_CLOUD_LIGHT_STEP   9.0   // base step toward the sun (blocks)
#define AL_CLOUD_LIGHT_GROWTH 1.7   // exponential light-step growth
#define AL_CLOUD_HG_G         0.62  // Henyey-Greenstein forward eccentricity
#define AL_CLOUD_MS_EXT       0.55  // Wrenninge per-octave extinction decay (a)
#define AL_CLOUD_MS_PHASE     0.60  // per-octave phase-g decay (b)
#define AL_CLOUD_MS_BRIGHT    0.70  // per-octave brightness decay (c)
#define AL_CLOUD_POWDER       0.35  // powder (dark-edge) term strength
#define AL_CLOUD_POWDER_STR   0.60  // how much powder is mixed in
#define AL_CLOUD_AMBIENT      0.65  // sky-ambient contribution to cloud fill
#define AL_CLOUD_SUN          22.0  // direct sun-scatter brightness (HDR)

// --- Cirrus (cheap thin high layer) ----------------------------------------
#define AL_CIRRUS_SCALE   0.00090
#define AL_CIRRUS_COVER   0.55
#define AL_CIRRUS_DENSITY 1.10
#define AL_CIRRUS_HG      0.70
#define AL_CIRRUS_SUN     8.0
#define AL_CIRRUS_AMB     0.50

// --- Cloud shadow (lib/clouds_common.glsl) ---------------------------------
#define AL_CLOUD_SHADOW_CLEAR 0.50  // ground darkening under clear-sky cloud
#define AL_CLOUD_SHADOW_STORM 0.80  // stronger under storm cloud

// --- Temporal accumulation --------------------------------------------------
#define AL_CLOUD_HISTORY_BLEND 0.85 // fraction of valid history kept per frame
#define AL_CLOUD_HDR_MAX       65000.0 // range-validation ceiling (NaN-proof)


/* =========================================================================
   SKY  (physically based atmosphere — Phase 3)
   -------------------------------------------------------------------------
   The sky is an analytic single-scatter atmosphere (Rayleigh + Mie + ozone,
   lib/atmosphere*.glsl) baked once per frame into the colortex6 sky-view LUT
   tile by the prepare pass and sampled everywhere. Direct/ambient LIGHT colours
   are derived from the same model (pure math, no LUT) in lib/lighting.glsl —
   the warm amber sun bias (AL_SUN_TINT) and cool ambient identity
   (AL_AMBIENT_SKY) are the tint MODIFIERS in the identity block below.
   ========================================================================= */

// Overall sky brightness. Baked into the LUT by the prepare pass so every
// reader (sky, clouds, fog, reflections) scales consistently.
#define SKY_BRIGHTNESS 1.0 // [0.50 0.75 1.00 1.25 1.50 2.00]

// HDR boost applied to the MOON texture (and any custom sky textures) so it
// reads through the tonemap and blooms later. NOTE: MOON-ONLY now — the vanilla
// sun texture is discarded and replaced by the procedural sun disc below
// (SUN_DISC_BRIGHTNESS), so this no longer affects the sun.
#define SUNMOON_BRIGHTNESS 3.0 // [1.0 2.0 3.0 4.0 6.0]

// Mie (haze/aerosol) scattering strength. Higher = a brighter, hazier white
// glow around the sun and a milkier horizon band.
#define MIE_STRENGTH 1.0 // [0.25 0.50 0.75 1.00 1.50 2.00 3.00]

// Atmospheric turbidity. Higher = dustier air: warmer, redder sun and a
// thicker, more washed-out horizon.
#define TURBIDITY 1.0 // [0.50 0.75 1.00 1.50 2.00 3.00]

// Procedural sun-disc angular size, multiplying AL_SUN_ANGULAR_RADIUS. 1.0 is
// the pack's deliberately soft, dreamy sun; lower is a tighter, sharper disc.
#define SUN_DISC_SIZE 1.0 // [0.50 0.75 1.00 1.50 2.00 3.00]

// Procedural sun-disc HDR brightness. High values bloom hard once bloom lands
// in Phase 4; the placeholder tonemap keeps them from clipping now.
#define SUN_DISC_BRIGHTNESS 2.0 // [0.50 1.00 2.00 4.00 8.00 16.00]

// Sun path tilt (degrees). Iris reads this const directive from the literal
// source text with NO macro expansion, so it must BE the constant — edit the
// number to retune. Negative tilts the sun's arc so it rakes low across the
// sky for long, warm golden hours (the pack's signature light).
const float sunPathRotation = -35.0;

// Procedural night sky: hash-cell twinkling stars, a tilted galaxy band and
// rare shooting stars, faded in through dusk and kept below the moon's
// brightness (lib/nightsky.glsl). Off removes all three and the sky pass adds
// nothing after dark. Additive over the atmosphere.
#define NIGHT_SKY // [NIGHT_SKY]

// Star field density. Scales how many cells spawn a star (many faint, few
// bright regardless). 1.00 is the tuned baseline; lower for a sparse minimalist
// sky, higher for a dense field.
#define STARS_DENSITY 1.00 // [0.50 0.75 1.00 1.50 2.00]


/* =========================================================================
   FOG
   -------------------------------------------------------------------------
   Aerial-perspective fog (lib/fog.glsl, composite1). NOT uniform density: an
   exponential height falloff whose in-scatter is sampled from the atmosphere
   sky LUT, so distance shifts bluer + desaturated with a warm hazy horizon and
   tracks time of day, weather and biome. One cheap pass — kept on in every
   profile (POTATO included). Internal density/height tunables live in
   lib/fog.glsl.
   ========================================================================= */

// Master aerial-fog toggle. Also gates the pass itself via
// `program.composite1.enabled = AERIAL_FOG` in shaders.properties, so turning
// it off genuinely skips the pass (colortex0 passes straight through to final).
#define AERIAL_FOG // [AERIAL_FOG]

// Overall fog density multiplier on top of the tuned sea-level baseline.
// 1.00 is the intended look; lower for crisp long views, higher for a soupier,
// moodier haze.
#define FOG_DENSITY 1.00 // [0.50 0.75 1.00 1.25 1.50 2.00]


/* =========================================================================
   POST
   ========================================================================= */

// Fixed exposure multiplier applied before the placeholder tonemap. Auto
// exposure arrives in a later phase; this is the manual override for now.
#define EXPOSURE 1.0 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]


/* =========================================================================
   DEBUG
   ========================================================================= */

// Visualise raw G-buffer channels. 0 = normal render.
//   1 albedo | 2 world normal | 3 lightmap (block=R, sky=G) | 4 depth |
//   5 matID | 6 ambient occlusion (white = unoccluded)
#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6]


/* =========================================================================
   COLOUR IDENTITY CONSTANTS  (not GUI options — edit + hot-reload to retune)
   -------------------------------------------------------------------------
   THE LOOK. Warm amber key light against a cool blue-purple sky fill is the
   pack's signature; keep the contrast strong. All values are LINEAR RGB
   (lighting math runs in linear space).
   ========================================================================= */

// Warm amber sun. Never neutral white — this bias is intentional at all
// times of day.
const vec3 AL_SUN_TINT = vec3(1.00, 0.79, 0.52);

// Cool, dim moonlight for the night key.
const vec3 AL_MOON_TINT = vec3(0.42, 0.55, 0.90);

// Cool blue-purple sky irradiance for the UPPER hemisphere (faces looking up
// toward open sky). The cool half of the warm/cool contrast.
const vec3 AL_AMBIENT_SKY = vec3(0.34, 0.46, 0.82);

// Slightly warmer, dimmer fill for the LOWER hemisphere (faces looking down
// pick up warmer ground bounce).
const vec3 AL_AMBIENT_GROUND = vec3(0.30, 0.27, 0.28);

// Sky-lightmap window over which the cool ambient desaturates toward neutral
// grey. Below LO the tint is fully greyed (caves / deep dark water — no purple
// cast); above HI the full cool blue-purple identity is kept. Narrowed for the
// 0.2.0 field test: the old 0.15-0.45 window greyed out normal above-ground
// shade (under trees / overhangs, sky-lm ~0.3-0.5), which read as "just normal
// Minecraft". This 0.05-0.30 window keeps the signature cool tint for anything
// with sky-lm >= 0.30 (all ordinary daylight shade) and only greys the genuinely
// sky-starved: caves and deep/dark water.
#define AL_AMBIENT_DESAT_LO 0.05
#define AL_AMBIENT_DESAT_HI 0.30

// Warm torch / block-light colour (used when BLOCKLIGHT_TINT is OFF — a single
// flat tint).
const vec3 AL_TORCH_TINT = vec3(1.00, 0.58, 0.26);

// Blocklight colour-temperature ramp (BLOCKLIGHT_TINT on). Candle-amber close to
// the source, deep ember-orange at the dim edge of its reach. CANDLE luminance
// is kept a touch under the sun so a torch core never out-punches daylight.
const vec3 AL_TORCH_CANDLE = vec3(1.00, 0.66, 0.32);
const vec3 AL_TORCH_EMBER  = vec3(1.00, 0.40, 0.14);

// Cool-blue night minimum. Terrain under open sky never falls below this.
const vec3 AL_NIGHT_FLOOR = vec3(0.030, 0.045, 0.085);

// Faint indirect-bounce lift added to the light sum so coloured faces never
// read as pure black. Kept near-neutral (only a whisper cool): this is the ONLY
// light an unlit cave face receives, so any saturation here would tint the cave.
// Field fix #2 wants caves free of a colour cast, so this stays essentially grey.
const vec3 AL_BOUNCE = vec3(0.020, 0.020, 0.022);

#endif // AL_SETTINGS
#ifndef AL_LIB_COMMON
#define AL_LIB_COMMON

/*
 lib/common.glsl — small constants and helpers shared everywhere.
 Pure GLSL 3.30 math, no samplers, no state. Keep this dependency-free.
*/


#define AL_PI     3.14159265358979
#define AL_TAU    6.28318530717959
#define AL_HALFPI 1.57079632679490

// Clamp-to-[0,1] convenience (a.k.a. HLSL saturate).
float alSaturate(float x)  { return clamp(x, 0.0, 1.0); }
vec2  alSaturate(vec2  x)  { return clamp(x, 0.0, 1.0); }
vec3  alSaturate(vec3  x)  { return clamp(x, 0.0, 1.0); }

// Smooth 0..1 ramp with zero derivative at both ends (Hermite).
float alSmooth(float x) { x = alSaturate(x); return x * x * (3.0 - 2.0 * x); }

#endif // AL_LIB_COMMON
#ifndef AL_LIB_COLOR
#define AL_LIB_COLOR

/*
 lib/color.glsl — colour-space transforms, luminance, tonemap placeholder.
 All pure float math (GLSL 3.30 safe). Lighting runs in LINEAR space; textures
 arrive as sRGB and must be decoded before shading, then re-encoded in final.
*/


// sRGB <-> linear. Fast 2.2-gamma approximation — precise enough for Phase 1,
// cheap, and branch-free. (A piecewise-exact sRGB curve can drop in later.)
vec3 alSrgbToLinear(vec3 c) { return pow(max(c, 0.0), vec3(2.2)); }
vec3 alLinearToSrgb(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// Rec.709 relative luminance of a linear-RGB colour.
float alLuminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

/*
 PLACEHOLDER TONEMAP — Phase 4 REPLACEMENT TARGET.
 This is the Narkowicz ACES filmic fit: cheap, gives a pleasant filmic
 shoulder so HDR values read reasonably. It is explicitly a stand-in; the
 real look is the AgX-style soft-filmic grade delivered in Phase 4. Do not
 tune the pack's final contrast against this curve.
 Input: linear HDR. Output: display-linear in [0,1] (still needs sRGB encode).
*/
vec3 alTonemapPlaceholder(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return alSaturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

#endif // AL_LIB_COLOR
#ifndef AL_LIB_SPACE
#define AL_LIB_SPACE

/*
 lib/space.glsl — coordinate-space transforms for fullscreen passes.
 Screen (uv+depth) -> view -> player/world. This file OWNS the inverse
 matrices it needs, so any fullscreen fragment program that includes it must
 NOT redeclare them (avoids duplicate-uniform errors). Gbuffers vertex
 shaders that only need gbufferModelViewInverse declare it themselves and do
 not include this file.
*/


uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;

// Screen-space (uv in [0,1], hardware depth in [0,1]) -> view space.
vec3 alScreenToView(vec2 uv, float depth) {
    vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
    vec4 clip = vec4(ndc, 1.0);
    vec4 view = gbufferProjectionInverse * clip;
    return view.xyz / view.w;
}

// View space -> player space (world position relative to the camera / feet).
// This is the space Iris' shadow matrices operate in.
vec3 alViewToPlayer(vec3 viewPos) {
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

// Direction only (ignores translation) view -> world.
vec3 alViewDirToWorld(vec3 v) {
    return mat3(gbufferModelViewInverse) * v;
}

/*
 -------------------------------------------------------------------------
 PREVIOUS-FRAME reprojection (for temporal accumulation — GTAO history).
 -------------------------------------------------------------------------
 To find where THIS frame's surface point sat on the PREVIOUS frame's screen
 we must re-express its position in the previous frame's player (feet) space.
 Player space is camera-relative, so a world-static point shifts by the camera
 delta (cameraPosition - previousCameraPosition) between frames. We then apply
 the PREVIOUS frame's model-view + projection (Iris' gbufferPrevious* matrices)
 to land in previous-frame clip space. These uniforms are declared here so any
 fullscreen pass that reprojects gets them for free (declaring an unused uniform
 is harmless — Iris still supplies it, glslang ignores it).
*/
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

// Current-frame player-space position -> previous-frame VIEW space.
vec3 alPlayerToPrevView(vec3 playerPos) {
    vec3 prevPlayer = playerPos + (cameraPosition - previousCameraPosition);
    return (gbufferPreviousModelView * vec4(prevPlayer, 1.0)).xyz;
}

// Previous-frame view-space position -> previous-frame screen space.
// Returns vec3(uv.xy, ndcDepth), all in [0,1] when the point is on-screen and
// in front of the previous camera (caller checks the range for validity).
vec3 alPrevViewToScreen(vec3 prevView) {
    vec4 clip = gbufferPreviousProjection * vec4(prevView, 1.0);
    vec3 ndc  = clip.xyz / clip.w;
    return ndc * 0.5 + 0.5;
}

// Linear eye-space depth (positive distance in front of the camera) from a
// view-space position. No near/far needed — it is just -z. Shared convention
// for the AO history's stored depth (colortex5.b) and its reprojection test.
float alLinearEyeDepth(vec3 viewPos) {
    return -viewPos.z;
}

#endif // AL_LIB_SPACE

uniform sampler2D colortex0; uniform sampler2D colortex2; uniform sampler2D depthtex0;
uniform float rainStrength; uniform float wetness; uniform float thunderStrength;
uniform int isEyeInWater; uniform int biome_category; uniform float temperature; uniform float rainfall;
#ifndef AL_LIB_FOG
#define AL_LIB_FOG

/*
============================================================================
 lib/fog.glsl — aerial-perspective fog (Phase 3, FOG subsystem)
----------------------------------------------------------------------------
 The model, in one paragraph. This is NOT a uniform-density distance fade and
 NOT a hard cutoff. It is single-scattering aerial perspective with a
 SEA-LEVEL-FLOORED EXPONENTIAL HEIGHT falloff: air density is CONSTANT at and
 below sea level and thins with altitude ABOVE it (scale height AL_FOG_HEIGHT).
 The floor matters — an un-floored exp would grow without bound below sea level
 and drown caves in bright sky haze. Aerial fog is also gated by sky exposure
 (see alApplyAerialFog) so enclosed spaces get none. Along the view ray we
 integrate the floored density analytically to an optical depth tau;
 extinction = exp(-tau) darkens
 the scene toward the distance while in-scattered light — sampled from the
 atmosphere's own sky LUT in the view direction, alSkySample(viewDir) — is
 added back in. Because the in-scatter colour IS the sky, distance naturally
 shifts bluer + desaturated with a warm hazy horizon, and the whole thing
 tracks time of day for free (the LUT already encodes sun elevation). Biome
 and weather nudge density and tint the in-scatter (tables below). Sky pixels
 (depth == 1) are left untouched — the clouds pass already carries the sky's
 own transmittance and must not be fogged twice — and underwater is skipped
 entirely (Phase 4 owns it).

 Pure-math + one texture read helper. The only sampler touched here is
 colortex6, and only indirectly via alSkySample() — that sampler is declared
 and owned by lib/atmosphere.glsl (this file declares no samplers of its own).
 Everything is GLSL 3.30 / Mac-GL4.1 safe: no loops, just a couple of exp()
 calls, so the pass is trivially cheap and stays on in every profile (POTATO
 included).

 DEPENDS ON lib/atmosphere.glsl (ATMOSPHERE agent) for:
   vec3 alSkySample(vec3 worldDir)   — cheap sky-LUT read (colortex6)
 We defensively range-validate its RESULT and fall back to an analytic sky
 gradient if it is ever non-finite / out of range (first-frame colortex6
 garbage on the Apple-GL clear=false path), so fog never produces NaNs even
 if the LUT read upstream is momentarily bad.
============================================================================
*/


/* -------------------------------------------------------------------------
   Tunables (internal, not GUI — edit + hot-reload). The GUI FOG_DENSITY
   slider (settings.glsl) multiplies AL_FOG_SEA_DENSITY on top of these.
   ------------------------------------------------------------------------- */

// Extinction coefficient at sea level, per world-metre, at FOG_DENSITY = 1 and
// in a neutral biome/clear weather. Tuned so a horizontal view reaches ~half
// extinction near ~150 m of clear air (ln2 / 0.0046 ≈ 150) — a soft dreamy
// haze, not soup.
#define AL_FOG_SEA_DENSITY 0.0046

// Scale height (metres): altitude over which density falls by 1/e. Larger =
// fog climbs higher up mountains before thinning.
#define AL_FOG_HEIGHT 26.0

// Reference sea level (world Y). Density peaks here. MC sea level is y≈62.
#define AL_FOG_SEA_LEVEL 62.0

// Optical-depth cap before exp(): keeps extinction well-defined and avoids
// denormal underflow. exp(-40) ≈ 4e-18 (fully fogged), never NaN/inf.
#define AL_FOG_MAX_TAU 40.0

// Sky-exposure gate window (raw sky lightmap 0..1). Aerial fog is OUTDOOR haze:
// it needs open sky to scatter into the view. Optical depth is scaled by
// smoothstep(LO, HI, skyLightmap) so caves and interiors (sky-lm ~0) get ZERO
// fog while open valleys (sky-lm >= HI) get the full amount — preserving Phase
// 2's cave darkness. Window mirrors the lighting ambient-desat window.
#define AL_FOG_SKY_GATE_LO 0.05
#define AL_FOG_SKY_GATE_HI 0.35

// Biome-modulation master switch. All biome_category / temperature / rainfall
// reads (verified Iris uniforms — see composite1.fsh header for evidence) are
// gated behind this. If a future Iris ever drops these uniforms, flip this off
// (or the profile can) and fog degrades gracefully to weather-only modulation
// with ZERO compile or runtime breakage. On by default (uniforms verified).
#define AL_FOG_BIOME_UNIFORMS

/* -------------------------------------------------------------------------
   Iris biome_category ordinals.
   VERIFIED against Iris source (1.21.11):
     common/src/main/java/net/irisshaders/iris/parsing/BiomeCategories.java
   Iris does NOT inject CAT_* macros into shader source (verified: no CAT_* in
   gl/shader/StandardMacros.java), so — contrary to a common assumption — we
   cannot rely on a predefined CAT_SWAMP etc. We therefore define our own
   constants matching the enum ORDINAL, which is exactly what the
   biome_category uniform reports (uniform1i = BiomeCategories.ordinal()).
   Values 0..16 also coincide with OptiFine's documented CAT_* numbering.
   ------------------------------------------------------------------------- */
#define AL_CAT_NONE          0
#define AL_CAT_TAIGA         1
#define AL_CAT_EXTREME_HILLS 2
#define AL_CAT_JUNGLE        3
#define AL_CAT_MESA          4   // badlands
#define AL_CAT_PLAINS        5
#define AL_CAT_SAVANNA       6
#define AL_CAT_ICY           7   // snowy
#define AL_CAT_THE_END       8
#define AL_CAT_BEACH         9
#define AL_CAT_FOREST        10
#define AL_CAT_OCEAN         11
#define AL_CAT_DESERT        12
#define AL_CAT_RIVER         13
#define AL_CAT_SWAMP         14
#define AL_CAT_MUSHROOM      15
#define AL_CAT_NETHER        16
#define AL_CAT_MOUNTAIN      17  // Iris addition (OptiFine-undocumented)
#define AL_CAT_UNDERGROUND   18  // Iris addition

/* -------------------------------------------------------------------------
   Analytic sky fallback — used only if the colortex6 LUT read comes back
   non-finite / out of range (defensive; see file header). A cheap
   horizon-warm → zenith-cool gradient so distance still reads hazy-blue even
   before the atmosphere LUT is valid.
   ------------------------------------------------------------------------- */
vec3 alFogAnalyticSky(vec3 worldDir) {
    float h = alSaturate(worldDir.y * 0.5 + 0.5);       // 0 down .. 1 up
    vec3 horizon = vec3(0.62, 0.60, 0.58);              // warm hazy band
    vec3 zenith  = vec3(0.20, 0.34, 0.62);              // cool blue
    return mix(horizon, zenith, alSmooth(h)) * SKY_BRIGHTNESS;
}

// NaN-proof in-scatter colour. alSkySample() reads the clear=false colortex6
// tile; the range test uses comparisons (NaN fails every one) rather than
// isnan/clamp alone, and self-heals to the analytic gradient. Bound 1e4 is
// well above any plausible HDR sky radiance but rejects inf/garbage.
vec3 alFogSkyInscatter(vec3 worldDir) {
    vec3 sky = alSkySample(worldDir);
    bool ok = (sky.r >= 0.0 && sky.g >= 0.0 && sky.b >= 0.0)
           && (sky.r < 1.0e4 && sky.g < 1.0e4 && sky.b < 1.0e4);
    return ok ? sky : alFogAnalyticSky(worldDir);
}

/* -------------------------------------------------------------------------
   Biome + weather modulation.
   =========================================================================
   MULTIPLIER TABLE (all deliberately SUBTLE; layered, no hard cutoffs)
   -------------------------------------------------------------------------
   BIOME (by biome_category, gated behind AL_FOG_BIOME_UNIFORMS):
     category         densityMul   scatterTint (R,G,B)        rationale
     SWAMP     (14)     x1.35       (0.90, 1.03, 0.88)   denser + slight green cast
     JUNGLE    (3)      x1.20       (0.95, 1.02, 0.93)   slightly denser, faint green
     DESERT    (12)     x0.70       (1.06, 0.98, 0.86)   thinner + warmer
     MESA      (4)      x0.75       (1.07, 0.96, 0.82)   thinner + warmer (badlands)
     ICY       (7)      x1.05       (0.92, 0.97, 1.08)   cooler
     (all others)       x1.00       (1.00, 1.00, 1.00)   neutral

   CONTINUOUS climate layer (smooth, on top of the discrete category — catches
   snowy/arid variants whose category is generic, e.g. snowy taiga = TAIGA):
     cold = saturate((0.30 - temperature) / 0.45)   → cool tint  (x up to 0.6)
     arid = saturate((0.30 - rainfall)/0.30)
          * saturate((temperature - 0.80)/0.40)      → warm tint + x0.88 density

   WEATHER (verified uniforms, always applied — no biome gate):
     rain = saturate(max(rainStrength, wetness*0.6))
       density x mix(1.0, 1.8, rain)                 rain raises density noticeably
       desat   = rain * 0.6                          in-scatter desaturates in rain
     thunder = saturate(thunderStrength)
       darken  = mix(1.0, 0.72, thunder)             thunder darkens the fog
   =========================================================================
   Outputs:
     densityMul  — multiplies the sea-level extinction coefficient
     scatterTint — multiplies the in-scatter (sky) colour
     desat       — 0..1, how far to pull in-scatter toward its own luminance
     darken      — multiplies the in-scatter brightness
   ------------------------------------------------------------------------- */
void alFogModulation(int biomeCategory, float temperature, float rainfall,
                     float rainStrength, float wetness, float thunderStrength,
                     out float densityMul, out vec3 scatterTint,
                     out float desat, out float darken) {
    densityMul  = 1.0;
    scatterTint = vec3(1.0);
    desat       = 0.0;
    darken      = 1.0;

#ifdef AL_FOG_BIOME_UNIFORMS
    // --- Discrete biome character ---
    if (biomeCategory == AL_CAT_SWAMP) {
        densityMul *= 1.35; scatterTint *= vec3(0.90, 1.03, 0.88);
    } else if (biomeCategory == AL_CAT_JUNGLE) {
        densityMul *= 1.20; scatterTint *= vec3(0.95, 1.02, 0.93);
    } else if (biomeCategory == AL_CAT_DESERT) {
        densityMul *= 0.70; scatterTint *= vec3(1.06, 0.98, 0.86);
    } else if (biomeCategory == AL_CAT_MESA) {
        densityMul *= 0.75; scatterTint *= vec3(1.07, 0.96, 0.82);
    } else if (biomeCategory == AL_CAT_ICY) {
        densityMul *= 1.05; scatterTint *= vec3(0.92, 0.97, 1.08);
    }

    // --- Continuous climate (smooth; catches generic-category variants) ---
    float cold = alSaturate((0.30 - temperature) / 0.45);
    float arid = alSaturate((0.30 - rainfall) / 0.30)
               * alSaturate((temperature - 0.80) / 0.40);
    scatterTint = mix(scatterTint, scatterTint * vec3(0.93, 0.97, 1.07), cold * 0.6);
    scatterTint = mix(scatterTint, scatterTint * vec3(1.05, 0.99, 0.88), arid * 0.5);
    densityMul *= mix(1.0, 0.88, arid);
#endif

    // --- Weather (always) ---
    float rain = alSaturate(max(rainStrength, wetness * 0.6));
    densityMul *= mix(1.0, 1.8, rain);
    desat       = rain * 0.6;
    darken      = mix(1.0, 0.72, alSaturate(thunderStrength));
}

/* -------------------------------------------------------------------------
   Analytic optical depth of SEA-LEVEL-FLOORED exponential height fog.

   The density profile is CONSTANT at/below sea level and only decays ABOVE it:
       rho(y) = beta0 * exp(-max(y - sea, 0) / H)
   i.e. rho == beta0 for every y <= sea, and thins with altitude above. This is
   the fix for the cave/below-sea explosion: the old un-floored exp grew without
   bound as y dropped (34x sea density at y=-30), replacing cave walls with
   bright sky haze. Air can't densify below sea level here; it plateaus.

   Along the ray y(t) = camY + dirY*t we integrate exactly via the piecewise
   antiderivative phi of the UNIT profile (rho/beta0):
       phi(y) = (y - sea)                        for y <= sea   (constant seg.)
       phi(y) = H * (1 - exp(-(y - sea)/H))      for y >  sea   (exp segment)
   phi is continuous (phi(sea)=0) and monotonically increasing (phi' = unit
   density > 0), so it transparently handles rays that CROSS the y=sea boundary
   (part constant-density, part exponential) with no explicit split. Then
       tau = beta0 * (phi(y1) - phi(y0)) / dirY                 (dirY != 0)
   which is always >= 0 (phi monotone: numerator and dirY share sign). The
   near-horizontal limit (dirY -> 0) is beta0 * unitDensity(y0) * dist, the
   consistent limit of the ratio above. exp() args are clamped so no altitude
   can produce inf/NaN.
   ------------------------------------------------------------------------- */

// Unit-profile antiderivative phi(y) (density measured in units of beta0).
float alFogPhiUnit(float y) {
    float d = y - AL_FOG_SEA_LEVEL;
    if (d <= 0.0) return d;                              // constant density below sea
    float e = clamp(-d / AL_FOG_HEIGHT, -AL_FOG_MAX_TAU, AL_FOG_MAX_TAU);
    return AL_FOG_HEIGHT * (1.0 - exp(e));               // exponential above sea
}

// Unit density (rho/beta0) at altitude y, floored at sea level.
float alFogUnitDensity(float y) {
    float d = max(y - AL_FOG_SEA_LEVEL, 0.0);
    return exp(clamp(-d / AL_FOG_HEIGHT, -AL_FOG_MAX_TAU, AL_FOG_MAX_TAU));
}

float alFogOpticalDepth(float camY, vec3 worldDir, float dist, float beta0) {
    float y0   = camY;
    float y1   = camY + worldDir.y * dist;
    float dirY = worldDir.y;

    float tau;
    if (abs(dirY) > 0.02) {
        tau = beta0 * (alFogPhiUnit(y1) - alFogPhiUnit(y0)) / dirY;
    } else {
        tau = beta0 * alFogUnitDensity(y0) * dist;      // near-horizontal ray
    }
    return clamp(tau, 0.0, AL_FOG_MAX_TAU);
}

/* -------------------------------------------------------------------------
   Full aerial-perspective evaluation for one pixel.
     sceneColor   — linear HDR colour under the fog (colortex0)
     camY         — camera world Y (cameraPosition.y)
     worldDir     — unit world-space view direction (camera -> fragment)
     dist         — straight-line distance camera -> fragment (metres)
     skyLightmap  — this pixel's raw sky lightmap (colortex2.a); gates fog so
                    caves/interiors (sky-lm ~0) get none. See AL_FOG_SKY_GATE_*.
     (biome/weather uniform values passed through to alFogModulation)
   Returns the fogged linear HDR colour.
   ------------------------------------------------------------------------- */
vec3 alApplyAerialFog(vec3 sceneColor, float camY, vec3 worldDir, float dist,
                      float userDensity, float skyLightmap, int biomeCategory,
                      float temperature, float rainfall, float rainStrength,
                      float wetness, float thunderStrength) {
    float densityMul; vec3 scatterTint; float desat; float darken;
    alFogModulation(biomeCategory, temperature, rainfall,
                    rainStrength, wetness, thunderStrength,
                    densityMul, scatterTint, desat, darken);

    // Sky-exposure gate: no open sky above -> no aerial fog (caves/interiors).
    float skyGate = smoothstep(AL_FOG_SKY_GATE_LO, AL_FOG_SKY_GATE_HI, skyLightmap);

    float beta0 = AL_FOG_SEA_DENSITY * max(userDensity, 0.0) * densityMul * skyGate;
    float tau   = alFogOpticalDepth(camY, worldDir, dist, beta0);
    float ext   = exp(-tau);                 // 1 = clear, 0 = fully fogged

    // In-scatter = sky radiance in the view direction, biome-tinted, thunder-
    // darkened, rain-desaturated. This is what makes distance read bluer/hazier
    // and warm at the horizon — the colour comes straight from the atmosphere.
    vec3 inscatter = alFogSkyInscatter(worldDir) * scatterTint * darken;
    inscatter = mix(inscatter, vec3(alLuminance(inscatter)), desat);

    vec3 result = sceneColor * ext + inscatter * (1.0 - ext);
    return max(result, vec3(0.0));
}

#endif // AL_LIB_FOG
in vec2 texcoord;
layout(location=0) out vec4 outColor;
void main(){
  vec3 scene=texture(colortex0,texcoord).rgb;
  float depth=texture(depthtex0,texcoord).r;
  if(depth>=1.0||isEyeInWater!=0){outColor=vec4(scene,1.0);return;}
  vec3 viewPos=alScreenToView(texcoord,depth);
  vec3 playerPos=alViewToPlayer(viewPos);
  float dist=length(playerPos);
  vec3 worldDir=(dist>1e-4)?playerPos/dist:vec3(0,1,0);
  float skyLm=alSaturate(texture(colortex2,texcoord).a);
  vec3 fogged=alApplyAerialFog(scene,cameraPosition.y,worldDir,dist,FOG_DENSITY,skyLm,biome_category,temperature,rainfall,rainStrength,wetness,thunderStrength);
  bool finite=(fogged.r>=0.0&&fogged.g>=0.0&&fogged.b>=0.0);
  outColor=vec4(finite?min(fogged,vec3(65000.0)):scene,1.0);
}
