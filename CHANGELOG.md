# Changelog

All notable changes to Asteria Loom are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.3] - 2026-07-23

Cinematic pass — a broad field-fix sweep across atmosphere, lighting, water,
clouds, foliage, TAA and interaction affordances, driven by screenshot review.

### Fixed

- **Fog was far too thick.** Sea-level extinction dropped ~4.3× (0.0068 → 0.0016:
  half-extinction moves from ~102 m to ~433 m). At 20–24 chunk render distances the
  mid-field no longer washes to haze — a flat horizon reaches only ~40% haze at the
  far edge while nearby terrain stays clear. Aerial depth is now subtle, not a wall.
- **Orange horizon ring / skybox through terrain.** Sky convergence is pushed late
  (only near-opaque flat-horizon rays approach the raw sky) and the edge-insurance
  strip is now a razor-thin, hard-gated seam seal — so no coloured ring follows the
  camera and legitimate mid-distance terrain keeps its dark, scene-referenced tone.
- **Void under the horizon.** The below-horizon sky is filled with the haze sampled
  at the horizon, so the world sits against continuous atmosphere and the horizon
  line sits *behind* terrain instead of showing a dark void band.
- **Night distance went pale grey.** The whole fog in-scatter is now crushed and
  cooled at night, so distant night terrain reads as dark, desaturated, moonlit
  silhouettes instead of white mist. Night fog floor lowered (0.085 → 0.028).
- **Sunrise/sunset shadows too weak.** `alSunlightColor` no longer crushes the low
  sun to a near-black deep red — it is re-normalised to keep luminance and shift
  *hue* to warm orange, so golden hour has a bright, strong, directional key and
  long dramatic shadows.
- **Objects had no lit vs shadow side.** The direct key is boosted (`AL_DIRECT_BOOST`)
  and the ambient wrap floor lowered (0.6 → 0.3), so sun-facing surfaces clearly
  brighten while backfacing/downward faces darken — real directional contrast on
  terrain, trees and grass without over-darkening open shaded ground or caves.
- **Water looked like scrolling fabric.** The wave model is retuned to broad,
  multi-directional swells (fewer components, ~15-block base wavelength, lower
  amplitude) and the high-frequency micro layer is demoted to a faint, larger-scale,
  short-range shimmer — no more tiled criss-cross weave.
- **Vanilla water texture visible / water too see-through.** The animated water
  atlas is no longer sampled into the surface albedo (shader-driven blue-green tint
  instead); down-look opacity and depth absorption are raised so deep water goes
  properly opaque blue-green while shorelines stay readable.
- **Night clouds too bright/white.** Cloud radiance is darkened (~20%) and cooled at
  night, gated by sun elevation so noon is untouched — clouds now read as dark,
  moody, moonlit masses with dark undersides.
- **Distant terrain shimmer with TAA.** The reprojection is un-jittered (removing
  the frame-varying reconstruction wobble that made far silhouettes swim) and the
  neighbourhood clamp is now a variance clip (mean ± σ) — far terrain/mountains/
  horizon are stable while near edges keep their anti-aliasing.
- **Block selection outline missing.** The outline is emitted as a bright, crisp
  near-white line, exempted from fog, and given the short TAA blend — so it stays a
  legible interaction affordance at close range.

### Added

- **High-quality foliage wind.** Grass, plants, crops, vines and leaves now sway
  (`lib/wind.glsl`): rolling gusts + per-plant phase (spatially varied, never in
  sync), anchored bases via `at_midBlock` top-weighting, grass swaying more than
  leaves, and a subtle leaf flutter. Applied in both the G-buffer and shadow passes
  so shadows wave in step. Foliage block IDs mapped in `block.properties`.
- **More small wispy clouds.** The cirrus layer is extended into a fragmented,
  multi-scale wisp system — many small bright wisps dotted across the sky by day
  (still obeying night darkening) alongside the existing volumetric weather masses.
- **God rays / sun shafts.** Screen-space light scattering (`composite2`) casts warm
  shafts through gaps in leaves and around terrain silhouettes toward the sun,
  strongest at low sun and in haze, heavily gated so it never washes the screen.

## [0.4.2] - 2026-07-23

Field fixes from 0.4.1 testing.

### Fixed

- **The horizon haze band can no longer appear in front of terrain.** Sky
  convergence is now driven by optical depth instead of a render-distance plane:
  fog stays dark scene-tone in the mid field and only heavily-extincted rays
  approach the raw sky, so terrain melts into the sky asymptotically. Elevated
  peaks keep low optical depth and stay crisp — haze climbs slopes smoothly
  instead of drawing a horizontal line (verified with a mountain-profile table;
  terrain/sky seam delta is 0% at typical render distances).

### Changed

- **Water waves de-uniformed** — six interfering directional components with
  roughly-opposing pairs (criss-cross chop instead of a marching front),
  dispersion (long waves travel faster), ~66-block patches that rotate and
  reweight the mix so different lake areas move differently, and a distance-faded
  domain-warped micro-detail layer. Big-wave normals are analytic (alias-free).
- **Water is much less see-through** — down-look opacity in deep water ~0.72
  (was ~0.42), shorelines stay clearer (~0.49), grazing keeps ~0.95; deep water
  reads as dense blue-green volume with red absorbed fastest.

## [0.4.1] - 2026-07-23

### Fixed

- **Pack failed to load ("Failed to parse buffer blend! index = -1").** The water
  pass's per-buffer blend overrides used bare draw-buffer indices; Iris requires
  buffer names (colortexN or legacy). Verified against Iris source and corrected
  to `blend.gbuffers_water.colortex2/colortex3 = off`.

## [0.4.0] - 2026-07-23

Phase 4 — water & post-processing. The pack gains its final rendering identity:
real water, temporal anti-aliasing, bloom, and the AgX filmic grade.

### Added

- **Water.** Animated wind-aligned ripples (matched to the clouds' wind), screen
  space reflections with quality tiers and a sky fallback (softly capped — never
  mirror-chrome), Beer-Lambert depth absorption, and animated voronoi caustics
  dancing on submerged terrain. Real water is identified by block ID
  (block.properties) — stained glass, ice, slime and other translucents keep
  their own look. Underwater gets blue-green distance haze with gentle
  refraction wobble; lava and powder snow get their own dense media.
- **Temporal anti-aliasing** (all presets except Potato): Halton-jittered
  geometry with a YCoCg-clamped, confidence-managed temporal resolve,
  rotation-aware sky reprojection, HDR flicker weighting, and reduced hand
  history to prevent weapon ghosting.
- **Bloom** — threshold-free 6-level mip-atlas bloom, strictly additive
  (a night torch halo brightens ~2x; noon scenes shift under 2%; nothing ever
  dims). Emissive spill against the dark nights is the payoff.
- **AgX filmic tonemap** with a soft look (gentle contrast, rolled highlights),
  numerically calibrated so the field-approved noon and night levels carry over
  within ~8%. Bounded auto-exposure from scene luminance (never undoes the dark
  nights); EXPOSURE becomes a bias control.
- **Biome-adaptive grading** (golden deserts, mossy swamps, crisp snow, lush
  jungle — all subtle) and **weather storytelling**: rain desaturates and cools,
  thunder pulls toward steel, post-rain wetness adds a fresh saturation lift,
  and lightning strikes flash the frame.
- New Water settings screen; Post screen gains TAA and Bloom controls.

### Fixed (during phase review)

- Stained glass/ice/slime rendered as wavy reflective water (no block ID guard).
- Water's surface-data writes were alpha-blended, silently disabling SSR,
  absorption and caustics on straight-down views (per-target blend disabled).
- Bloom crossfade dimmed highlights; now purely additive.
- Debug views bypass the TAA resolve for pixel-exact probing.

## [0.3.3] - 2026-07-23

Tone and atmosphere rework from macOS 0.3.2 field feedback.

### Changed

- **Nights are properly dark now** — open-ground night brightness roughly halved
  (moon key, cool sky-fill, and night floor all reduced) while the cool-blue
  readability floor survives; torches pop much harder against the darker base.
- **Fog is thicker, darker, and scene-toned** — in-scatter blends toward a muted
  scene-ambient tone instead of raw bright sky: hazy blue-grey days, muted warm
  sunsets, and a new cool moon-haze so depth reads at night. Base density up
  ~50% (half-extinction ~100 m).
- **Clouds now genuinely dissolve into the distance** — opacity and scattering
  both fade with the same optical-depth model the terrain fog uses, applied after
  temporal accumulation; horizon clouds are 95-99% dissolved and converge to the
  identical sky value as fogged terrain.

### Fixed

- The warm horizon glow can no longer sit in front of mid-distance terrain: the
  far-plane sky convergence is confined to a thin skyline strip and scaled by how
  fogged a pixel actually is.
- Fog and lighting now share one canonical day/night ramp, so night fog and night
  lighting transition at the same sun elevation.

## [0.3.2] - 2026-07-22

Cloud and fog polish from macOS 0.3.1 field testing (first fully-working build on
both platforms).

### Fixed

- **Dark rectangular veil lagging behind the camera** — cloud temporal history is
  now strictly rejected off-screen (no edge-clamp reads), gated to sky pixels so
  it can never darken terrain, and carries a validity sentinel so uninitialised
  history reads fail transparent. Verified with a camera-rotation simulation.
- **Cloud drift speed** — new Cloud Speed slider; the default is ~44x slower than
  before (a gentle roll of ~29 blocks/second), with the detail "boil" slowed to
  match.
- **Clouds now fade into the distance haze** using the same optical-depth model
  and sky in-scatter as terrain fog, so horizon clouds melt into the sky instead
  of ending abruptly.
- **Render-distance seam removed** — fogged terrain converges to the exact sky
  colour over the last stretch of the frustum, so the world edge is invisible at
  any render distance.
- **Sunset white-out softened** — ground-level haze compresses highlights and
  desaturates slightly relative to the sky's own glow; noon is unchanged.

## [0.3.1] - 2026-07-22

Forensic hotfix for field regressions reported on Windows and macOS across
0.2.x-0.3.0. Every root cause was reproduced in a numerical simulation of the
shader math before being fixed.

### Fixed

- **Shadows missing on Windows / over-dark on macOS.** The shadow math itself was
  proven correct; the failure was the platform-split hardware-sampler path. The
  default is now a single software compare path (identical on all platforms) with
  PCSS blocker search on the same raw depth texture, and the fragile
  "no blockers means fully lit" early-out is gone. The hardware path remains
  available behind an off-by-default internal toggle.
- **World-erasing wash on macOS.** Aerial fog could flood the entire frame with
  sky colour when a non-finite optical depth was clamped to maximum on Apple's
  GL. Fog now fails toward clear: non-finite values produce zero fog and a
  reconstruction guard passes the scene through untouched.
- **Night ~30% too dark after the atmosphere refactor** — night ambient re-lifted
  to within ~5% of the 0.1.1 reference the user validated; noon provably
  unchanged.
- **Purple banding on submerged terrain** — the ambient-desaturation and fog
  skylight windows were misaligned, creating a double contour on the quantised
  lightmap; both now share one gentler window.
- **Dark "shadowy" particles** — particles use non-directional lightmap lighting
  (camera-facing quads no longer go black against the sun).
- New Debug Views 7 (lighting-pass coordinate/depth probe) and 8 (sky-vs-lit
  branch probe) for on-device pipeline diagnosis.

## [0.3.0] - 2026-07-22

Phase 3 — sky, clouds, fog. The vanilla sky is gone: the pack now computes its own
atmosphere, volumetric clouds, aerial perspective, and night sky.

### Added

- **Physically based atmosphere.** Analytic Rayleigh + Mie + ozone single
  scattering with numerically integrated transmittance, baked once per frame into
  a horizon-biased sky-view LUT and sampled everywhere. Sunrise, noon, sunset,
  and dusk follow the sun's real elevation; the horizon reads warmer and hazier
  than the zenith. Procedural limb-darkened HDR sun disc (vanilla sun texture
  retired; moon kept). Sun and ambient light colours are now atmosphere-driven,
  with the warm amber / cool blue identity preserved as tunable modifiers.
- **Volumetric clouds.** Two layers — 3D cumulus with erosion detail and height
  shaping, plus a high cirrus sheet — with sun light-marching, multiple-scattering
  approximation, powder-effect dark undersides, weather-driven coverage, wind
  drift, and temporal accumulation. Cloud shadows sweep the terrain and align
  with the sun. Quality tiers per preset; Potato/Low keep vanilla clouds.
- **Aerial perspective fog.** Distance shifts bluer and desaturated by scattering
  toward the real sky; density falls off with altitude and is gated by sky
  exposure (caves stay dark). Biome-modulated (swamp, jungle, desert, badlands,
  snow) and weather-responsive (rain thickens and greys, thunder darkens).
- **Procedural night sky.** Star field with magnitude distribution, colour
  variation and gentle twinkle, a tilted galaxy band with dust structure, and
  occasional shooting stars — all fading through dusk, kept below moon brightness.
- New settings screens/options: sky (mie, turbidity, sun disc, night sky,
  star density), clouds (quality, coverage), fog (density).

### Fixed (during phase review)

- Aerial fog no longer floods caves or below-sea-level terrain with sky-coloured
  haze (sea-level density floor + skylight gating).
- Cloud lighting and cloud shadows now use the exact sun direction including
  sunPathRotation (was ~17 degrees off, misaligning silver linings and shadows).

## [0.2.1] - 2026-07-22

Hotfix for regressions found testing 0.2.0 on real hardware (M4 Mac + Windows).

### Fixed

- **World invisible on macOS.** The never-cleared AO history buffer starts with
  undefined contents; on Apple's GL that could be NaN, which self-reinfected the
  temporal history and blackened all lighting from the first frame. History reads
  are now range-validated (NaN cannot pass a comparison), the GTAO math is
  domain-clamped throughout, and non-finite values can no longer be written.
- **Distant shadows disappeared.** Shadow bias and normal offset scaled linearly
  with the distortion warp's local texel size, reaching metre-plus magnitudes at
  range and deleting far shadows. Normal offset is now hard-capped at 0.30 m and
  depth bias uses a square-root curve with an absolute cap.
- **Moiré artifacts on ice** (and other flat translucents at grazing sun): added a
  quadratic grazing-angle bias term and a 2.5-texel minimum PCF radius that turns
  residual coherent acne into frame-averaged noise.
- **Profile selector missing from the settings GUI** — the main screen was missing
  the `<profile>` element; Potato–Ultra can now be selected in-game.
- **Night too bright / identity washed out.** Blocklight peak returned to the
  0.1.x level while keeping the extended 6-block warm reach, and the cave/water
  ambient desaturation window was narrowed so ordinary daylight shade keeps the
  full cool blue-purple identity.

## [0.2.0] - 2026-07-22

Phase 2 — lighting & shadows. PCSS soft shadows, GTAO, and the field-feedback
lighting fixes from on-device 0.1.1 testing.

### Added

- **PCSS shadows with contact-hardening.** Shadow-map distortion warp (~6.7x centre
  texel density, position-dependent bias/offset scaling), 4-tap blocker search,
  Vogel-disc PCF with 8-24 taps by preset, blue-noise + R2 per-frame rotation.
  Uses Iris separate hardware shadow samplers where available, with a
  compare-sampled Vogel PCF fallback otherwise.
- **Screen-space contact shadows** (High/Ultra): 14-step raymarch toward the light
  for fine-detail contact darkening.
- **GTAO with temporal accumulation.** New dedicated AO pass (horizon-based,
  quality-tiered slices/steps) with history reprojection through previous-frame
  matrices, depth-mismatch rejection, and a persistent history buffer; applied to
  indirect lighting only. New AO settings screen and debug view.
- **Warm Light Ramp**: blocklight tint ramps candle-amber to ember-orange.

### Changed

- Blocklight curve retuned: torches/campfires now visibly warm a ~6 block radius
  at night (field fix from M4 testing).
- Cool ambient desaturates as sky exposure falls — caves and underwater terrain no
  longer read purple; open-shade warm/cool identity unchanged (field fix).
- Maximum penumbra softness is now a world-space constant, so higher shadow
  resolutions no longer cap shadows harder than lower ones.
- `SHADOW_FILTER` option replaced by `SHADOW_PCSS` + `SHADOW_SAMPLES`.

### Fixed

- AO history depth is sourced from opaque-only depth, fixing shimmering
  unaccumulated AO on terrain seen through water, glass, or particles.
- Validator gained a `mac-hw` target covering the macOS + hardware-shadow-samplers
  path the M4 actually runs (CI now compiles all three platform combinations).

## [0.1.1] - 2026-07-22

Hotfix for a real-device failure found testing 0.1.0 on an M4 Mac (Iris, OpenGL 4.1).

### Fixed

- **`final.fsh` failed to compile on macOS** — the buffer-format directives
  (`const int colortexNFormat = RGBA16F;` etc.) were declared as live GLSL, but the
  format names are Iris-only tokens, not GLSL identifiers. They are now inside a
  comment block, which is where Iris' `ConstDirectiveParser` reads them from.
- **Shadow map sizing silently ignored.** `shadowMapResolution`/`shadowDistance` were
  driven by `#define`s, but Iris extracts const directives from raw text without macro
  expansion, so every preset would have fallen back to the default shadow map size.
  Both are now literal-valued const GUI options in `settings.glsl` (profiles, screens,
  sliders, and lang rewired accordingly).
- **Validator could mask the format bug.** `tools/validate.py` no longer stubs
  buffer-format identifiers; an uncommented format declaration is now a hard failure,
  format directives are located inside comments for the single-source check, and
  const-style GUI options are parsed and cross-checked like `#define` options.

## [0.1.0] - 2026-07-22

Phase 1 — scaffold and foundation. The pack loads and renders correctly under Iris on
macOS (OpenGL 4.1).

### Added

- **Deferred G-buffer pipeline.** Full opaque gbuffers set writing a well-defined
  G-buffer (albedo, encoded normal, lightmap, material ID) across four color targets,
  a fullscreen deferred shading pass, a structural composite passthrough, and a final
  pass. Sky and translucent programs forward-blend on top.
- **Five quality profiles** — Potato, Low, Medium, High, Ultra — selectable from the
  in-game shader settings screens, with Phase 1 differentiators (shadows on/off, shadow
  map resolution, vanilla clouds). Medium supplies the default values.
- **Provisional lighting.** Warm amber sun bias with cool blue-purple hemisphere sky
  ambient, warm blocklight, a night-time cool ambient floor, and a small bounce term so
  unlit faces are never pure black. The whole model lives in `lib/lighting.glsl` for reuse
  by the translucent forward passes.
- **Provisional simple shadows.** Depth-only shadow pass with a single/2x2 tap sample and
  normal-offset plus slope-scaled bias, gated behind the `SHADOWS` option. (PCSS,
  distortion, and contact shadows are Phase 2.)
- **Final pass.** Fixed-exposure control, a placeholder filmic tonemap (marked for AgX
  replacement in Phase 4), linear-to-sRGB conversion, and optional debug views (albedo,
  normals, lightmap, depth, material ID).
- **Heavily commented `settings.glsl`** holding every tunable and the pack's color
  identity constants, plus `lang/en_us.lang` localization.
- **CI validation.** `tools/validate.py` runs `glslangValidator` over every program for
  every profile with sampler-budget and render-target checks; `tools/package.py` builds
  the installable zip; `.github/workflows/validate.yml` runs both on every push.
- Repository scaffold: README, MIT LICENSE, this changelog, `.gitignore`, and contributor
  documentation.

### Notes

- Explicitly out of scope for this release (clean seams left in place): PCSS/shadow
  distortion, SSAO, TAA, volumetric clouds, the atmosphere model, SSR, bloom, the AgX
  grade, Distant Horizons programs, world folders, and the advanced tier.

[Unreleased]: https://github.com/soundbird-uk/asteria-loom-shaders/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/soundbird-uk/asteria-loom-shaders/releases/tag/v0.1.0
