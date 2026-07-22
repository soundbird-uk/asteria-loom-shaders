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
// while its peak stays just under the warm-sun luminance. Edit + hot-reload.
//   BASE     overall lift of the whole block-light term (the 0.1.1 fix's punch)
//   FALLOFF  perceptual power on the lightmap (higher = tighter to the source)
//   TAIL     blend toward a gentler quadratic so distant grass keeps a glow
#define AL_BLOCKLIGHT_BASE    1.10
#define AL_BLOCKLIGHT_FALLOFF 2.20
#define AL_BLOCKLIGHT_TAIL    0.30

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
   SKY
   ========================================================================= */

// Draw vanilla clouds (forward-lit). Defaults ON until volumetric clouds
// replace them in Phase 3. Also gates `program.gbuffers_clouds.enabled`.
#define VANILLA_CLOUDS // [VANILLA_CLOUDS]

// Overall sky-gradient brightness (reproduced vanilla gradient for now).
#define SKY_BRIGHTNESS 1.0 // [0.50 0.75 1.00 1.25 1.50 2.00]

// HDR boost applied to the sun/moon textures so the disc reads through the
// tonemap and blooms in later phases.
#define SUNMOON_BRIGHTNESS 3.0 // [1.0 2.0 3.0 4.0 6.0]


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
// grey. Below LO the tint is fully greyed (caves / deep underwater — no purple
// cast); above HI the full cool blue-purple identity is kept (open shade). The
// midpoint sits near sky-lightmap ~0.3 per the 0.1.1 field feedback.
#define AL_AMBIENT_DESAT_LO 0.15
#define AL_AMBIENT_DESAT_HI 0.45

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
