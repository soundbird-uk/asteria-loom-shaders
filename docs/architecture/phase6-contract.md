# Asteria Loom — Phase 6 Architecture Contract (advanced tier)

Binding contract for Phase 6 (the **advanced tier**: GPU-compute effects for
Windows/Linux). Phase 1–5 contracts and all standing LAWS remain in force
(NaN-law on clear=false reads, formats only in final.fsh comment block, three-way
options, surgical shared-file edits, Mac GL4.1 portable path unaffected).

## 0. The hard constraints that shape everything here

- **macOS is GL 4.1.** No compute shaders, no SSBOs, no custom/3D images. The
  advanced-tier features fundamentally cannot exist on the maintainer's machine.
- **The gate is `AL_ADVANCED_TIER`.** Defined in settings.glsl ONLY when the user
  opts in (`ADVANCED_TIER`) AND Iris reports `IRIS_FEATURE_COMPUTE_SHADERS`,
  `IRIS_FEATURE_SSBO` and `IRIS_FEATURE_CUSTOM_IMAGES`. On macOS none of those
  flags exist, so the macro is never defined and every advanced branch compiles
  away. Nothing else may `#define AL_ADVANCED_TIER`.
- **Verification ceiling (stated plainly).** The CI compile gate (glslang) now
  syntax-validates `.csh` compute programs on the `advanced` target, but there is
  **no GPU in CI** and the maintainer runs macOS. Advanced-tier features are
  therefore **syntax-complete, not runtime-verified**. Every advanced source file
  says so in its header, and so does the CHANGELOG. Do not describe them as
  field-hardened.

## 1. Tooling first (CI agent) — DONE

`tools/validate.py`:
- Discovers `*.csh` as compute programs (stage `comp`).
- Compiles `.csh` **only on the `advanced` target** — never on `mac`/`mac-hw`
  (compiling compute there would be a false PASS) nor on the `mac+DH` spot-check.
- Fragment-only lints (RENDERTARGETS, sampler budget, frag-out) already skip
  non-fragment stages, so compute passes them by construction.
- Self-tests: `.csh` discovered; compiled on advanced; absent on mac; a trivial
  `.csh` compiles green on advanced.

## 2. Gate + options foundation — DONE

- `settings.glsl`: `ADVANCED_TIER` GUI toggle (default on; inert on macOS) and the
  derived `AL_ADVANCED_TIER` gate. Histogram tunables (`AL_HISTO_*`).
- `shaders.properties`: `iris.features.optional = COMPUTE_SHADERS SSBO
  CUSTOM_IMAGES …` (optional so the pack still loads on macOS, where Iris simply
  never runs the `.csh`), plus a new `[ADVANCED]` screen carrying `ADVANCED_TIER`.
- `lang/en_us.lang`: `ADVANCED_TIER` entry, explicit that it is a no-op on macOS.
- **Proven Mac-unaffected:** the CI `mac`/`mac-hw` targets define none of the
  feature flags, so `AL_ADVANCED_TIER` compiles out and the `.csh` files are not
  even compiled — the Mac matrix is byte-identical to the tier-absent build.

## 3. Compute histogram auto-exposure — DONE (syntax-validated)

The signature advanced-tier feature so far. A luminance **histogram** drives auto-
exposure instead of a single deep-mip average, so tiny bright/dark outliers (sun
disc, torch, cave mouth) no longer skew the metered level.

- `world0/composite5_a.csh` — REDUCE: trimmed-mean of last frame's histogram
  (discard the darkest `AL_HISTO_LOW_CLIP` and brightest `1-AL_HISTO_HIGH_CLIP` of
  the population), write the metered luminance to a `colortex5` scratch texel via
  an image, then clear the bins.
- `world0/composite5_b.csh` — ACCUMULATE: strided (¼-res) sample of the HDR scene
  into 128 log-luminance bins with `atomicAdd`.
- `world0/composite5.fsh` — on `AL_ADVANCED_TIER`, read the metered luminance from
  the scratch texel (a plain `texelFetch`, valid in the program's `#version 330`);
  otherwise the portable deep-mip average. All downstream adaptation/clamp/AgX is
  shared. **Key portability trick:** the SSBO lives ONLY in the GLSL-460 compute
  files; the `#version 330` fragment never sees an SSBO or image — the hand-off is
  a single RGBA16F texel, so the Mac program is untouched.

Ordering (OptiFine/Iris runs a program's `.csh` in suffix order before its
fragment stage): `_a` (reduce+clear) → `_b` (accumulate) → `composite5.fsh`. The
histogram SSBO is persistent, so the reduce reads a complete histogram with a
one-frame lag (invisible; exposure adapts over seconds).

## 4. Remaining Phase 6 scope (not yet implemented)

Tracked, NOT done. Each is subject to the §0 verification ceiling.
- **Flood-fill coloured voxel light (LPV):** 3D-image ping-pong flood of block
  light colour through a camera-anchored voxel grid; sampled in `deferred1` for
  true coloured GI-ish blocklight. (Large; needs a voxelization pass + 3D images.)
- **Voxel ray-traced shadows / GI:** trace the LPV/voxel grid for contact/AO/GI.
- **3D-image-cached volumetric upgrades.**

All must land behind `AL_ADVANCED_TIER`, keep the Mac matrix byte-identical, and
be delivered with the honest syntax-only verification note.

## 5. Definition of done (per feature)

validate green on `--target all` (all worlds × profiles × mac/mac-hw/advanced +
mac+DH), self-tests green, Mac-unaffected proven, header + CHANGELOG state the
verification ceiling, zip delivered.
