# Changelog

All notable changes to Asteria Loom are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
