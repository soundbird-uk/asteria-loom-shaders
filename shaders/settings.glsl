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
#define SUN_INTENSITY 1.00 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Cool hemisphere sky-fill (ambient) strength. This is the cool half of the
// pack's signature warm/cool contrast — turn it up for softer shadows.
#define AMBIENT_INTENSITY 1.00 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Warm block-light (torches/lanterns) strength.
#define BLOCKLIGHT_INTENSITY 1.00 // [0.50 0.75 1.00 1.25 1.50 1.75 2.00]

// Colour-temperature ramp on block light: candle-amber near a source fading to
// deep ember-orange at the dim edge of its reach. This is the Mac-path
// approximation of coloured light (true per-source colour is a later phase).
// Off = a single flat warm torch tint.
#define BLOCKLIGHT_TINT // [BLOCKLIGHT_TINT]

/* -------------------------------------------------------------------------
   COLOURED BLOCK LIGHT  (screen-space — deferred2 + colortex13/14)
   -------------------------------------------------------------------------
   Every block light in the pack has so far been the SAME warm constant, so a
   redstone torch, a soul lantern and a pearlescent froglight all washed their
   surroundings the identical amber. This replaces the HUE with a per-pixel
   sampled one: the `deferred2` pass gathers, in a blue-noise-rotated disc
   around each pixel, the (emissive albedo x emission level) of every VISIBLE
   emitter, temporally accumulates it (colortex14) and hands it to
   lib/lighting.glsl as colortex13.

   THE ONE INVARIANT — read before touching any of this: only the HUE comes
   from the gather. The INTENSITY of block light still comes exclusively from
   the vanilla `lm.x` lightmap, whose falloff is computed by the game's own
   flood fill and is therefore already occlusion-correct. That is why light can
   never leak through a wall: a pixel on the far side of a wall from a torch has
   lm.x == 0, so `block = blTint * (blAmt * ...)` is zero no matter what colour
   the screen-space gather thinks it found. Do NOT be tempted to add the
   gathered magnitude as light — that is exactly the propagation problem this
   design deliberately refuses to reinvent (real voxel-propagated colour needs
   the compute/GL4.3 advanced tier the macOS GL4.1 path cannot run).

   Off-screen / unseen emitters simply are not found, and the confidence term
   falls to 0 there, so the tint degrades GRACEFULLY back to the warm constant
   ramp below rather than going grey. That fallback is the whole reason the
   ramp constants are kept.
   ------------------------------------------------------------------------- */

// Master toggle. Also gates the PASS itself via
// `program.deferred2.enabled = COLORED_BLOCKLIGHT` in shaders.properties, so
// turning it off costs literally nothing (the gather never runs and deferred1
// never declares the colortex13 sampler).
#define COLORED_BLOCKLIGHT // [COLORED_BLOCKLIGHT]

// How far the sampled hue is allowed to pull the block-light tint away from the
// warm constant ramp. 0.00 = never (identical to the toggle being off, but the
// pass still runs), 1.00 = the tuned default (a confident emitter fully owns the
// hue), >1 over-drives the confidence ramp so weaker/more distant emitters also
// colour their surroundings.
// NOTE: the default MUST be spelled exactly as one of the list entries below —
// "1.0" against a list containing "1.00" makes Iris render a phantom duplicate
// "Default" entry in the GUI (this pack shipped that bug once already).
#define COLORED_BLOCKLIGHT_STRENGTH 1.00 // [0.00 0.25 0.50 0.75 1.00 1.25 1.50]

// --- Coloured block-light shaping (internal, not GUI) ---------------------
// Disc gather (deferred2.fsh). The buffer is HALF resolution and the hue field
// is inherently low-frequency, so a modest tap count plus the bilinear upsample
// is plenty; raising TAPS costs linearly for very little.
#define AL_CBL_TAPS          16     // taps per pixel on the spiral disc
#define AL_CBL_TURNS         7.0    // spiral turns across the disc (tap spread)
// World-space reach of the gather (blocks). Beyond this an emitter is rejected
// outright: vanilla block light dies at 15 blocks, so a source further away is
// not lighting this pixel and must not colour it.
#define AL_CBL_WORLD_RADIUS  14.0
// Ceiling on the PROJECTED search radius (UV) so a pixel right in front of the
// camera doesn't march a quarter of the screen per tap (same guard as GTAO).
#define AL_CBL_MAX_RADIUS_UV 0.22
// Distance falloff of a found emitter: w = level^2 / (1 + d^2 * FALLOFF).
// Inverse-square flavoured, softened so a torch a few blocks away still counts.
#define AL_CBL_FALLOFF       0.25
// Overall gain on the accumulated gather. Only affects CONFIDENCE (the hue is
// normalised to unit chroma), i.e. how readily a weak/distant emitter wins.
#define AL_CBL_GAIN          8.0
// Confidence ramp on the gather's peak channel: below EPS nothing was found
// (fall back to the constant ramp), at FULL the emitter owns the hue outright.
// EPS is deliberately above the R11F_G11F_B10F denormal floor.
#define AL_CBL_EPS           0.004
// CONFIDENCE MUST NOT RE-ENCODE DISTANCE. This ramp answers one question only —
// "is this a real emitter hue, or noise?" — and it has to saturate just above the
// noise floor. It is NOT a falloff curve: the distance falloff is already owned,
// completely, by the vanilla lm.x lightmap, which is the entire design principle
// of this feature (hue here, intensity there). Setting FULL far above EPS made
// the ramp a second, much steeper falloff stacked on top of lm.x, so the colour
// died about half a block from a redstone torch and everything past that snapped
// back to the warm constant — field-reported, and predicted verbatim by the
// calibration note in the VOXEL section below. FULL is now a small multiple of
// EPS: anything the gather can actually distinguish from nothing is believed.
// Tinting a faint far detection is harmless — out there lm.x has faded to ~0, so
// the block-light term it multiplies is ~0 regardless of its hue.
#define AL_CBL_FULL          0.010
// Range-validation ceiling for the persistent-buffer reads (NaN law).
#define AL_CBL_MAX           65000.0
// Temporal accumulation (colortex14). The hue field is smooth and slow, so a
// high blend is safe and kills the disc's per-frame tap noise outright.
#define AL_CBL_T_BLEND         0.90
#define AL_CBL_T_DEPTH_REJECT  0.05

/* -------------------------------------------------------------------------
   FLOOD-FILL COLOURED VOXEL BLOCK LIGHT  (shadow.gsh + shadowcomp/shadowcomp1)
   -------------------------------------------------------------------------
   The screen-space gather above can only find emitters that are ON SCREEN, so
   a torch behind you or round a corner contributes nothing. This replaces it
   (and falls back to it) with a real 3D light field:

     1. shadow.gsh voxelises every shadow-casting block into a 128x64x128 grid
        centred on the camera, splatting albedo + light level into shadowcolor0.
        It rides the SHADOW pass, so it sees everything within shadowDistance —
        off screen, behind you, round the corner, all of it.
     2. shadowcomp + shadowcomp1 flood-fill that grid: a 6/18/26-neighbour
        gather over the persistent field (shadowcolor1, ping-ponged via its
        own alt buffer — Iris only allocates two shadowcolors), where
        SOLID voxels hold no light and therefore block it. Two steps per frame
        on a field that persists, so it converges in a fraction of a second and
        then tracks the world.
     3. deferred1 samples the field at the shaded point and feeds it into the
        SAME alBlockLightTint() slot the screen-space gather used.

   THE INVARIANT IS UNCHANGED — and it is not negotiable: the field supplies
   HUE and a bounded confidence boost ONLY. The INTENSITY of block light still
   comes exclusively from vanilla's `lm.x` lightmap, which is occlusion-correct
   by construction (the game's own flood fill computed it). This 1-metre
   diffusion approximation would leak through thin walls if it were used as
   radiance; as a hue behind lm.x it physically cannot, because lm.x is 0 on the
   far side of the wall and zero times any colour is zero.

   COST / COMPATIBILITY NOTES, read before enabling on a low preset:
     * It reserves a 2048x512 strip of the shadow buffer for the voxel atlas
       (see lib/voxel.glsl), which SHRINKS the shadow map to
       (shadowMapResolution - 512)^2. At 2048 that is 1536^2, at 3072 2560^2.
       Below shadowMapResolution 2048 the atlas no longer fits and the field is
       only partially populated (it degrades to the screen-space fallback, it
       does not break) — which is why POTATO/LOW ship with this OFF.
     * The shadow pass gains a geometry shader. shadow.gsh is present in the
       pack whether or not this option is on (Iris compiles every stage file it
       finds); with the option off it is a pure pass-through that emits the
       input triangle unchanged.
   ------------------------------------------------------------------------- */

// Master toggle. Also gates the propagation PASSES via
// `program.shadowcomp.enabled` / `program.shadowcomp1.enabled` in
// shaders.properties, and compiles the voxelisation splat out of shadow.gsh,
// so with it off the only residue is a pass-through geometry stage.
// (Default ON because settings.glsl defaults are contractually the MEDIUM
// profile's values and MEDIUM enables it. If field testing shows the geometry
// stage is a problem on some driver, flipping this to `//#define` is the
// one-character kill switch for anyone who has not picked a preset.)
#define VOXEL_LIGHT // [VOXEL_LIGHT]

// How readily the voxel field's hue wins over the warm constant ramp. This is a
// gain on the field's MAGNITUDE, which is what drives the confidence ramp in
// lib/lighting.glsl — it does not (and must not) brighten anything, because the
// hue is normalised to unit chroma before use. 0.00 = the field never wins
// (identical to the toggle being off, but the passes still run).
// NOTE: the default MUST be spelled exactly as one of the list entries — "1.0"
// against a list containing "1.00" makes Iris render a phantom duplicate
// "Default" entry in the GUI (this pack shipped that bug once already).
#define VOXEL_LIGHT_STRENGTH 1.00 // [0.00 0.25 0.50 0.75 1.00 1.25 1.50 2.00]

// Propagation kernel per flood-fill step:
//   1 = 6 face neighbours            (cheapest; propagation is a little boxy)
//   2 = 6 faces + 12 edge diagonals  (rounder spread)
//   3 = all 26 neighbours            (roundest; ~4x the taps of tier 1)
// Diagonal taps are weighted 1/sqrt(2) and 1/sqrt(3) so the kernel approximates
// an isotropic diffusion rather than over-weighting the corners.
#define VOXEL_LIGHT_QUALITY 1 // [1 2 3]

// --- Voxel-light shaping (internal, not GUI) ------------------------------
// Per-step retention of the diffusion. 1.0 is the discrete harmonic solution
// (light falls off ~1/r from a source, the physically sensible answer); slightly
// under 1.0 adds an exponential cutoff so a bright source cannot fill the whole
// 128-block grid with its hue. Two steps run per frame, so the field converges
// over roughly (reach / 2) frames and then simply tracks the world.
#define AL_VOXEL_SPREAD 0.965
// Radiance a level-15 emitter injects into its own voxel. Arbitrary units — only
// the RATIO between emitters and the AL_VOXEL_GATHER_GAIN below matter, because
// the consumer normalises to unit chroma.
#define AL_VOXEL_EMIT 1.0
// Emission response curve. Vanilla light level is linear in "blocks of reach",
// so a level-7 source is far more than half as visually present as a level-15
// one; squaring would make dim sources vanish. Kept mildly super-linear so
// glowstone still beats a sculk vein when both are in range.
#define AL_VOXEL_EMIT_POW 1.4
// Maps the field into the SAME units the screen-space gather uses, so the single
// confidence ramp in lib/lighting.glsl (AL_CBL_EPS .. AL_CBL_FULL) serves both
// paths and the two never disagree about how confident "confident" is.
// Calibration: a diffusion at steady state around a unit source falls off close
// to 0.16/r, so the field reads ~0.16 one block from a torch, ~0.04 at four
// blocks and ~0.016 at ten. The confidence ramp saturates at AL_CBL_FULL (0.05),
// so a gain of 2.5 puts FULL confidence out to roughly five blocks and keeps
// partial confidence to the edge of a light's vanilla 15-block reach — beyond
// which lm.x has faded to nothing anyway and the hue is moot. Over-gaining here
// is safe by construction (confidence is clamped and the hue is unit-chroma
// normalised, so it can never brighten anything); under-gaining is not, because
// it silently reverts the whole feature to the warm ramp a metre from a torch.
#define AL_VOXEL_GATHER_GAIN 2.5
// How far along the surface normal the consumer steps before sampling. A lit
// surface's OWN voxel is solid and by construction holds no light, so the sample
// must be taken in the air voxel in front of it. 0.6 clears the boundary by a
// comfortable margin without skipping the adjacent voxel entirely.
#define AL_VOXEL_NORMAL_STEP 0.6

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
#define NIGHT_BRIGHTNESS 1.00 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

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
#define BOUNCE_INTENSITY 1.00 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00]


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

// --- AO spatial denoise (bilateral, deterministic) ------------------------
// GTAO's slice/step jitter leaves per-pixel noise even after temporal
// accumulation (reprojection error at distance rejects history and falls back
// to the noisy current frame). A depth-aware bilateral blur run at read time
// removes that grain deterministically — no motion, no flicker, no distance
// jitter. Radius in texels of the (half-res) AO buffer; the kernel is a
// separable-style box of (2*R+1)^2 taps with a Gaussian spatial falloff.
#define AL_AO_DENOISE            // comment out to disable the bilateral pass
#define AL_AO_DENOISE_RADIUS 2   // 2 -> 5x5 kernel (25 taps)
// Spatial Gaussian sigma (texels). Larger = smoother, softer edges.
#define AL_AO_DENOISE_SIGMA 2.0
// Depth edge stopping: a neighbour is down-weighted by
// exp(-(dLinear/center)^2 / DEPTHK^2). Smaller = sharper depth edges kept.
#define AL_AO_DENOISE_DEPTHK 0.06
// Normal edge stopping: neighbours facing away are rejected below this dot so
// the blur never bleeds AO across a crease/corner.
#define AL_AO_DENOISE_NORMALK 0.86

// --- SHADOW temporal accumulation (5.3.0, colortex11) ---------------------
// PCSS/PCF filters a stochastic Vogel disc: the penumbra is the AVERAGE of a
// handful of randomly rotated taps, so a single frame of it is grainy at every
// soft shadow edge (the "fuzzy noisy texture" in the field report). Increasing
// SHADOW_SAMPLES is the brute-force fix and costs linearly; accumulating the
// SAME taps over time is free by comparison and converges to the true penumbra.
// deferred1 reprojects the previous frame's resolved visibility (colortex11) and
// blends, while lib/shadow.glsl advances the per-pixel Vogel rotation every frame
// (AL_SHADOW_ANIMATE) so each frame contributes NEW taps rather than repeating
// the same ones.
//   MAX_BLEND    — history ceiling (0.88 => ~8-frame effective average).
//   CONF_STEP    — disocclusion re-convergence rate.
//   DEPTH_REJECT — relative eye-depth mismatch that discards history.
//   CLAMP        — the history is additionally clamped to the current frame's
//                  value +/- this. It is wider than the tap noise (so the noise
//                  still averages away) but tight enough that a moving occluder
//                  cannot drag a stale shadow along behind it (ghosting).
#define AL_SHADOW_TEMPORAL
#define AL_SHADOW_T_MAX_BLEND    0.88
#define AL_SHADOW_T_CONF_STEP    0.16
#define AL_SHADOW_T_DEPTH_REJECT 0.05
#define AL_SHADOW_T_CLAMP        0.45


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
#define VC_COVERAGE 0.55 // [0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70]

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
// 5.1.1 ("more, smaller, thicker candy-floss clouds; less sparse; not one huge
// blob at high coverage"): the old 0.00028 scale made noise cells ~3.5k blocks
// wide, so the visible sky spanned barely one cell -> either empty or a single
// giant cloud. Tripled the frequency so many distinct puffs fill the sky, +1 FBM
// octave for finer clumping. (Wind speed is raised in step below to keep the drift
// rate the same, since world drift = WIND_SPEED / COVERAGE_SCALE.)
#define AL_CLOUD_COVERAGE_SCALE   0.00090 // world XZ -> noise domain (smaller clouds)
#define AL_CLOUD_COVERAGE_OCTAVES 5       // FBM octaves for the coverage map
// Base coverage drift in NOISE units/sec, before the CLOUD_SPEED slider. World
// drift = AL_CLOUD_WIND_SPEED * CLOUD_SPEED / AL_CLOUD_COVERAGE_SCALE blocks/sec
// => 0.008 * 1.0 / 0.00028 ≈ 29 blocks/s at the default (a gentle dreamy roll).
// This is ~44x slower than the 0.3.1 default (0.35) that field-tested "WAY too
// fast"; the slider restores brisker motion for those who want it.
#define AL_CLOUD_WIND_SPEED       0.024   // coverage drift (noise units / sec) —
                                          // raised with the finer scale so the
                                          // world drift speed stays ~29 blocks/s
#define AL_CLOUD_STORM_BOOST      0.22    // extra coverage added at full rain

// --- Cumulus 3D shaping -----------------------------------------------------
#define AL_CLOUD_DETAIL_SCALE   0.006  // 3D erosion-noise frequency
#define AL_CLOUD_DETAIL_OCTAVES 3      // 3D FBM octaves (billow erosion)
#define AL_CLOUD_EDGE           0.24   // coverage->density remap softness (crisper puffs)
#define AL_CLOUD_BOTTOM_ROUND   0.18   // flat-ish base rise (first 18% of slab)
#define AL_CLOUD_TOP_ROUND      0.55   // billowy top erodes over the upper 45%
#define AL_CLOUD_EROSION        0.60   // how hard detail carves cloud edges (cauliflower)
#define AL_CLOUD_DENSITY        1.75   // overall optical density (thicker candy-floss)
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
#define SKY_BRIGHTNESS 1.00 // [0.50 0.75 1.00 1.25 1.50 2.00]

// HDR boost applied to the MOON texture (and any custom sky textures) so it
// reads through the tonemap and blooms later. NOTE: MOON-ONLY now — the vanilla
// sun texture is discarded and replaced by the procedural sun disc below
// (SUN_DISC_BRIGHTNESS), so this no longer affects the sun.
#define SUNMOON_BRIGHTNESS 3.0 // [1.0 2.0 3.0 4.0 6.0]

// Mie (haze/aerosol) scattering strength. Higher = a brighter, hazier white
// glow around the sun and a milkier horizon band.
#define MIE_STRENGTH 1.00 // [0.25 0.50 0.75 1.00 1.50 2.00 3.00]

// Atmospheric turbidity. Higher = dustier air: warmer, redder sun and a
// thicker, more washed-out horizon.
#define TURBIDITY 1.00 // [0.50 0.75 1.00 1.50 2.00 3.00]

// Procedural sun-disc angular size, multiplying AL_SUN_ANGULAR_RADIUS. 1.0 is
// the pack's deliberately soft, dreamy sun; lower is a tighter, sharper disc.
#define SUN_DISC_SIZE 1.00 // [0.50 0.75 1.00 1.50 2.00 3.00]

// Procedural sun-disc HDR brightness. High values bloom hard once bloom lands
// in Phase 4; the placeholder tonemap keeps them from clipping now.
#define SUN_DISC_BRIGHTNESS 2.00 // [0.50 1.00 2.00 4.00 8.00 16.00]

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
#define GODRAY_STRENGTH 1.00 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00 3.00]

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

// Overall fog density multiplier on top of the tuned sea-level baseline. Scales
// the mid-field aerial HAZE (the atmospheric depth you see across the landscape).
// 1.00 is the intended look; lower for crisp long views, higher for a soupier,
// moodier haze. Does NOT affect the render-edge wall (that has its own controls).
#define FOG_DENSITY 1.00 // [0.00 0.50 0.75 1.00 1.25 1.50 2.00]

// --- Render-edge fog wall (the new distance-fog system) --------------------
// The far fog has two GUI-tunable stages, both measured in CHUNKS before the
// render-distance edge (so they mean the same thing at any render distance):
//   FOG_WALL_CHUNKS  — the last N chunks are a SOLID grey fog wall that fully
//                      hides the unrendered-chunk dropoff into the void. 0 = no
//                      wall (edge left open). Raise for a thicker seal.
//   FOG_START_CHUNKS — the patchy, uneven fog begins building this many chunks
//                      before the edge and ramps up to the wall. Larger = the
//                      distance hazes over sooner / more gradually.
// FOG_START_CHUNKS is always treated as at least (wall + 1) internally so the
// patchy ramp can never sit inside or behind the wall.
#define FOG_WALL_CHUNKS  3.0 // [0.0 1.0 1.5 2.0 2.5 3.0 4.0 5.0]
#define FOG_START_CHUNKS 6.5 // [3.0 4.5 5.0 6.5 8.0 10.0 12.0 16.0]

// How uneven/patchy the far fog builds before the wall (0 = smooth radial ramp,
// 1 = strongly broken into real-looking banks). Cosmetic; tune to taste.
#define FOG_PATCHINESS 1.0 // [0.0 0.25 0.5 0.75 1.0 1.5]


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

// Gerstner wave DISPLACEMENT + ripple normals on the water surface (lib/water.glsl,
// pure math). Drives the vertex swells, the shaded normal and the SSR reflection
// wobble. Cheap enough to stay ON even on POTATO (the wave COUNT scales below).
#define WATER_WAVES // [WATER_WAVES]

// Wave quality = number of summed Gerstner waves (golden-angle spaced, so they
// never repeat). 1=4 waves (fastest) .. 5=12 waves (richest swell detail). This is
// the main water perf/quality dial the presets scale.
#define WATER_WAVE_QUALITY 4 // [1 2 3 4 5]
#if   WATER_WAVE_QUALITY == 1
    #define AL_WATER_WAVE_N 4
#elif WATER_WAVE_QUALITY == 2
    #define AL_WATER_WAVE_N 6
#elif WATER_WAVE_QUALITY == 3
    #define AL_WATER_WAVE_N 8
#elif WATER_WAVE_QUALITY == 4
    #define AL_WATER_WAVE_N 10
#else
    #define AL_WATER_WAVE_N 12
#endif

// Dynamic FOAM: Jacobian crest foam (white foam where wave crests pinch/fold over,
// determinant J < 0) + depth-buffer CONTACT foam (soft shoreline foam where water
// meets blocks). Off on POTATO/LOW.
#define WATER_FOAM // [WATER_FOAM]

// Overall water ABSORPTION strength (Beer-Lambert extinction scale). Higher makes
// water go opaque/navy faster with depth; lower keeps it clearer/teal for longer.
#define WATER_ABSORPTION 1.00 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

// SHORELINE SWELL ATTENUATION: how deep the water must be (blocks) before the big
// ocean swells reach FULL height. Below this, large low-frequency waves fade out so
// beaches/shallows stay calm; the fine capillary ripples are always kept so shallow
// water never reads as flat glass. Depth is read from the scene depth buffer
// (gbuffers_water.vsh) per water vertex. Larger = swells only build far offshore.
#define COAST_SWELL_DISTANCE 20.0 // [5.0 10.0 15.0 20.0 30.0 40.0 50.0]

// Animated voronoi caustics on the submerged scene, projected along the sun
// direction and faded with water depth + sky exposure + time of day. POTATO
// turns this off.
#define WATER_CAUSTICS // [WATER_CAUSTICS]

// --- Reflective solid blocks (5.0.9) ---------------------------------------
// Screen-space reflections on smooth SOLID blocks, MATERIAL-DEPENDENT (tagged in
// block.properties): metals (iron/gold/copper/netherite/diamond/emerald) reflect
// strongly and tint the reflection with their own colour; ice (packed/blue and
// regular) and polished stones stay glassy — subtle head-on, reflective at grazing
// (Fresnel). Reuses the water SSR raymarch (composite) against depthtex0, with a
// sky-access gate so indoor blocks don't reflect bright sky. Master toggle:
#define REFLECTIVE_BLOCKS // [REFLECTIVE_BLOCKS]

// Overall reflection strength for blocks. 1.0 = tuned default.
#define REFLECTIVE_STRENGTH 1.00 // [0.25 0.50 0.75 1.00 1.50]

// Per-class base reflectivity (internal, not GUI). Glassy = ice / polished stone;
// Metal = the metal block set. REFLECTIVE_STRENGTH scales both.
#define AL_REFLECT_ICE   0.55   // glassy dielectric (Fresnel-shaped in composite)
#define AL_REFLECT_METAL 0.55   // ROUGH metal (was 0.90 = chrome); albedo-tinted
// 5.2.0 PBR roughness: iron/gold blocks are ROUGH metal, not mirrors. Roughness
// blurs the environment reflection toward the soft zenith ambient and weights DOWN
// the sharp SSR contribution, so metal reads as brushed metal, never chrome.
#define AL_REFL_ROUGH_METAL      0.62
#define AL_REFL_ROUGH_DIELECTRIC 0.12
// 5.3.0 full micro-facet (GGX) reflection — see lib/pbr.glsl.
//   F0_DIELECTRIC — achromatic normal-incidence reflectance for non-metals
//                   (0.04 is the physical value for most dielectrics). The old
//                   code used 0.04..0.75 lerped by metalness, which is NOT how
//                   metals work: a metal's F0 IS its albedo, so iron got a flat
//                   0.75 grey mirror = the chrome look in the field report.
//   METAL_DIFFUSE — how much of the forward-lit diffuse a metal keeps. Physically
//                   a metal has NO diffuse lobe, but killing it outright makes an
//                   unlit indoor iron block read as a black hole, so a small
//                   fraction is retained (documented deviation).
//   SSR_MAX_ROUGH — above this roughness the sharp screen-space reflection is
//                   dropped entirely; only the (blurred) environment remains.
#define AL_REFL_F0_DIELECTRIC 0.04
#define AL_REFL_METAL_DIFFUSE 0.45
// Environment a reflective block sees with NO sky access (caves, interiors):
// this fraction of its own forward-lit colour. See composite.fsh for why a metal
// cannot simply be given a black environment there.
#define AL_REFL_INDOOR_ENV    0.80
#define AL_REFL_SSR_MAX_ROUGH 0.80

// Portals get water-like SSR reflections too (composite reflective path, gated by
// REFLECTIVE_BLOCKS). Dielectric (metalness 0) -> Fresnel-shaped, deep reflections.
#define AL_NETHER_PORTAL_REFLECT 0.55
#define AL_END_PORTAL_REFLECT    0.45

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
// --- Gerstner wave shaping (internal, not GUI) -----------------------------
// 5.1.0 OVERHAUL: a golden-angle Gerstner spectrum (lib/water.glsl). WAVE_N (the
// count) is set by the GUI WATER_WAVE_QUALITY above. These shape the spectrum:
//   K        — base wavenumber of the LONGEST swell (2pi/wavelength; 0.36 ~ 17 blk)
//   WAVE_GAIN— geometric frequency step per wave (each wave ~1.28x higher freq)
//   AMP      — base amplitude (world metres) of the longest swell (vertex swell)
//   AMP_GAIN — amplitude falloff per wave (shorter waves are smaller)
//   SPEED    — dispersion rate (omega = SPEED*sqrt(k); long waves travel faster)
//   STEEPNESS— crest-pinch: higher sharpens crests / broadens troughs (0..1-ish;
//              auto-bounded per wave by 1/(k*N) so the surface never self-loops)
#define AL_WATER_WAVE_K       0.28   // base wavenumber (2pi/lambda); 0.28 ~ 22-block swell
#define AL_WATER_WAVE_GAIN    1.28
#define AL_WATER_WAVE_AMP     0.148  // base swell amplitude (world metres); 0.148 = ocean feel
#define AL_WATER_AMP_GAIN     0.80   // gentler amplitude decay per octave so short chop < long swells
#define AL_WATER_WAVE_SPEED   0.68   // dispersion rate; faster for long open-water swells
#define AL_WATER_STEEPNESS    3.8    // crest-pinch (bounded per-wave; higher = sharper whitecap tops
                                     // without self-loop; Jacobian dips more -> more crest foam)
// SHORELINE SAFETY: Gerstner also pulls vertices HORIZONTALLY, which can drag a
// water vertex away from the solid block beside it and open a seam/void at the
// shore. We can't detect neighbours in a vertex shader, so we DAMP the horizontal
// pull to a small fraction (the vertical swell + the analytic normal carry the
// look). At 0.35 any shore gap is < ~0.08 block — invisible — while crests still
// pinch. The FRAGMENT normal/Jacobian keep the FULL steepness (shading is
// unaffected). Set to 0.0 for zero horizontal motion (no gaps at all).
#define AL_WATER_HORIZ_DAMP   0.35
// Distant-normal flatten (anti-sparkle): fade the surface normal toward flat over
// this block range so far crests don't alias into shimmer under FXAA. A..B blocks,
// MAXFLAT = how far toward flat at the far end.
#define AL_WATER_NORMAL_FADE_A 55.0
#define AL_WATER_NORMAL_FADE_B 150.0
#define AL_WATER_NORMAL_MAXFLAT 0.6

// Micro-ripple normal (domain-warped 3D simplex — capillary waves / wind gusts).
//   SCALE — world frequency of the fine ripples (~0.9 => sub-block detail)
//   AMP   — how much the micro slope tilts the surface normal
//   SPEED — evolution rate through the noise's time axis (off-sync from swells)
//   WARP  — domain-warp strength (breaks any grid so ripples read organic)
//   FADE  — blocks over which the micro layer fades out (anti-sparkle at range)
#define AL_WATER_MICRO_SCALE  0.90
#define AL_WATER_MICRO_AMP    0.13   // stronger capillary-ripple tilt for visible fine texture
#define AL_WATER_MICRO_SPEED  0.80
#define AL_WATER_MICRO_WARP   0.70   // stronger warp = more organic, non-grid micro ripples
#define AL_WATER_MICRO_FADE   32.0   // micro detail visible from noticeably further away (was 26)

// --- Footprint normal anti-aliasing (fixes the "grid grain" on water) -------
// The ripple normal is high-frequency world-space detail. When a single screen
// pixel spans more than a ripple wavelength — looking ACROSS water from above,
// or at any distance — those ripples fall below Nyquist and ALIAS against the
// pixel grid. That aliased normal then scatters BOTH the reflected direction and
// the refraction UV per pixel, which is the dark grainy grid on water from above.
// fwidth(waterRefXZ) measures that per-pixel footprint (world units/px); the fine
// normal detail is faded out analytically where it would alias, so the surface
// smooths to calm exactly where the grain used to be. Deterministic — no dither,
// no history — so it cannot grain or crawl. Higher K = flatten sooner.
#define AL_WATER_AA_MICRO_K   1.60   // footprint fade rate for the fine ripples
#define AL_WATER_AA_FLAT_K    0.16   // footprint-driven flatten of the whole normal
#define AL_WATER_AA_MAXFLAT   0.85   // ceiling on that footprint flatten (0..1)

// --- Foam (internal, not GUI; master toggle is WATER_FOAM) -----------------
//   JAC_LO/HI — Jacobian range mapped to crest-foam amount: foam ramps in as J
//               drops from HI toward LO. Textbook whitecaps trigger at J<0 (fully
//               folded crests), but stable block-grid water keeps J>0 (crests
//               sharpen without inverting), so the threshold sits just under 1.0 to
//               catch the SHARPEST ~5-15% of crests as sparse whitecaps.
//   CONTACT   — shoreline foam thickness: water within this many blocks (depth)
//               of the terrain behind it foams.
//   COLOR     — foam albedo (linear).
#define AL_WATER_FOAM_JAC_HI   0.975  // foam begins at sharper crests (was 0.985)
#define AL_WATER_FOAM_JAC_LO   0.870  // foam full at heavily-folded crests (was 0.900)
#define AL_WATER_FOAM_CONTACT  0.55   // narrower shore band (0.55 blocks); was 0.85 which read as a painted ring
const vec3 AL_WATER_FOAM_COLOR = vec3(0.90, 0.94, 0.97);  // more white, less blue-tinted foam
// 5.1.2 foam tone: contact (shoreline) foam was too white/jarring and never
// darkened at night. STR caps its strength; NIGHT is its brightness floor at night
// (both crest + contact foam are lit by day factor so they read moonlit-grey after
// dark instead of glowing white).
#define AL_WATER_FOAM_CONTACT_STR 0.82  // stronger but narrower = crisp shoreline foam (was 0.65)
#define AL_WATER_FOAM_NIGHT       0.14
// 5.2.0 whispy fractal foam: a multi-octave domain-warped simplex mask breaks both
// the crest and shoreline foam into chaotic, filamentary whiskers instead of a
// uniform white band. SCALE = world frequency, WARP = domain-warp strength.
#define AL_WATER_FOAM_SCALE 1.15  // finer noise frequency -> less "tiled texture" look (was 0.85)
#define AL_WATER_FOAM_WARP  1.55  // stronger coarse domain warp = bigger organic tongues (was 1.30)
// 5.3.0 WHISKER foam: the 3-octave warped field above still read as a soft,
// uniform gradient band because it was used as a plain MULTIPLIER. The mask is
// now built from RIDGED octaves (1 - |simplex|), which produce filaments rather
// than blobs, and is applied as an EROSION THRESHOLD: foam only survives where
// (drive * noise) clears the threshold, so the band's own edge is chewed into
// broken whiskers instead of fading out evenly.
//   OCTAVES   — ridged octaves in the fractal sum.
//   WARP2     — second-stage domain warp (finer, counter-rotated) = whiskers.
//   ERODE_LO/HI — the erosion smoothstep window applied to (drive * mask).
//   FIL       — extra high-frequency filament gain near the erosion edge.
#define AL_WATER_FOAM_OCTAVES  5     // one extra ridged octave for finer filament branching (was 4)
#define AL_WATER_FOAM_WARP2    0.95  // stronger fine warp = more hair-like whisker tips (was 0.65)
#define AL_WATER_FOAM_ERODE_LO 0.24  // more aggressive erosion threshold (was 0.18) -> more holes/gaps
#define AL_WATER_FOAM_ERODE_HI 0.72  // wider erosion window for gradual filament edges (was 0.62)
#define AL_WATER_FOAM_FIL      0.75  // stronger filament gain at torn edges (was 0.55)

// --- Reflection: occluded-horizon fix + sun glint (5.1.2) ------------------
// Near-horizontal reflected rays are almost always occluded by shore terrain /
// mountains, but the sky LUT has a bright horizon band there that SSR-misses paint
// onto the water as a jarring bright line. Fade the reflected SKY toward a dark
// water tone as the reflected ray nears the horizon (Rw.y in LO..HI); only up-
// pointing rays show real sky. SSR still overrides with real on-screen geometry.
#define AL_WATER_REFL_HORIZON_LO 0.00
#define AL_WATER_REFL_HORIZON_HI 0.22
// 5.2.0: this is the reflection an occluded/downward ray returns. It was near-black,
// which — combined with sharp wave normals scattering rays every direction from an
// overhead view — produced the griddy DARK PATCHES on water (image_6af8bc). Set to a
// dim WATER tone so misses/downward rays read as the water reflecting itself, never
// a black hole; SSR still overrides with real on-screen geometry.
const vec3 AL_WATER_REFL_OCCLUDED = vec3(0.050, 0.100, 0.140);
// --- SSR IN-FILL (5.3.0) ---------------------------------------------------
// A screen-space ray can only ever hit what is ON SCREEN. From an overhead view
// the sharp Gerstner crests scatter rays toward geometry that is off-screen or
// behind the camera, so a large fraction of pixels MISS — and every miss used to
// fall back to a near-black occluded tone, printing the dark, uniform grainy
// GRID over the water in image_6af8bc.jpg.
// The in-fill replaces "miss => dark" with "miss => a plausible reflection":
//   * up-pointing rays          -> the real sky LUT sample,
//   * horizon / downward rays   -> the water's own depth-tinted body colour
//                                  (deep = the absorbed ocean tone, shallow =
//                                  brighter), lifted by the sky lightmap,
// blended by the horizon ramp above. FLOOR is a hard lower bound on the in-fill
// luminance scale so no ray direction can ever resolve to black.
//   BODY_K   — how much of the sky's own brightness the body tone borrows.
//   FLOOR    — minimum in-fill scale (never 0 => never a black patch).
//   HIT_SOFT — how softly a partial/edge-faded SSR hit crossfades into the
//              in-fill, so hit and miss neighbours cannot form a hard grid.
#define AL_WATER_INFILL_BODY_K 0.55
#define AL_WATER_INFILL_FLOOR  0.22
#define AL_WATER_INFILL_SOFT   0.35
// Analytic SUN GLINT (the sun disc isn't in the depth buffer, so SSR can't reflect
// it): a tight specular toward the sun so water sparkles with the sun/moon.
#define AL_WATER_SUN_SPEC     9.0
#define AL_WATER_SUN_SPEC_POW 500.0

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
#define AL_SSR_MAX_DIST      64.0   // longer SSR reach for more complete reflections (was 48)
#define AL_SSR_THICKNESS     0.90   // tighter hit tolerance = fewer false positives (was 1.10)
#define AL_SSR_REFINE        5      // binary-search refinement iterations
#define AL_SSR_EDGE_FADE     0.12   // screen-edge reflection fade width (uv)
// GLOSSY reflection pre-filter (deterministic grain fix). The SSR hit colour is
// averaged over a small screen-space kernel around the hit so the per-pixel
// divergence from micro-ripple normals + the frozen dither (which read as the
// "grid grain" on water viewed from above) is smoothed into a soft gloss. The
// radius grows with view distance because far water sub-tends fewer pixels, so
// the same world-space ripples alias into a tighter, harsher grid there.
#define AL_SSR_GLOSS_TAPS    10      // more ring taps for smoother glossy average (was 8)
#define AL_SSR_GLOSS_RADIUS  1.6     // base kernel radius (texels of colortex0)
#define AL_SSR_GLOSS_DISTK   0.04    // extra radius per metre of view distance

// --- SSR ray hygiene (5.3.0) ----------------------------------------------
// NORMAL_BIAS: the march starts this far ALONG THE SURFACE NORMAL (metres,
// scaled with view distance) so a ray leaving a surface cannot immediately
// re-intersect the very pixel it came from. Self-intersection is what let a
// near-horizontal ray "hit" the surface it started on and paste the bright sky
// horizon band INSIDE the block (field report: "a horizon bar reflected within
// the block, as if looking through it").
// MIN_DOT: a reflected ray whose direction points INTO the surface (dot with the
// normal <= this) is geometrically impossible; reject before marching instead of
// letting it wander behind the geometry and return an arbitrary depth hit.
#define AL_SSR_NORMAL_BIAS   0.06
#define AL_SSR_NORMAL_DISTK  0.015
#define AL_SSR_MIN_DOT       0.02

// --- SSR TEMPORAL ACCUMULATION (5.3.0, colortex10) -------------------------
// SSR is a stochastic, per-pixel process (dithered ray start + per-pixel ripple
// normals), so a SINGLE frame of it is inherently noisy — no purely spatial
// filter can remove that without destroying the reflection. The fix is temporal:
// reproject the previous frame's resolved reflection through the motion vector
// (lib/space.glsl alMotionVector) and accumulate.
//   MAX_BLEND    — history ceiling (0.92 => ~12-frame effective average).
//   CONF_STEP    — how fast a freshly disoccluded pixel earns that ceiling. The
//                  earned confidence lives in colortex12 (R8) and rises one step
//                  per consecutively accepted frame, so a pixel that just came
//                  into view converges over ~7 frames instead of locking onto a
//                  single noisy one. Same mechanism as the shadow history.
//   DEPTH_REJECT — relative eye-depth disagreement that rejects history.
//   CLIP_GAMMA   — the accumulated history is clipped to mean +/- gamma*sigma of
//                  the CURRENT frame's glossy ring taps (the same statistical
//                  clip composite3's TAA uses). This is what keeps the result
//                  SHARP and ghost-free rather than a temporal blur: history is
//                  only trusted while it agrees with the local reflection
//                  distribution measured this frame.
#define AL_SSR_TEMPORAL
#define AL_SSR_T_MAX_BLEND    0.92
#define AL_SSR_T_CONF_STEP    0.14
#define AL_SSR_T_DEPTH_REJECT 0.05
#define AL_SSR_T_CLIP_GAMMA   1.35
// Screen-space REFRACTION: how far (uv) the water normal bends the submerged scene
// sample. Subtle + distance-faded so the seabed wobbles under the surface without
// tearing. (5.1.0 water overhaul.)
#define AL_WATER_REFRACT     0.022  // moderately reduced UV offset (was 0.028); less "rubber-glass" warp

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
   Bloom is a threshold-free energy-conserving REAL dual-filter pyramid: a
   progressive downsample (composite4..composite9 build the 6-level tile atlas in
   colortex9, each level from the PREVIOUS level) then a tent-cascade upsample
   (composite10..composite13) whose final level-1 tent+add is folded into the
   scene by the combine pass composite14 (layout + kernels in lib/bloom.glsl).
   final then does auto-exposure (mip-average, metered in composite14 and read
   from colortex5.a) -> AgX soft-filmic tonemap (lib/tonemap.glsl) -> biome +
   weather grade (lib/grade.glsl) -> sRGB. The AgX defaults are calibrated so
   the noon/night LEVELS carry over from the old placeholder within ~10%.
   ========================================================================= */

// Master bloom toggle. Also gates the downsample/upsample passes themselves via
// `program.composite4..composite13.enabled = BLOOM` (POTATO off — real perf
// win). The combine pass composite14 still runs for auto-exposure; its
// bloom-combine is `#ifdef BLOOM` so with bloom off the scene passes through
// untouched.
#define BLOOM // [BLOOM]

// Bloom strength. Scales the scene<->bloom mix weight (energy-conserving lerp).
// 1.0 is the tuned dreamy baseline; higher blooms harder, lower is subtle.
#define BLOOM_STRENGTH 1.0 // [0.5 0.75 1.0 1.25 1.5]

// --- Bloom shaping (internal, not GUI) ------------------------------------
// ADDITIVE bloom weight w in `scene + bloom * w`, before BLOOM_STRENGTH.
// Additive (not a crossfade): bright emissives GAIN a soft halo and NOTHING is
// dimmed (the brief's "generous bloom / emissive spill"). `bloom` is the full
// dual-filter pyramid U1 = L1 + tent(U2), normalised by the level count so it is
// an energy-preserving average magnitude of the 6 levels (each tent is
// energy-preserving), so the added energy is bounded; AgX's soft highlight
// rolloff in final absorbs it without clipping. Tuned (numeric sim through the
// AgX path) so a night torch halo gains ~2.1x while a noon midtone shifts <2%:
// scene L=0.18 + bloom~0.18 -> +1.7% display; a torch-lit dark halo (scene~0.02
// + bloom~1.0) -> ~2.1x brighter; the torch CORE (already saturated) is
// unchanged. BLOOM_STRENGTH scales this (1.5 -> halo ~2.5x, noon ~+2.5%).
#define AL_BLOOM_ADD 0.04

// Tent-upsample tap radius (in source-tile texels) for the pyramid's dual-filter
// UPSAMPLE (lib/bloom.glsl alBloomTentTile). 1.0 is the standard COD/Jimenez
// 3x3 tent; larger spreads each level's contribution wider (softer, dreamier,
// but can over-smooth fine glow). Keep near 1.0.
#define AL_BLOOM_TENT_RADIUS 1.0

// Exposure user bias. Multiplies the auto-adapted exposure in final (auto
// exposure now does the metering; this is the manual trim on top). 1.0 = no
// trim; the calibration exposure that sets the base levels is AL_AGX_EXPOSURE.
#define EXPOSURE 1.00 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00]

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
// Mac-path auto-exposure: composite14 meters the deep-mip average scene
// luminance and adapts colortex5.a (a true persistent slot — composite1 now
// preserves that alpha instead of clobbering it, so the loop reads last frame's
// value). Deliberately GENTLE and asymmetric so it never undoes the field-
// approved dark nights (see composite14.fsh for the loop design).
//   KEY       target average luminance (drives KEY/avgLum metering)
//   MIN/MAX   clamp on the metered multiplier. Combined with STRENGTH below the
//             FINAL exposure multiplier is bounded to mix(1,MIN,STRENGTH) ..
//             mix(1,MAX,STRENGTH) = ~[0.90, 1.08] — i.e. auto-exposure can never
//             push the image more than ~10% off the CALIBRATED base level, so
//             the field-approved noon/night levels always carry over (contract
//             §0). It is a gentle correction, not a full metering.
//   STRENGTH  how far toward the metered target vs a neutral 1.0 (subtle)
//   TAU       adaptation time constant (seconds) of the exponential integrator:
//             the exposure converges toward the metered target over ~TAU seconds
//             (rate = 1 - exp(-frameTime/TAU)), frame-rate independent.
// 0.4.4 ("dark areas too light"): tightened the auto-exposure so it can't lift
// caves/night toward daylight (MAX 1.16 -> 1.04, STRENGTH 0.5 -> 0.30).
#define AL_EXPOSURE_KEY 0.26
#define AL_EXPOSURE_MIN 0.80
#define AL_EXPOSURE_MAX 1.04
#define AL_EXPOSURE_STRENGTH 0.30
#define AL_EXPOSURE_TAU 1.0

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
// Grain policy (revised): screen-space noise sources are handled DETERMINISTICALLY
// wherever possible, because temporal reprojection without a velocity buffer rejects
// history at distance and falls back to the raw noisy frame — that is what produced
// the "distance jitter" in both FXAA and TAA.
// Each stochastic effect therefore has a SPATIAL defence that works with the dither
// frozen, and the per-frame dither ANIMATION is gated per effect. Current policy —
// this list is normative; if you change a gate, change it here too:
//
//   * GTAO       -> dither FROZEN under FXAA (deferred.fsh, `#ifdef AL_TAA`).
//                   Spatial defence: the depth+normal BILATERAL denoise at READ
//                   time in deferred1.fsh (AL_AO_DENOISE). That denoise must stay
//                   at read time and NEVER be written back into the colortex5
//                   history — deferred blends colortex5 into colortex4 and
//                   composite1 copies it back, so a filter inside that loop
//                   re-filters an already-filtered signal every frame and the blur
//                   compounds until each surface flattens to a constant patch.
//   * Shadow PCF -> Vogel rotation + contact-shadow dither FROZEN under FXAA
//                   (lib/shadow.glsl, deferred1.fsh). Spatial defence: 12+ Vogel
//                   taps and non-tiling IGN. The colortex11 accumulator therefore
//                   contributes nothing under FXAA — that is deliberate. Animating
//                   it made every accumulation FAILURE (off-screen reprojection on
//                   a camera turn, disocclusion, distance depth-reject) fall back
//                   to noise that changes every frame, i.e. crawling shadow edges,
//                   which is the regression this pack has already shipped once.
//   * SSR        -> dither IS animated whenever AL_SSR_TEMPORAL is set (which is
//                   unconditional), so it animates under FXAA too. This is the one
//                   effect that deviates, and it is deliberate: SSR owns a
//                   dedicated validated accumulator (colortex10 + the colortex12
//                   confidence ramp) plus a glossy ring pre-filter, and reflections
//                   have not shown the crawl that shadows did. If reflection crawl
//                   IS reported, gate this to `#ifdef AL_TAA` like the others —
//                   composite.fsh has two sites.
//   * Coloured   -> disc rotation IS animated unconditionally, for the same
//     block light    reasons as SSR plus two of its own: the buffer is HALF
//                   resolution and bilinearly upsampled (a 2x2 box filter for
//                   free), and only the NORMALISED hue is consumed, so tap-count
//                   magnitude noise cancels out of the result entirely. It owns
//                   a validated reprojected accumulator (colortex14, blend 0.90).
//                   If coloured-light crawl is ever reported, gate the frame
//                   advance in deferred2.fsh to `#ifdef AL_TAA` like the others.
//
// The composite3 temporal RESOLVE runs in both AA modes as an anti-flicker pass.

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
// 5.0.11 ("too much orange fog, washed out; want overworld-style distance fog in
// a nether tone"). The Nether now uses the SAME distance-fog structure as the
// overworld — a light mid-field ember haze + a patchy far gradient + a solid
// render-edge wall — instead of a heavy uniform exponential ember. AL_NETHER_FOG
// is the (dim) mid haze; AL_NETHER_FOG_FAR is the richer far-wall ember that hides
// the render edge; the half-distance is much longer so the near/mid field is clear.
const vec3 AL_NETHER_FOG     = vec3(0.115, 0.040, 0.024);  // dim mid ember (was 0.24,0.07,0.04)
const vec3 AL_NETHER_FOG_FAR = vec3(0.190, 0.066, 0.040);  // far-wall ember tone
#define AL_NETHER_FOG_HALF 150.0

// --- End (world1) ---
// Cool violet key + purple ambient (the End has no sun). The black-hole sky is
// drawn procedurally in world1/deferred1; these light the terrain.
const vec3 AL_END_KEY     = vec3(0.60, 0.38, 0.92);   // cool violet directional-ish
const vec3 AL_END_AMBIENT = vec3(0.12, 0.075, 0.20);  // low purple fill (moody, darker)
// 5.0.11 — same overworld-style distance fog for the End, in a purple tone. The
// mid haze is dim; the far wall converges to the End horizon SPACE colour so distant
// terrain melts seamlessly into the purple sky. Long half-distance keeps the near/
// mid field clear (the whisps are the star, not soup).
const vec3 AL_END_FOG     = vec3(0.085, 0.032, 0.160);  // dim purple mid haze
const vec3 AL_END_FOG_FAR = vec3(0.155, 0.055, 0.290);  // far wall = End horizon space colour
#define AL_END_FOG_HALF 200.0

// End procedural space backdrop — a purple gradient. LOW = near horizon (a
// richer, clearly-visible violet), HIGH = zenith (deep near-black purple). The
// contrast between the two is deliberately wide so the gradient READS as a
// gradient (5.0.8 field: "you removed the gradient from the End skybox").
const vec3 AL_END_SPACE_LOW  = vec3(0.155, 0.055, 0.290);
const vec3 AL_END_SPACE_HIGH = vec3(0.022, 0.007, 0.060);

// End VOLUMETRIC WHISPS (lib/blackhole.glsl + world1/composite2). Glowing violet
// whisps that live in 3D world space (NOT the skybox) — sparse vertical columns
// that rise and drift ethereally, raymarched and BOUNDED by the scene depth so
// the End pillars/terrain correctly occlude them. Like clouds, but lower, vertical
// and glowing.
// 5.0.11 TWO-LAYER WHISPS (field: "not luminous light-purple / too white / not
// see-through / abruptly stop up high"). The march (lib/blackhole.glsl) accumulates
// TWO independent whisp fields with emission-absorption self-occlusion, so each
// layer's glow is BOUNDED to COL*GLOW (saturated purple, sub-1 => never white) and
// low densities keep them very SEE-THROUGH. A vertical envelope fades them in from
// the base and out gently toward the top (no abrupt cut-off).
#define AL_END_WHISP_MAXDIST 200.0   // how far the march reaches (blocks)

// GUI (Sky screen): master toggle + overall glow multiplier for the whisps.
#define END_WHISPS // [END_WHISPS]
#define END_WHISP_INTENSITY 1.00 // [0.00 0.25 0.50 0.75 1.00 1.50 2.00]

// Vertical band (world Y): fade IN above BASE, fade OUT over TOP_FADE below TOP.
#define AL_END_WHISP_BASE_Y  -40.0
#define AL_END_WHISP_TOP_Y    170.0
#define AL_END_WHISP_TOP_FADE 110.0  // long, gradual top fade (blocks)

// LARGE whisps — wide, sparse, VERY see-through, medium-saturated purple.
#define AL_END_WHISP_SCALE_L  0.022   // low frequency = large columns
#define AL_END_WHISP_RISE_L   0.16    // vertical drift speed
#define AL_END_WHISP_DENS_L   0.045   // LOW density -> very see-through
#define AL_END_WHISP_GLOW_L   0.50    // peak glow of a solid large column
const vec3 AL_END_WHISP_COL_L = vec3(0.40, 0.16, 0.72);   // see-through medium purple

// FINE whisps — tiny, thin, more numerous, LIGHTER purple, MORE glowing.
#define AL_END_WHISP_SCALE_F  0.085   // high frequency = tiny thin whisps
#define AL_END_WHISP_RISE_F   0.26
#define AL_END_WHISP_DENS_F   0.070
#define AL_END_WHISP_GLOW_F   0.70    // brighter (more glowing) than the large layer
const vec3 AL_END_WHISP_COL_F = vec3(0.62, 0.40, 0.92);   // lighter glowing purple

// Dormant black-hole size — the procedural black hole was removed (5.0.6), so this
// is NO LONGER a GUI option (it did nothing). Kept as a plain constant only so the
// call site in world1/composite2 still compiles; the value is ignored.
#define END_BLACKHOLE_SIZE 1.0

#endif // AL_SETTINGS
