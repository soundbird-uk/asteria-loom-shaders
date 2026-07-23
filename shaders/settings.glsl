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

// Night brightness — how readable open terrain stays after dark. Master
// multiplier on the whole NIGHT ambient (both the cool sky fill's night lift and
// the cool-blue floor); noon is never affected. Default 1.0 = the intended dark,
// moody, moonlit look (0.3.2 retune); raise it if you want brighter nights.
#define NIGHT_BRIGHTNESS 1.0 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

// Night ambient level (internal, not GUI). The Phase-3 atmosphere-driven ambient
// (alAmbientColor) bottoms out at 0.18x its day value after dark; lib/lighting.glsl
// multiplies the sky ambient by mix(this * NIGHT_BRIGHTNESS, 1.0, dayFactor).
//
// 0.3.2 FIELD RETUNE: the 0.3.1 value of 1.9 (chasing the old 0.1.1 "correct
// night") overshot — the user reports nights "look exactly like vanilla, not
// nearly dark enough". The brief wants atmospheric shader-pack nights: clearly
// darker and moodier than vanilla, cool-blue readable but NOT daylight-lite.
// Dropped to 0.90 so the open-ground night sits at ~0.54x the 0.3.1 level (moon
// direct + night floor were cut alongside — see AL_NIGHT_DIRECT_SCALE and
// AL_NIGHT_FLOOR). NOON is provably unchanged (dayFactor==1 -> factor 1.0). Edit
// + hot-reload; NIGHT_BRIGHTNESS is the user-facing multiplier on top.
#define AL_NIGHT_AMBIENT_LIFT 0.90

// Moon direct-key scale at night (internal, not GUI). Multiplies ONLY the direct
// sun/moon term via mix(this, 1.0, dayFactor), so moonlight is dimmed after dark
// (part of the 0.3.2 darker-night retune) while NOON direct is untouched
// (dayFactor==1 -> 1.0). Keeps a soft directional moon key for silhouettes
// without lifting the whole scene toward daylight. Edit + hot-reload.
#define AL_NIGHT_DIRECT_SCALE 0.55

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
// occluder (contact-hardening) instead of a fixed blur. The default (robust)
// path reads RAW shadow depth (shadowHardwareFiltering=false) and does the
// blocker search + soft manual-compare PCF entirely in-shader, so PCSS works on
// EVERY platform (no hardware-sampler dependency). Off (LOW) = plain
// fixed-radius Vogel. See lib/shadow.glsl and AL_SHADOW_HW below.
#define SHADOW_PCSS // [SHADOW_PCSS]

// Shadow filter tap count (Vogel disc). More = smoother penumbrae, more cost.
#define SHADOW_SAMPLES 12 // [8 12 16 24]

// Screen-space contact shadows: a short view-space raymarch that catches the
// fine contact detail the shadow map is too coarse for (block bases, tight
// gaps). Multiplies the shadow term. Off by default; on for HIGH/ULTRA.
//#define CONTACT_SHADOWS // [CONTACT_SHADOWS]

// --- Shadow path (internal, not GUI) --------------------------------------
// EXPERIMENTAL hardware-shadow-sampler path. OFF by default. The shipping path
// is the software manual-compare (raw depth + step) shadow, which is the code
// the 0.1.1 build used and the field confirmed as correct — it produces visible
// soft shadows identically on Windows and macOS, keeping distortion + PCSS.
//
// The hardware path (sampler2DShadow + GL_LEQUAL hardware PCF, gated by
// IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS for the PCSS blocker search) shipped
// in 0.2.x and was field-confirmed BROKEN in opposite directions per platform:
// zero shadows on Windows (the separate-sampler blocker search's
// `if (blockers < 0.5) return 1.0` early-out turns any raw-read discrepancy into
// fully-lit EVERYWHERE) and over-shadowing on macOS. It cannot be proven correct
// in CI (no Mac GL driver), so it is quarantined here. Enabling it ALSO requires
// setting `shadowHardwareFiltering = true` in shaders.properties.
//#define AL_SHADOW_HW

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

// Cloud drift speed. A gentle, dreamy roll at 1.0; the slider scales the wind
// linearly. At 1.0 the coverage pattern drifts ~29 blocks/second (see
// AL_CLOUD_WIND_SPEED below), i.e. a soft breeze — 0.25 is nearly becalmed,
// 4.0 a brisk storm front.
#define CLOUD_SPEED 1.0 // [0.25 0.5 1.0 2.0 4.0]

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
// Base coverage drift in NOISE units/sec, before the CLOUD_SPEED slider. World
// drift = AL_CLOUD_WIND_SPEED * CLOUD_SPEED / AL_CLOUD_COVERAGE_SCALE blocks/sec
// => 0.008 * 1.0 / 0.00028 ≈ 29 blocks/s at the default (a gentle dreamy roll).
// This is ~44x slower than the 0.3.1 default (0.35) that field-tested "WAY too
// fast"; the slider restores brisker motion for those who want it.
#define AL_CLOUD_WIND_SPEED       0.008   // coverage drift (noise units / sec)
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

// --- Distance fade / aerial perspective ------------------------------------
// Clouds must melt into the same horizon haze as terrain fog (fog.glsl leaves
// sky pixels untouched, so the cloud pass fades itself). We reuse lib/fog.glsl's
// optical-depth model + AL_FOG_* constants so the fade RATE matches terrain fog
// exactly, and recolour the cloud toward alSkySample(viewDir) — the SAME sky-LUT
// in-scatter fog uses — so both converge to one horizon value (no seam).
#define AL_CLOUD_AERIAL_RAINBOOST 1.8   // matches fog.glsl rain density mult

// --- Temporal accumulation --------------------------------------------------
#define AL_CLOUD_HISTORY_BLEND 0.85 // fraction of valid history kept per frame
#define AL_CLOUD_HDR_MAX       65000.0 // range-validation ceiling (NaN-proof)
// STRICT reprojection margin (fraction of screen). A reprojected history UV must
// land inside [MARGIN, 1-MARGIN]^2 or the pixel uses the CURRENT frame only —
// NO edge-clamped read. This is the core fix for the "dark box" veil: newly
// revealed screen regions (camera rotation/translation) never blend garbage or
// clamped edge history. Simulated: kills the veil (0.30 -> ~0.05, converges).
#define AL_CLOUD_REPROJ_MARGIN 0.02
// Real transmittance writes are floored to this tiny epsilon, reserving exactly
// 0.0 as the "invalid / uninitialised (Apple-GL clear=false garbage)" marker: a
// history alpha below it is treated as invalid and rejected. Invisible visually
// (a 0.2% floor), robust as a validity sentinel.
#define AL_CLOUD_TRANS_EPS 0.002


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
//   5 matID | 6 ambient occlusion (white = unoccluded) |
//   7 pipeline probe A (deferred1 texcoord.xy + sampled depth, raw) |
//   8 pipeline probe B (deferred1 branch: red = sky, green = lit geometry)
// Probes 7/8 bypass ALL grading + the fog/cloud composite passes so they show
// exactly what deferred1 wrote — a decisive check that the opaque shading pass
// (not a later fullscreen pass) is producing correct per-pixel output.
#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7 8]


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
// BAND FIX (0.3.x): the sky lightmap is quantised (~16 levels), so a smoothstep
// whose ACTIVE range spans only a few of them shows a hard contour where the
// transition lands — visible as banding/contours on submerged terrain. Lowering
// LO from 0.05 to 0.00 widens the active range across MORE quantised levels,
// cutting the worst per-level jump ~21% (0.389 -> 0.307), while HI stays 0.30 so
// above-ground shade (sky-lm >= 0.30) keeps its FULL cool tint (no vibrancy
// regression). The aerial-fog sky gate (lib/fog.glsl) is aligned to this SAME
// window so the two no longer place offset contours at different depths (that
// double band was half the visible artifact).
#define AL_AMBIENT_DESAT_LO 0.00
#define AL_AMBIENT_DESAT_HI 0.30

// Warm torch / block-light colour (used when BLOCKLIGHT_TINT is OFF — a single
// flat tint).
const vec3 AL_TORCH_TINT = vec3(1.00, 0.58, 0.26);

// Blocklight colour-temperature ramp (BLOCKLIGHT_TINT on). Candle-amber close to
// the source, deep ember-orange at the dim edge of its reach. CANDLE luminance
// is kept a touch under the sun so a torch core never out-punches daylight.
const vec3 AL_TORCH_CANDLE = vec3(1.00, 0.66, 0.32);
const vec3 AL_TORCH_EMBER  = vec3(1.00, 0.40, 0.14);

// Cool-blue night minimum. Terrain under OPEN SKY (gated by sky lightmap, so
// caves get none) never falls below this after dark. 0.3.2 field retune: dropped
// ~48% from (0.030,0.045,0.085) so the floor reads as "moonlit gloom" rather than
// "daylight-lite" — nights are clearly darker while silhouettes/nearby detail stay
// readable. Hue kept cool-blue. Scaled by the NIGHT_BRIGHTNESS GUI slider.
const vec3 AL_NIGHT_FLOOR = vec3(0.015, 0.022, 0.043);

// Faint indirect-bounce lift added to the light sum so coloured faces never
// read as pure black. Kept near-neutral (only a whisper cool): this is the ONLY
// light an unlit cave face receives, so any saturation here would tint the cave.
// Field fix #2 wants caves free of a colour cast, so this stays essentially grey.
const vec3 AL_BOUNCE = vec3(0.020, 0.020, 0.022);

#endif // AL_SETTINGS
