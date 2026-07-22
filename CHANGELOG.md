# Changelog

All notable changes to Asteria Loom are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
