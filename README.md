# Asteria Loom

A from-scratch, high-end shaderpack for Minecraft Java via the [Iris](https://irisshaders.dev/)
pipeline. Asteria Loom aims for a soft, filmic, dreamy look — gentle contrast, generous
bloom, hazy aerial perspective, an AgX-style tonemap, and painterly golden hours — rather
than a hard, hyper-real one.

It ships as a **single auto-adapting pack**. One download works everywhere: advanced,
Windows/Linux-only features (compute-based colored voxel light, ray-traced GI, histogram
auto-exposure) unlock automatically on capable machines and compile cleanly out of the
build on macOS. Development is **Mac-first** against OpenGL 4.1, so the baseline is
guaranteed to run on Apple Silicon; Windows and Linux gain an advanced tier on top.

> **Status: Phase 1 (foundation).** The deferred rendering scaffold, five quality
> presets, and provisional lighting/shadows are in place and render correctly under Iris
> on macOS. The signature visuals (physically based sky, volumetric clouds, PCSS, water,
> the End black hole, and more) arrive in later phases — see the roadmap below.

## Feature roadmap

Each phase is a self-contained milestone. See [`docs/roadmap.md`](docs/roadmap.md) for the
detailed checklist.

| Phase | Theme | Status | Highlights |
|---|---|---|---|
| 1 | Scaffold & foundation | **Current** | Deferred G-buffer pipeline, five profiles, provisional warm/cool lighting + simple shadows, CI validation |
| 2 | Lighting & shadows | Planned | PCSS with distortion + contact shadows, hemisphere ambient, lightmap-colored light, SSAO/GTAO, night floor |
| 3 | Sky, clouds & fog | Planned | Rayleigh/Mie atmosphere + sky LUT, HDR sun disc, volumetric clouds with temporal upscale, aerial-perspective fog, rich night sky |
| 4 | Water & post | Planned | SSR, caustics, underwater haze, TAA, bloom, AgX grade, biome-adaptive grading, weather storytelling |
| 5 | Dimensions & extras | Planned | End black hole + purple haze, Nether pass, "loom" crepuscular rays + aurora, Distant Horizons programs |
| 6 | Advanced tier (Windows/Linux) | Planned | Flood-fill colored light, voxel RT shadows/GI, histogram exposure, 3D-cached volumetrics — all cleanly gated |
| 7 | Tuning & release | Planned | Per-profile performance validation, sampler audits, screenshots, v1.0.0 |

## Requirements

- The **latest Minecraft Java release** (as targeted by current Iris builds).
- The [**Fabric**](https://fabricmc.net/) mod loader.
- The **latest stable Iris** (the 1.11.x line) plus its bundled Sodium.
- A GPU supporting **OpenGL 4.1** or newer. The advanced tier additionally requires
  OpenGL 4.3+ (compute shaders, SSBOs, custom images) and is therefore Windows/Linux-only;
  macOS runs the full baseline pack.

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
lever), not just by `#define` tweaks.

| Preset | Intended for | Intent |
|---|---|---|
| Potato | Integrated graphics | Bare-minimum look that still runs. Shadows, volumetric clouds, SSR, SSAO and TAA are OFF. |
| Low | Weak dedicated GPUs | Basic shadows and core lighting on; heavy effects still disabled. |
| Medium | Mainstream GPUs (default) | Balanced defaults — the reference look and the values everything else builds on. |
| High | RTX 3060-class GPUs | Targets 60 fps at 1080p. Higher shadow quality and the full effect set enabled. |
| Ultra | High-end GPUs | Everything at maximum quality and sample counts, no performance compromises. |

> Effects listed above beyond Phase 1 are staged in as their phases land; the preset
> structure and per-phase differentiators are already wired in.

## Screenshots

_Placeholder — screenshots will be added once the visual phases land. No representative
imagery exists yet; nothing here is a real capture._

## Development

The pack source lives in `shaders/`. Tooling lives in `tools/`, and continuous integration
runs on every push.

- **Validation.** `tools/validate.py` (Python 3, standard library only) resolves Iris-style
  `#include`s, injects each profile's `#define` set, and runs `glslangValidator` over every
  program for every profile. It also checks fragment sampler budgets and render-target
  declarations.
  ```sh
  python3 tools/validate.py
  ```
- **Packaging.** `tools/package.py` builds an installable `AsteriaLoom-<version>.zip` whose
  root contains the `shaders/` folder (the layout Iris expects).
- **CI.** [`.github/workflows/validate.yml`](.github/workflows/validate.yml) runs the
  validator across all five profiles on every push and uploads the packaged zip as a build
  artifact.

Contributors should start with [`docs/architecture.md`](docs/architecture.md) for the pass
chain, G-buffer layout, and the macOS GL 4.1 constraints that shape the whole design.

## Credits

Asteria Loom is **100% original code, written from scratch.** No GLSL was copied from any
existing pack. Its architecture draws inspiration from studying the design of packs such as
Photon, Complementary, Bliss, Rethinking Voxels, and others in the shaderLABS community —
as reference for *how* problems are approached, never as a source of code. Those packs carry
study-only or all-rights-reserved licenses; none of their code is present here.

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 soundbird-uk.
