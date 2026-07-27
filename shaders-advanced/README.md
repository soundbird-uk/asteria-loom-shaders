# `shaders-advanced/` — the Advanced-tier overlay

This directory is **not a second copy of the pack**. It is a thin *overlay*: a
delta applied on top of the canonical `shaders/` tree to produce the
Windows/Linux-only **Advanced** zip.

```
shaders/            canonical source of truth. macOS-safe. ZERO .csh, ever.
shaders-advanced/   overlay. Paths mirror shaders/. ONLY files that DIFFER
                    from, or are NEW relative to, the canonical tree.
```

## Why the split exists

Iris compiles **every** `.csh` a pack ships, unconditionally —
`ProgramSet.readComputeArray` is not feature-gated — and macOS (OpenGL 4.1)
cannot compile compute shaders. So a single `.csh` anywhere in the pack makes
the *whole* pack fail to load on macOS with
`Shader compilation failed for compute <name>`.

`#ifdef` gating does **not** help. `AL_ADVANCED_TIER`, `IRIS_FEATURE_COMPUTE_SHADERS`,
`MC_OS_WINDOWS` — none of them matter. The file's mere *presence* is fatal.

The only safe answer is to ship two archives:

| zip | built from | audience |
| --- | --- | --- |
| `AsteriaLoom-<version>.zip` | `shaders/` | **everyone** — the default download, macOS included |
| `AsteriaLoom-Advanced-<version>.zip` | `shaders/` + this overlay | Windows/Linux only — **will NOT load on macOS** |

## The contract

1. **Mirror the paths.** A file here at `world0/composite.fsh` replaces
   `shaders/world0/composite.fsh` in the Advanced build. A file here with no
   counterpart in `shaders/` is simply added. Both variants pack into the
   `shaders/` prefix inside the zip, which is the layout Iris expects.
2. **Only the delta.** Never duplicate a file that is identical to its
   `shaders/` counterpart — that creates two sources of truth that silently
   drift. If a change belongs in both builds, it goes in `shaders/`.
3. **`shaders/` never depends on this tree.** No program under `shaders/` may
   `#include` anything under `shaders-advanced/lib/advanced/`, directly or
   transitively. The default zip ships `shaders/` alone, so such an include is
   either a dead reference (Iris hard-fails the pack) or a way to smuggle
   compute-tier code into the Mac build. `tools/validate.py` lints this.
4. **Compute programs live here and only here.** `.csh` files must never appear
   under `shaders/`. `tools/validate.py` hard-fails on any `.csh` in the
   canonical tree, and `tools/package.py` refuses to write the default zip if a
   `.csh` would end up inside it.
5. **Advanced-only library code goes in `lib/advanced/`.** Keeping it under one
   prefix is what makes rule 3 mechanically checkable.

## Tooling

```sh
# canonical macOS gate — .csh is a hard failure (unchanged, always runs in CI)
python3 tools/validate.py --target all

# advanced build — merges shaders/ + this overlay into a temp tree and validates
# that, with compute programs allowed and compiled with -S comp
python3 tools/validate.py --target advanced --overlay shaders-advanced

# both zips
python3 tools/package.py --version 1.2.3 --variant all
```

## Current state

Infrastructure only. This overlay is intentionally **empty** of shader files —
the packager and validator are wired up and exercised against it, and the
Phase 6 features (voxel light, ray-traced shadows/GI, compute histogram
auto-exposure, 3D-image volumetrics) land here later. See
`docs/roadmap.md` Phase 6.
