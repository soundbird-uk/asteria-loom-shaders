# Asteria Loom

A from-scratch, high-end shaderpack for Minecraft Java via the [Iris](https://irisshaders.dev/)
pipeline. Asteria Loom aims for a soft, filmic, dreamy look — gentle contrast, generous
bloom, hazy aerial perspective, an AgX-style tonemap, and painterly golden hours — rather
than a hard, hyper-real one.

It ships as a **single auto-adapting pack**. One download works everywhere: advanced,
Windows/Linux-only features unlock automatically on capable machines and compile cleanly out
of the build on macOS. Development is **Mac-first** against OpenGL 4.1, so the baseline is
guaranteed to run on Apple Silicon; Windows and Linux gain an advanced tier on top.

> **Current version: 0.3.3** (Phases 1–3 shipped and field-hardened on M4 Mac and Windows).
> **0.4.0 — Phase 4 (water & post) — is implemented and in adversarial review.** See the
> roadmap below and the [changelog](CHANGELOG.md) for the full release history.

## Features

Live today (0.3.3):

- **Soft PCSS shadows** with shadow-map distortion warp (higher centre resolution),
  blocker-search penumbrae and contact-hardening, plus screen-space **contact shadows** on
  High/Ultra. A single software compare path runs identically on Windows and macOS.
- **GTAO** (horizon-based ambient occlusion) with temporal accumulation, applied to the
  indirect lighting only.
- **Physically based atmosphere** — analytic Rayleigh + Mie + ozone single scattering baked
  once per frame into a horizon-biased sky-view LUT and sampled everywhere. A procedural,
  limb-darkened HDR **sun disc** replaces the vanilla sun. Sun and ambient colours are
  atmosphere-driven, keeping the warm-amber / cool-blue identity as tunable modifiers.
- **Two-layer volumetric clouds** (3D cumulus with erosion detail + a high cirrus sheet):
  sun light-marching, multiple-scattering approximation, powder-dark undersides,
  weather-driven coverage, wind drift with an adjustable **cloud speed**, temporal
  accumulation, and cloud shadows cast onto the terrain.
- **Aerial-perspective fog** that scene-tones with distance (hazy blue-grey days, muted warm
  sunsets, cool moon-haze at night), modulated by biome and weather, and gated by sky
  exposure so caves stay dark.
- **Procedural night sky** — magnitude-distributed twinkling stars, a tilted dust-structured
  galaxy band, and occasional shooting stars, all fading through dusk below moon brightness.
- **Dark, moody nights** with a preserved cool-blue readability floor and a warm blocklight
  ramp so torches, campfires and glowstone pop against the darker base.

Implemented in **0.4.0 (Phase 4)**, in review — not yet field-verified on-device:

- **Water** — procedural animated ripples, screen-space reflections of sky and geometry,
  depth-dependent absorption tint, projected animated caustics on submerged surfaces, and
  underwater volumetric media (blue-green haze + gentle refraction).
- **TAA** — Halton-jittered temporal anti-aliasing with reprojection and neighbourhood
  clamping (on in every preset except Potato).
- **Bloom** — threshold-free, energy-conserving mip-chain bloom driving emissive spill.
- **AgX tonemap** with mip-average auto-exposure and temporal adaptation, plus
  biome-adaptive grading and **weather storytelling** (rain desaturates and cools, thunder
  darkens, post-rain wetness lifts freshness, lightning flashes brighten the frame).

## Roadmap

Each phase is a self-contained milestone. See [`docs/roadmap.md`](docs/roadmap.md) for the
detailed checklist and per-phase field-hardening notes.

| Phase | Theme | Status | Highlights |
|---|---|---|---|
| 1 | Scaffold & foundation | **Complete** (field-hardened) | Deferred G-buffer pipeline, five profiles, CI validation |
| 2 | Lighting & shadows | **Complete** (field-hardened) | PCSS soft shadows + distortion + contact shadows, GTAO, warm blocklight ramp |
| 3 | Sky, clouds & fog | **Complete** (field-hardened) | PB atmosphere + sky LUT, procedural sun disc, volumetric clouds, aerial fog, night sky |
| 4 | Water & post | **Implemented, in review** | Water/SSR/caustics/underwater, TAA, bloom, AgX + auto-exposure, biome grading, weather storytelling |
| 5 | Dimensions & extras | Upcoming | End black hole + purple haze, Nether pass, loom crepuscular rays + aurora, Distant Horizons |
| 6 | Advanced tier (Windows/Linux) | Upcoming | Flood-fill colored light, voxel RT shadows/GI, histogram exposure, 3D-cached volumetrics |
| 7 | Tuning & release | Upcoming | Per-profile perf validation, sampler audits, screenshots, v1.0.0 |

Phases 1–3 are complete and have been hardened through repeated on-device testing on an M4
Mac (Iris, GL 4.1) and Windows. Phase 4 is code-complete and passing CI across all profiles
but has not yet been field-verified; treat its features as provisional until 0.4.0 releases.

## Requirements

- The **latest Minecraft Java release** (as targeted by current Iris builds).
- The [**Fabric**](https://fabricmc.net/) mod loader.
- The **latest stable Iris** (the 1.11.x line) plus its bundled Sodium.
- A GPU supporting **OpenGL 4.1** or newer. The advanced tier (Phase 6) will additionally
  require OpenGL 4.3+ and is therefore Windows/Linux-only; macOS runs the full baseline pack.

## Installation

1. **Get the pack.** Either:
   - Download the release zip from the
     [Releases](https://github.com/soundbird-uk/asteria-loom-shaders/releases) page and drop
     it into your `.minecraft/shaderpacks/` folder, **or**
   - Clone this repository and place the `shaders/` folder into `shaderpacks/`. During
     development a symlink keeps the live pack in sync with the repo:
     ```sh
     # macOS / Linux
     ln -s "$(pwd)/shaders" ~/.minecraft/shaderpacks/AsteriaLoom
     ```
     (Or simply copy the `shaders/` folder in as `AsteriaLoom/` if you prefer.)
2. Launch Minecraft with Iris, open **Options → Video Settings → Shader Packs**, and select
   **Asteria Loom**.
3. Pick a preset and tune options from the in-game shader settings screens.

### Development shortcuts

- Press **`R`** in-game to hot-reload the pack after editing a shader file.
- Press **`Ctrl+D`** to toggle Iris debug mode, which surfaces compile errors. Iris also
  dumps the preprocessed GLSL to `.minecraft/patched_shaders/` — error line numbers refer to
  those patched files, not the raw source.

## Presets

Asteria Loom auto-selects a sensible default, but you can switch profiles at any time from
the shader settings screen. Presets differ by which passes run at all (the real performance
lever), not just by `#define` tweaks. Current differentiators:

| Preset | Intended for | Shadows | AO | Clouds | Water | Post |
|---|---|---|---|---|---|---|
| Potato | Integrated graphics | Off | Off | Vanilla | Waves only, no SSR/caustics | No TAA, no bloom |
| Low | Weak dedicated GPUs | On, hard-edged (no PCSS), 1536 map | Off | Vanilla | SSR quality 1 | TAA + bloom |
| Medium | Mainstream GPUs (default) | PCSS, 12 samples, 2048 map | On, quality 2 | Volumetric, quality 1 | SSR quality 2 | TAA + bloom |
| High | RTX 3060-class GPUs | PCSS 16 samples + contact shadows | On, quality 3 | Volumetric, quality 2 | SSR quality 2 | TAA + bloom |
| Ultra | High-end GPUs | PCSS 24 samples + contact, 3072 map | On, quality 3 | Volumetric, quality 3 | SSR quality 3 | TAA + bloom |

## Settings screens

Every option is exposed in the in-game GUI, grouped into screens:

- **Lighting** — sun/ambient/blocklight intensity, blocklight tint, night brightness, bounce.
- **Shadows** — enable, PCSS, sample count, shadow map resolution, shadow distance, contact shadows.
- **AO** — enable, quality, strength.
- **Sky** — sky and sun/moon brightness, Mie strength, turbidity, sun disc size/brightness, night sky, star density.
- **Clouds** — volumetric clouds, quality, coverage, cloud speed, vanilla-cloud fallback.
- **Fog** — aerial fog, density.
- **Water** — SSR, SSR quality, waves, caustics.
- **Post** — bloom, bloom strength, exposure, TAA.
- **Debug** — debug view selector.

## Screenshots

_Placeholder — no polished promotional captures are embedded yet._ Field screenshots from
on-device M4 Mac and Windows testing exist in the development session and pull-request history
for Phases 1–3; a curated gallery will land with the visual-tuning pass in Phase 7.

## Development

The pack source lives in `shaders/`. Tooling lives in `tools/`, and continuous integration
runs on every push.

- **Validation.** `tools/validate.py` (Python 3, standard library only) resolves Iris-style
  `#include`s, injects each profile's `#define` set, and runs `glslangValidator` over every
  program for every profile. It also checks fragment sampler budgets and render-target
  declarations, and compiles all three platform combinations (including the macOS +
  hardware-shadow-samplers `mac-hw` target).
  ```sh
  python3 tools/validate.py
  ```
- **Packaging.** `tools/package.py` builds an installable `AsteriaLoom-<version>.zip` whose
  root contains the `shaders/` folder (the layout Iris expects).
- **CI.** [`.github/workflows/validate.yml`](.github/workflows/validate.yml) runs the
  validator across all five profiles on every push and uploads the packaged zip as a build
  artifact.

Contributors should start with [`docs/architecture.md`](docs/architecture.md) for the pass
chain, buffer layout, and the macOS GL 4.1 constraints that shape the whole design.

## Credits

Asteria Loom is **100% original code, written from scratch.** No GLSL was copied from any
existing pack. Its architecture draws inspiration from studying the design of packs such as
Photon, Complementary, Bliss, Rethinking Voxels, and others in the shaderLABS community —
as reference for *how* problems are approached, never as a source of code. Those packs carry
study-only or all-rights-reserved licenses; none of their code is present here.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 soundbird-uk.
