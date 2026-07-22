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
 override a small subset (SHADOWS, SHADOW_RESOLUTION, SHADOW_FILTER).
============================================================================
*/


/* =========================================================================
   PROFILES NOTE
   -------------------------------------------------------------------------
   The five presets (POTATO/LOW/MEDIUM/HIGH/ULTRA) are defined in
   shaders.properties via `profile.*`. They only flip options declared in
   THIS file. Phase-1 differentiators:
     - SHADOWS          (POTATO off; everyone else on)
     - SHADOW_RESOLUTION(1024 / 1536 / 2048 / 2048 / 3072)
     - SHADOW_FILTER    (POTATO/LOW off; MEDIUM+ on)
   Later phases add SSAO / TAA / clouds / SSR quality knobs here.
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
#define SHADOW_RESOLUTION 2048 // [1024 1536 2048 3072 4096]

// Max distance (blocks) shadows are cast. Larger = more coverage, softer.
#define SHADOW_DISTANCE 128 // [64 96 128 192 256]

// Soften shadow edges with a cheap 2x2 tap. Off = single hard tap (cheapest).
#define SHADOW_FILTER // [SHADOW_FILTER]


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
//   1 albedo | 2 world normal | 3 lightmap (block=R, sky=G) | 4 depth | 5 matID
#define DEBUG_VIEW 0 // [0 1 2 3 4 5]


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

// Warm torch / block-light colour.
const vec3 AL_TORCH_TINT = vec3(1.00, 0.58, 0.26);

// Cool-blue night minimum. Terrain under open sky never falls below this.
const vec3 AL_NIGHT_FLOOR = vec3(0.030, 0.045, 0.085);

// Faint indirect-bounce lift added to the light sum so coloured faces never
// read as pure black. Subtly cool.
const vec3 AL_BOUNCE = vec3(0.018, 0.021, 0.030);

#endif // AL_SETTINGS
