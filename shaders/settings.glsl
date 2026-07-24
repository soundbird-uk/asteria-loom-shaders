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
// 0.4.4 FIELD FIX ("light sources have no luminosity / don't illuminate"): base
// lifted 0.92 -> 1.55 and falloff eased 1.70 -> 1.45 so torches throw a much
// brighter, wider warm pool instead of a faint patch.
#define AL_BLOCKLIGHT_BASE    1.55
#define AL_BLOCKLIGHT_FALLOFF 1.45
#define AL_BLOCKLIGHT_TAIL    0.35

// Self-illumination strength for emissive light-source blocks (matID EMISSIVE):
// added as albedo * this in deferred1, so the block glows in its OWN texture
// colour and blooms a coloured halo. HDR — AgX rolls it off, bloom spreads it.
#define AL_EMISSIVE_STRENGTH  4.5

// Held-light strength (0.4.4b — "a torch in offhand doesn't illuminate stuff").
// A warm point light around the CAMERA driven by the held item's light value
// (heldBlockLightValue / _2), so carrying a torch/lantern/glowstone lights the
// nearby surroundings. deferred1 adds it, distance-attenuated and facing-weighted.
#define AL_HELD_LIGHT 1.6

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
// 0.4.4: dropped 0.90 -> 0.42 so night is genuinely dark/moody (the moon key +
// stars carry it), not "looks like no shader on".
// 5.0.4 FIELD: 0.42 read as too dark ("at night it's too dark"). Raised to 0.66 —
// a brighter moonlit night that's still cool + moody, not daylight.
#define AL_NIGHT_AMBIENT_LIFT 0.66

// Daytime ambient (cool sky fill) scale (internal). 0.4.4 ("sun does nothing /
// shadows not dark enough"): the shadowed side was lit almost as much as the lit
// side by a strong blue ambient. Cutting the ambient to 0.55 while the direct key
// is boosted gives real lit-vs-shadow CONTRAST. Open up-facing shade still reads
// (wrap=1 there); vertical/backfacing surfaces go properly dark.
#define AL_AMBIENT_SCALE 0.55

// Moon direct-key scale at night (internal, not GUI). Multiplies ONLY the direct
// sun/moon term via mix(this, 1.0, dayFactor), so moonlight is dimmed after dark
// (part of the 0.3.2 darker-night retune) while NOON direct is untouched
// (dayFactor==1 -> 1.0). Keeps a soft directional moon key for silhouettes
// without lifting the whole scene toward daylight. Edit + hot-reload.
#define AL_NIGHT_DIRECT_SCALE 0.40

// Direct-key contrast boost (internal, not GUI). Multiplies ONLY the direct
// sun/moon term in lib/lighting.glsl (never ambient), on top of SUN_INTENSITY.
// 0.4.3 field fix (ISSUE 7/8: "objects have no lit vs shadow side / sun too weak
// on ground"): the ambient wrap floor was lowered alongside, so overall exposure
// barely moves but the lit-vs-shadow CONTRAST rises — the sun now reads as a real
// key light with a bright side and a dark side. AgX rolls the extra highlight off
// softly, so noon does not clip. Edit + hot-reload.
#define AL_DIRECT_BOOST 1.95

// Low-sun warmth (0.4.8): extra warm-orange push on the DIRECT key as the sun
// nears the horizon, so sunrise/sunset cast a strong golden/orange colour onto
// terrain and blocks. Multiplied onto the sun colour, ramped in only at low sun.
const vec3 AL_SUN_LOW_TINT = vec3(1.30, 0.70, 0.34);

// (0.4.9: the sun-edge rim glow was removed — it read as an ugly bright outline.)

// Fake indirect-bounce floor. A tiny lift so unlit coloured faces are never
// pure black (real GI arrives in a later phase).
#define BOUNCE_INTENSITY 1.0 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00]


/* =========================================================================
   FOLIAGE WIND  (vertex sway — lib/wind.glsl, ISSUE 5)
   -------------------------------------------------------------------------
   Grass/plants and leaves sway in the gbuffers_terrain vertex shader (and the
   shadow pass, so their shadows wave in step). Block bases stay anchored (a
   height/top weight from at_midBlock); grass sways more than leaves; rolling
   gusts + per-plant phase make it organic and spatially varied, never a uniform
   sine. Foliage block IDs are mapped in block.properties (10010 grass, 10020
   leaves). Internal (not GUI) — edit + hot-reload; set strengths to 0 to disable.
   ========================================================================= */
// Master switch (internal). Comment out to compile foliage wind away entirely.
#define AL_WAVING_FOLIAGE
// Time multiplier on the whole animation.
#define AL_WIND_SPEED 1.0
// Grass / small-plant sway strength (the strong, lapping motion).
#define AL_WIND_GRASS 1.0
// Leaf flutter strength (deliberately subtler than grass — subtle branch-like
// movement, not big translation).
#define AL_WIND_LEAF  0.45


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
// 0.4.4b FIELD FIX ("contact shadows make grainy false shadows on DISTANT
// terrain"): the fixed-world-length screen-space march becomes many pixels wide
// far away, so its dithered taps read as grain. Fade contact shadows out by this
// camera distance (blocks) — they only matter for near contact detail anyway.
#define AL_CONTACT_MAX_DIST 22.0


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

// --- Cirrus / high wisps (cheap thin high layer) ---------------------------
// 0.4.3 (ISSUE 6: "need more small wispy white clouds"): the cirrus layer is
// extended into the pack's small-wisp system — a fragmented, multi-scale veil that
// dots the sky with many small bright wisps while the volumetric cumulus keeps the
// big weather masses. Higher coverage + lower density = lighter, wispier; the
// WISP break-up (lib/clouds.glsl) shatters the sheet into small streaks so it
// never reads as one continuous veil or as noisy speckle. Bright by day; the
// night darkening below applies to them too (composited together).
#define AL_CIRRUS_SCALE   0.00090
#define AL_CIRRUS_COVER   0.62
#define AL_CIRRUS_DENSITY 0.85
#define AL_CIRRUS_HG      0.70
#define AL_CIRRUS_SUN     8.0
#define AL_CIRRUS_AMB     0.50
// Small-wisp break-up: frequency multiplier (vs coverage scale) and how hard it
// fragments the cirrus sheet into small streaks. Higher WISP_STR = more, smaller
// wisps. Kept smooth (value noise) so wisps stay soft, never speckly.
#define AL_CIRRUS_WISP_SCALE 5.0
#define AL_CIRRUS_WISP_STR   0.60

// --- Night darkening (ISSUE 2: "night clouds too bright/white") ------------
// Applied to the whole composited cloud radiance in composite1 AFTER temporal
// accumulation, gated by the sun-elevation day factor so NOON is untouched. At
// night clouds drop to AL_CLOUD_NIGHT_BRIGHT of their day radiance and take on the
// cool AL_CLOUD_NIGHT_TINT, so they read as dark, moody, moonlit masses (with dark
// undersides) instead of glowing daytime white. Storm fronts stay visible but dim.
#define AL_CLOUD_NIGHT_BRIGHT 0.20
const vec3 AL_CLOUD_NIGHT_TINT = vec3(0.46, 0.58, 0.86);

// --- Cloud shadow (lib/clouds_common.glsl) ---------------------------------
#define AL_CLOUD_SHADOW_CLEAR 0.50  // ground darkening under clear-sky cloud
#define AL_CLOUD_SHADOW_STORM 0.80  // stronger under storm cloud

// --- Distance fade / aerial perspective ------------------------------------
// Clouds DISSOLVE with distance (opacity AND scattering fade toward zero) so
// distant clouds genuinely melt away instead of persisting as recoloured shapes
// (0.3.2 field fix). What's revealed is the background atmosphere sky, which is
// exactly alFogSkyInscatter(dir) = lib/fog.glsl's own far-fade target, so cloud
// and terrain fog converge to ONE horizon value with no seam. The fade uses
// fog.glsl's height-floored optical-depth model (reused, not duplicated): for
// clouds well above the fog layer that optical depth is ~linear in distance, so
// with the density boost below the fade reads as a dreamy distance haze —
// ~50% dissolved by ~1.2 km, ~85% by ~3 km, mostly gone at the horizon.
// Multiplier on terrain fog's own AL_FOG_SEA_DENSITY. >1 makes clouds dissolve a
// touch faster than terrain hazes (they melt INTO the haze the terrain becomes),
// while reusing fog's density means clouds AUTO-TRACK the fog agent's thickness
// tuning, keeping the horizon convergence stable across their edits.
#define AL_CLOUD_AERIAL_DENSITY   1.3   // cloud fog density vs terrain fog
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

// Aurora (Loom motif — GUI, gbuffers_skybasic via lib/aurora.glsl). Woven-band
// aurora curtains on CLEAR COLD NIGHTS only (cold biome + no rain + deep night):
// a few flowing green-teal curtains with violet fringes and slow undulation,
// added over the atmosphere next to the night sky, kept BELOW the moon so it
// stays dreamy rather than neon. Off removes it entirely.
#define AURORA // [AURORA]

// Aurora peak radiance (internal, not GUI). Deliberately below the star/moon
// range so the curtains read as a soft glow, never a neon poster.
#define AL_AURORA_STRENGTH 0.22


// --- Horizon-band softening (internal, not GUI — gbuffers_skybasic.fsh) ----
// 0.4.5b FIELD FIX (confirmed via Debug View 11): the analytic atmosphere makes a
// harsh, over-bright, yellow-green BAND at the astronomical horizon (dir.y ~ 0)
// that cuts a hard line across the scene right where distant terrain sits. These
// tame it into a soft haze so the sky-to-terrain transition reads naturally:
//   WIDTH  — elevation (|dir.y|) over which the softening fades out (radians-ish)
//   DESAT  — how far the band is pulled toward neutral grey (kills the midday
//            yellow-green; GATED to high sun so sunrise/sunset stay warm)
//   DIM    — overall dimming of the band at all times (never blinding)
#define AL_SKY_HORIZON_WIDTH 0.20
#define AL_SKY_HORIZON_DESAT 0.65
#define AL_SKY_HORIZON_DIM   0.68


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

// Sun shafts / god rays (GUI — composite2.fsh). Screen-space light scattering:
// from each pixel a march toward the sun's screen position accumulates UNOCCLUDED
// (sky / gap) samples, so warm shafts fan out through gaps in leaves and around
// terrain silhouettes toward the sun. Gated to near-zero cost when the sun is
// behind the camera / below the horizon / off-screen; stronger at low sun and in
// haze. 0.4.4b: STABLE spatial dither (no temporal flicker — was the "jittery"
// screen artifact) + more taps so it no longer draws hard radial lines. Additive
// in HDR (AgX rolls it off); GODRAY_STRENGTH scales it.
#define GOD_RAYS // [GOD_RAYS]

// God-ray strength (GUI slider). 0 = off, 1.0 = tuned default, higher = stronger.
#define GODRAY_STRENGTH 1.0 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00 3.00]

// --- God-ray shaping (internal, not GUI) ----------------------------------
#define AL_GODRAY_SAMPLES   40     // march taps toward the sun (more = smoother)
#define AL_GODRAY_DECAY     0.96   // per-step weight decay (concentrates near sun)
#define AL_GODRAY_INTENSITY 0.42   // base strength (GODRAY_STRENGTH multiplies this)
#define AL_GODRAY_LOWSUN    2.2    // extra multiplier as the sun nears the horizon
#define AL_GODRAY_RAINBOOST 1.6    // extra multiplier in rain/haze

// --- Loom ray WEAVE (internal, not GUI — lib/rays.glsl) --------------------
// The "light-weave" signature: the god-ray shafts are modulated by a slow
// angular interference of two overlapping frequencies around the sun axis, so
// the shafts read as gently interwoven bands rather than a uniform fan. DEPTH
// is subtle (never fully cuts a ray); DRIFT slowly rotates the interference so
// the weave breathes without per-pixel flicker (the shaft march stays stable).
#define AL_RAY_WEAVE_FREQ_A 7.0    // first angular frequency (bands around the sun)
#define AL_RAY_WEAVE_FREQ_B 11.0   // second angular frequency (interference partner)
#define AL_RAY_WEAVE_DEPTH  0.32   // modulation depth (0 = off, 1 = full dark bands)
#define AL_RAY_WEAVE_DRIFT  0.04   // slow angular drift (rad/s) — dreamy, not flicker

// Overall fog density multiplier on top of the tuned sea-level baseline.
// 1.00 is the intended look; lower for crisp long views, higher for a soupier,
// moodier haze.
#define FOG_DENSITY 1.00 // [0.50 0.75 1.00 1.25 1.50 2.00]


/* =========================================================================
   WATER  (Phase 4 — SSR, ripples, absorption, caustics, underwater)
   -------------------------------------------------------------------------
   gbuffers_water draws forward-lit ripple-normalled water AND (new) writes its
   surface into the G-buffer (colortex2 normal+lightmap, colortex3 matID WATER)
   so the new `composite` pass can screen-space reflect and depth-tint it. The
   `composite` pass ALWAYS runs (cheap early-out for non-water pixels): SSR is
   gated INTERNALLY by the SSR toggle so absorption + caustics survive with SSR
   off. Underwater medium (haze + wobble) is a surgical addition to composite2's
   isEyeInWater branch. Internal shaping tunables live at the bottom of this
   section.
   ========================================================================= */

// Screen-space reflections on water/ice surfaces. When on, the composite pass
// raymarches the reflected ray against the depth buffer and blends the hit (or
// a sky-LUT fallback on miss) over the water via Schlick Fresnel. When off, the
// reflection term falls back to the sky sample only (still Fresnel-blended) and
// absorption + caustics still run. POTATO turns this off.
#define SSR // [SSR]

// SSR raymarch quality: 1 = 16 steps, 2 = 24, 3 = 32 (binary-search refined
// either way). Higher = longer, cleaner reflections at more cost. LOW uses 1,
// MEDIUM/HIGH 2, ULTRA 3.
#define SSR_QUALITY 2 // [1 2 3]

// Animated ripple normals on the water surface (2-3 octave wind-aligned
// wave-noise, pure math). Drives both the forward shading and the SSR
// reflection wobble. Cheap, so it stays ON even on POTATO.
#define WATER_WAVES // [WATER_WAVES]

// Animated voronoi caustics on the submerged scene, projected along the sun
// direction and faded with water depth + sky exposure + time of day. POTATO
// turns this off.
#define WATER_CAUSTICS // [WATER_CAUSTICS]

// --- Wave shaping (internal, not GUI) --------------------------------------
// Reworked (0.4.2 field fix — "too uniform, one direction"): the surface is NOT
// a single wind-aligned marching front. It is a SUPERPOSITION of
// AL_WATER_WAVE_COMPONENTS directional sine waves at spread angles (roughly-
// opposing pairs form standing / criss-cross chop, not a front), varied
// frequencies (kmul spread), and DISPERSION-flavoured speeds (long waves travel
// faster: omega = SPEED*sqrt(k)). A very-low-frequency PATCH field rotates +
// reweights the components per lake patch so different areas visibly move
// differently, and a high-frequency 2-warp domain-warped noise MICRO layer adds
// the fine "physical 3D texture", faded out with distance to kill sparkle. The
// big-wave normal is ANALYTIC (one pass, exact gradient — cheaper AND alias-free
// than finite differences); only the micro layer uses central differences.
// 0.4.3 FIELD FIX (ISSUE 10: "water looks like a compact scrolling fabric"): the
// fabric look came from too MANY directional components criss-crossing at a high
// base wavenumber PLUS a strong, high-frequency micro layer that dominated the
// normal. Reworked toward BROAD, multi-directional swells with the micro detail
// demoted to a faint near-surface texture:
//   * fewer components (6 -> 4) so the interference reads as lapping swells, not a
//     dense weave;
//   * lower base wavenumber (0.85 -> 0.42 => ~15-block longest wavelength, broad
//     swells), and the per-component spread below now covers a wider, gentler band;
//   * lower overall amplitude so the surface undulates instead of shattering into
//     high-frequency chop.
#define AL_WATER_WAVE_COMPONENTS 4      // superposed directional waves (>=2 opposing)
#define AL_WATER_WAVE_K          0.42   // base spatial wavenumber (longest wave)
#define AL_WATER_WAVE_SPEED      0.50   // dispersion time-rate (omega = SPEED*sqrt(k))
#define AL_WATER_WAVE_AMP        0.16   // overall normal-perturbation strength (subtle)
#define AL_WATER_NORMAL_EPS      0.14   // micro-layer central-difference step (world m)
// Spatial variation: patch field frequency (very low) + local rotation range.
#define AL_WATER_PATCH_SCALE     0.012  // ~83-block patches move differently
#define AL_WATER_PATCH_ROT       1.6    // radians of local component rotation
// Micro detail (2-warp domain-warped value noise): DEMOTED to a faint, larger-
// scale near-surface shimmer so it can never become the tiled-cloth texture.
// Lower frequency (bigger features), a fraction of the old amplitude, and a much
// shorter fade so it is gone within a few blocks (kills the busy weave + sparkle).
#define AL_WATER_MICRO_SCALE     0.85   // lower freq (~1.2-block wavelength)
#define AL_WATER_MICRO_AMP       0.045  // faint (was 0.16)
#define AL_WATER_MICRO_SPEED     0.90   // off-sync from the big waves
#define AL_WATER_MICRO_FADE      12.0   // blocks; micro gone beyond (anti-sparkle)

// --- Water surface opacity (internal, not GUI) -----------------------------
// Fresnel-driven alpha: the surface is denser looking straight down and near-
// mirror at grazing. The base texture alpha still multiplies this so vanilla
// water density carries. 0.4.2 field fix ("far too see-through"): ALPHA_MIN
// raised 0.55 -> 0.65 so the down-look surface carries meaningfully more water
// COLOUR (denser tint, not a window). The rest of the down-look opacity is
// DEPTH-DRIVEN by the composite absorption below (shallow stays clear, deep goes
// properly opaque blue-green). See the before/after transmission table there.
// 0.4.3 (ISSUE 11: "water too see-through / vanilla texture visible"): ALPHA_MIN
// raised 0.65 -> 0.74 so the down-look surface carries clearly more of its own
// shader colour (denser water, not a window). Deep opacity is still mostly
// DEPTH-driven by the absorption below (shallow shorelines stay readable).
#define AL_WATER_ALPHA_MIN 0.74   // looking down (low Fresnel)
#define AL_WATER_ALPHA_MAX 0.95   // grazing (high Fresnel)

// Shader-driven deep-water surface colour (linear). The vanilla scrolling water
// texture is SUPPRESSED (see gbuffers_water.fsh) and replaced by this identity
// tint modulated by the biome vertex colour, so the surface look is defined by
// reflection + absorption, not the animated atlas. Deep blue-green, dreamy.
const vec3 AL_WATER_TINT = vec3(0.09, 0.19, 0.22);

// --- SSR / reflection (internal, not GUI) ----------------------------------
// F0 for a water/air interface ~0.02. REFLECT_MAX caps grazing Fresnel a touch
// below 1 so water never becomes a hard chrome mirror (dreamy identity).
#define AL_WATER_F0          0.02
#define AL_WATER_REFLECT_MAX 0.90
#define AL_SSR_MAX_DIST      48.0   // total view-space march length (metres)
#define AL_SSR_THICKNESS     1.10   // max surface thickness accepted as a hit (m)
#define AL_SSR_REFINE        5      // binary-search refinement iterations
#define AL_SSR_EDGE_FADE     0.12   // screen-edge reflection fade width (uv)

// --- Absorption (internal, not GUI) ----------------------------------------
// Beer-Lambert tint of the SUBMERGED scene by the water path length between the
// surface (depthtex0) and the opaque behind it (depthtex1). Red is absorbed most
// -> the classic green-blue deepening. The coeffs keep the brief's (0.35,0.12,
// 0.08) COLOUR RATIO (so transmitted stays coloured blue-green, never grey);
// SCALE sets how fast water goes opaque with depth. Applied MULTIPLICATIVELY to
// colortex0 (which already blended the water over the scene), weighted by
// (1-Fresnel) so it reads as depth-dependent water VOLUME — an honest
// approximation (we cannot separate the pre-blended transmitted term).
//   0.4.2 field fix ("far too see-through"): SCALE raised 0.16 -> 0.55 (~3.4x).
//   This is what makes DEEP water read opaque while shallow shoreline stays
//   clear. Effective bottom TRANSMISSION looking straight down (surface factor
//   (1-alpha)(1-fres) ~= 0.534 at ALPHA_MIN 0.65, x per-channel absorb), i.e.
//   opacity = 1 - luminance(T):
//     depth   BEFORE (0.16)            AFTER (0.55)
//      1 blk  T~(.57,.59,.60) op~.42   T~(.44,.50,.51) op~.49
//      3 blk  T~(.51,.57,.58) op~.44   T~(.31,.46,.49) op~.57
//      8 blk  T~(.39,.52,.55) op~.51   T~(.11,.32,.38) op~.72  (dense blue-green)
//   -> deep down-look opacity now ~0.72 (target 0.65-0.75), shallow ~0.49
//   (shorelines read), grazing ~0.95 (reflection dominates). Red is crushed far
//   faster than blue/green, so deep water is COLOURED, not black.
// 0.4.3 (ISSUE 11): SCALE raised 0.55 -> 0.78 so DEEP water goes properly opaque
// blue-green (bottom hidden) while the colour RATIO keeps shallow shorelines clear
// and readable. Red is crushed fastest -> deep water is coloured, never black.
#define AL_WATER_ABSORB       vec3(0.35, 0.12, 0.08)
#define AL_WATER_ABSORB_SCALE 0.78

// --- Caustics (internal, not GUI) ------------------------------------------
// SCALE maps world XZ into the voronoi domain; SPEED is the (slow) animation
// rate; STRENGTH is the max ± modulation of the submerged contribution (~28%);
// DEPTH_FADE is the water-depth (metres) over which caustics fade out (bright in
// the shallows, gone in the deep).
#define AL_CAUSTIC_SCALE      0.32
#define AL_CAUSTIC_SPEED      0.45
#define AL_CAUSTIC_STRENGTH   0.28
#define AL_CAUSTIC_DEPTH_FADE 7.0

// --- Underwater medium (internal, not GUI) ---------------------------------
// composite2's isEyeInWater branch: exponential haze toward a tint, per medium.
// DENSITY is per-metre extinction of the medium (bigger = shorter visibility).
// WATER: pleasant universal blue-green (we have no per-biome water colour at
// composite time — documented approximation). LAVA: dense warm orange-red.
// SNOW: dense soft white. WOBBLE is the underwater UV refraction amplitude.
const vec3 AL_UW_WATER_TINT = vec3(0.055, 0.16, 0.20);
#define AL_UW_WATER_DENSITY 0.075
const vec3 AL_UW_LAVA_TINT  = vec3(0.85, 0.26, 0.05);
#define AL_UW_LAVA_DENSITY  1.30
const vec3 AL_UW_SNOW_TINT  = vec3(0.82, 0.86, 0.94);
#define AL_UW_SNOW_DENSITY  0.85
#define AL_UW_WOBBLE        0.0032


/* =========================================================================
   POST  (bloom + AgX tonemap + auto-exposure — Phase 4)
   -------------------------------------------------------------------------
   Bloom is a threshold-free energy-conserving mip pyramid (composite4 builds a
   6-level tile atlas in colortex9; composite5 sums + mixes it into the scene).
   final then does auto-exposure (mip-average, metered in composite5 and read
   from colortex5.a) -> AgX soft-filmic tonemap (lib/tonemap.glsl) -> biome +
   weather grade (lib/grade.glsl) -> sRGB. The AgX defaults are calibrated so
   the noon/night LEVELS carry over from the old placeholder within ~10%.
   ========================================================================= */

// Master bloom toggle. Also gates the downsample pass itself via
// `program.composite4.enabled = BLOOM` (POTATO off — real perf win). composite5
// still runs for auto-exposure; its bloom-combine is `#ifdef BLOOM` so with
// bloom off the scene passes through untouched.
#define BLOOM // [BLOOM]

// Bloom strength. Scales the scene<->bloom mix weight (energy-conserving lerp).
// 1.0 is the tuned dreamy baseline; higher blooms harder, lower is subtle.
#define BLOOM_STRENGTH 1.0 // [0.5 0.75 1.0 1.25 1.5]

// --- Bloom shaping (internal, not GUI) ------------------------------------
// ADDITIVE bloom weight w in `scene + bloomSum * w`, before BLOOM_STRENGTH.
// Additive (not a crossfade): bright emissives GAIN a soft halo and NOTHING is
// dimmed (the brief's "generous bloom / emissive spill"). bloomSum is a
// normalised weighted average of the 6 levels, so the added energy is bounded;
// AgX's soft highlight rolloff in final absorbs it without clipping. Tuned
// (numeric sim through the AgX path) so a night torch halo gains ~2.1x while a
// noon midtone shifts <2%: scene L=0.18 + bloomSum~0.18 -> +1.7% display; a
// torch-lit dark halo (scene~0.02 + bloomSum~1.0) -> ~2.1x brighter; the torch
// CORE (already saturated) is unchanged. BLOOM_STRENGTH scales this (1.5 ->
// halo ~2.5x, noon ~+2.5%).
#define AL_BLOOM_ADD 0.04

// Exposure user bias. Multiplies the auto-adapted exposure in final (auto
// exposure now does the metering; this is the manual trim on top). 1.0 = no
// trim; the calibration exposure that sets the base levels is AL_AGX_EXPOSURE.
#define EXPOSURE 1.0 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

// --- AgX tonemap (internal, not GUI — edit + hot-reload) ------------------
// Calibration exposure baked into AgX. Tuned (numeric sim vs the outgoing
// placeholder) so mid-grey noon L=0.18 and darker night L=0.05 land within
// ~10% of the old levels. See lib/tonemap.glsl for the full calibration table.
// 0.4.4 ("lighting feels flat"): exposure trimmed 0.98 -> 0.93 (deeper shadows)
// and the slope/power raised for a punchier, higher-contrast midtone so lit vs
// shadowed reads strongly, while AgX still rolls the HDR sun/torches off softly.
#define AL_AGX_EXPOSURE 0.93
#define AL_AGX_SLOPE 1.24
#define AL_AGX_POWER 1.28
// Saturation about luminance (+5% — gentle, per the pack identity).
#define AL_AGX_SAT 1.05
// Warm channel tilt (amber bias carried into the tonemap; subtle).
#define AL_AGX_WARM 0.006

// --- Auto-exposure (internal, not GUI) ------------------------------------
// Mac-path auto-exposure: composite5 meters the deep-mip average scene
// luminance and adapts colortex5.a. Deliberately GENTLE and asymmetric so it
// never undoes the field-approved dark nights (see composite5.fsh for the loop
// design + the composite1 alpha-clobber limitation).
//   KEY       target average luminance (drives KEY/avgLum metering)
//   MIN/MAX   clamp on the metered multiplier. Combined with STRENGTH below the
//             FINAL exposure multiplier is bounded to mix(1,MIN,STRENGTH) ..
//             mix(1,MAX,STRENGTH) = ~[0.90, 1.08] — i.e. auto-exposure can never
//             push the image more than ~10% off the CALIBRATED base level, so
//             the field-approved noon/night levels always carry over (contract
//             §0). It is a gentle correction, not a full metering.
//   STRENGTH  how far toward the metered target vs a neutral 1.0 (subtle)
//   TAU       adaptation time constant (seconds) for the temporal smoothing
//   ADAPT_MIN floor on the per-frame blend rate (keeps metering effective)
// 0.4.4 ("dark areas too light"): tightened the auto-exposure so it can't lift
// caves/night toward daylight (MAX 1.16 -> 1.04, STRENGTH 0.5 -> 0.30).
#define AL_EXPOSURE_KEY 0.26
#define AL_EXPOSURE_MIN 0.80
#define AL_EXPOSURE_MAX 1.04
#define AL_EXPOSURE_STRENGTH 0.30
#define AL_EXPOSURE_TAU 1.0
#define AL_EXPOSURE_ADAPT_MIN 0.35

// Anti-Aliasing MODE. 0 = Off, 1 = FXAA, 2 = TAA.
//   FXAA — fast spatial edge smoothing done on the final tonemapped image (where
//          it actually works); no camera jitter, so NO shimmer. The default.
//   TAA  — jittered temporal accumulation (sharper sub-pixel detail) resolved in
//          composite3 with un-jitter + variance clip. Steadier than raw aliasing
//          but can still crawl slightly on far silhouettes; offered as a choice.
#define AA_MODE 1 // [0 1 2]

// Derived internal flags (do not set directly — driven by AA_MODE).
#if AA_MODE == 2
    #define AL_TAA        // jittered temporal AA path (jitter + composite3 resolve)
#endif
#if AA_MODE == 1
    #define AL_FXAA_ON    // spatial FXAA in final.fsh
#endif

// --- FXAA shaping (internal, not GUI — composite3.fsh) --------------------
// Lottes console-FXAA thresholds. EDGE_MIN/EDGE_MUL gate which luma steps count
// as an edge; REDUCE_* damp the search direction in near-flat areas; SPAN caps
// the blur reach (texels). Defaults are the widely-used values.
// 0.4.9: thresholds lowered + span widened so FXAA visibly smooths more edges.
#define AL_FXAA_EDGE_MIN   0.0156   // ~1/64: catch fainter edges (more smoothing)
#define AL_FXAA_EDGE_MUL   0.0625   // 1/16: lower relative threshold vs local max
#define AL_FXAA_REDUCE_MUL 0.125    // 1/8:  direction reduce (bright-area damping)
#define AL_FXAA_REDUCE_MIN 0.0078   // ~1/128
#define AL_FXAA_SPAN       12.0     // max blur span (texels) — longer edge reach

// --- TAA resolve shaping (internal, not GUI — composite3.fsh) --------------
// Max fraction of the reprojected history kept per frame, scaled by confidence.
// 0.9 = strong smoothing while still reactive (matches the AO history ceiling).
#define AL_TAA_MAX_BLEND      0.9
// Shorter ceiling for the HAND (matID HAND): a fast weapon swing would ghost at
// 0.9, so the first-person hand caps lower and re-converges quickly.
#define AL_TAA_HAND_MAX_BLEND 0.6
// Confidence ramp: added each accepted frame, capped at MAX. A freshly
// disoccluded / newly-revealed pixel starts at STEP and converges over ~1/STEP
// frames (~10) toward full history weight.
#define AL_TAA_CONF_STEP 0.1
#define AL_TAA_CONF_MAX  1.0
// History rejection: relative linear-depth mismatch above this discards the
// reprojected sample. 0.4.9: loosened 0.05 -> 0.10 so history isn't rejected every
// frame on tiny reprojection error (that constant rejection was the "flickers like
// crazy" — the resolve fell back to the raw jittered current each frame).
#define AL_TAA_DEPTH_REJECT 0.10
// Neighbourhood VARIANCE-CLIP width (composite3): history clipped to mean +/- this
// * stddev of the 3x3 YCoCg box (intersected with true min/max). 0.4.9: widened
// 1.0 -> 1.6 so history is preserved (much less flicker) at a little more ghosting.
#define AL_TAA_CLIP_GAMMA 1.6
// Anti-flicker (FXAA / no-jitter) blend ceiling — a touch lower than the TAA
// ceiling so it quiets shimmer without smearing moving foliage/entities.
#define AL_TAA_FXAA_MAX_BLEND 0.75


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
//
// HORIZON-DIAGNOSIS views (0.4.4b — computed in composite2, shown raw):
//   9  SKY MASK        — white = sky pixels (depthtex0 == 1), black = terrain.
//                        Shows EXACTLY where the sky is drawn vs where terrain
//                        occludes it. If a "horizon band" shows over BLACK
//                        (terrain) here, the band is being painted onto terrain.
//   10 FOG AMOUNT      — greyscale fogF (0 clear .. 1 fully fogged) on terrain.
//                        Shows whether fog is what brightens the far field.
//   11 RAW SKY (LUT)   — the atmosphere sky sample along each pixel's view ray,
//                        for the WHOLE screen (ignores depth). Shows the bright
//                        horizon BAND the sky itself produces (the suspected
//                        cause, and why other dimensions show the overworld sky).
#define DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7 8 9 10 11]

/* =========================================================================
   HORIZON DIAGNOSIS TOGGLES (internal, not GUI — edit + hot-reload)
   -------------------------------------------------------------------------
   Flip these ONE AT A TIME (uncomment) to bisect the "horizon visible through /
   in front of terrain" artifact. Each isolates a single suspect; whichever one
   makes the band disappear identifies the cause.
   ========================================================================= */
// composite2: skip aerial fog entirely (is the fog painting the band?).
//#define AL_DBG_NO_FOG
// gbuffers_skybasic: skip the below-horizon haze fill (is the fill the band?).
//#define AL_DBG_NO_SKYFILL
// gbuffers_skybasic: output a FLAT dark grey sky (is the atmosphere sky itself
// the bright horizon band? if the band vanishes with a flat sky, it is the LUT).
//#define AL_DBG_FLATSKY


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
// 0.4.4: lowered ~45% so night open ground reads as moonlit gloom, not lit.
// 5.0.6 FIELD ("night is too dark, can't see anything"): raised ~2.3x so open
// moonlit ground stays clearly readable at night while keeping the cool hue.
const vec3 AL_NIGHT_FLOOR = vec3(0.020, 0.026, 0.048);

// Faint indirect-bounce lift added to the light sum so coloured faces never
// read as pure black. Kept near-neutral (only a whisper cool): this is the ONLY
// light an unlit cave face receives, so any saturation here would tint the cave.
// Field fix #2 wants caves free of a colour cast, so this stays essentially grey.
// 0.4.4 ("enclosed spaces too light / looks like no shader in the dark"): the
// bounce floor is the ONLY light an unlit cave face gets, so it set the cave
// floor brightness. Cut ~65% (0.020 -> 0.006) so caves are genuinely dark and
// torches read as the light source. Still non-zero so coloured faces aren't pure
// black. (BOUNCE_INTENSITY scales it; AO multiplies it.)
// 5.0.6 FIELD ("caves / Nether / no-light areas are too dark, can't see
// anything"): this is the ONLY light a fully-enclosed face receives, so it sets
// the minimum visibility floor in pure darkness. Raised ~6x (0.006 -> 0.036) so
// unlit caves and dark Nether reaches read as a dim, navigable gloom instead of
// pitch black, while still far below torch/daylight so torches remain the light
// source. Near-neutral (whisper cool) to avoid tinting caves. Applies in every
// dimension (part of the shared indirect sum); AO + BOUNCE_INTENSITY scale it.
const vec3 AL_BOUNCE = vec3(0.036, 0.038, 0.048);

/* =========================================================================
   DIMENSIONS (Phase 5 — world-1 Nether, world1 End). Colour identity for the
   per-dimension passes. Programs in shaders/world-1 / shaders/world1 define
   AL_DIM_NETHER / AL_DIM_END before including the shared libs so lib/lighting +
   lib/fog take the right branch. Edit + hot-reload.
   ========================================================================= */
// --- Nether (world-1) ---
// Flat warm-ember ambient (the Nether glows everywhere; no sun, no sky gate).
const vec3 AL_NETHER_AMBIENT = vec3(0.34, 0.13, 0.07);
// Ember fog tint + its half-distance (blocks to ~50% fog). Raised from 26 -> 62
// so the Nether reads atmospheric, not soupy — you can see across a cavern again.
const vec3 AL_NETHER_FOG = vec3(0.24, 0.07, 0.04);
#define AL_NETHER_FOG_HALF 62.0

// --- End (world1) ---
// Cool violet key + purple ambient (the End has no sun). The black-hole sky is
// drawn procedurally in world1/deferred1; these light the terrain.
const vec3 AL_END_KEY     = vec3(0.60, 0.38, 0.92);   // cool violet directional-ish
const vec3 AL_END_AMBIENT = vec3(0.12, 0.075, 0.20);  // low purple fill (moody, darker)
// Purple haze — LESS foggy now (field feedback: more aurora, less fog). Longer
// half-distance so the End reads clear with the aurora as the star, not soup.
const vec3 AL_END_FOG     = vec3(0.13, 0.05, 0.24);   // deep purple in-scatter
#define AL_END_FOG_HALF 150.0

// End procedural space backdrop — a dark purple gradient. LOW = near horizon,
// HIGH = zenith (darker overall).
const vec3 AL_END_SPACE_LOW  = vec3(0.09, 0.030, 0.17);
const vec3 AL_END_SPACE_HIGH = vec3(0.03, 0.012, 0.075);

// Flowing aurora borealis (lib/blackhole.glsl alEndAurora). STR = sky-curtain
// brightness; VEIL = how strongly the same curtains are added over the scene
// (in front of / behind geometry) in world1/composite2, so the aurora is all
// around, not just a distant backdrop.
#define AL_END_AURORA_STR  0.55
#define AL_END_AURORA_VEIL 0.40
// Procedural black-hole apparent size (angular radius multiplier). Small default.
#define END_BLACKHOLE_SIZE 1.0 // [0.50 0.75 1.00 1.50 2.00]

#endif // AL_SETTINGS
