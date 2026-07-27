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
   The one exception is `shaders.properties` — see below, it is **appended**.
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
   prefix is what makes rule 3 mechanically checkable. Advanced-only *settings*
   go in `lib/advanced/settings_advanced.glsl`, **never** in
   `shaders/settings.glsl` — that file is compiled into the Mac build too, and
   every GUI option in it is bound by the settings/screen/lang three-way
   contract the validator enforces.
6. **`shaders.properties` is APPENDED, never replaced.** See the next section.

## `shaders.properties` — the append mechanism

`shaders.properties` is the one file the overlay may **not** replace. Rule 1
(replace-by-path) is wrong for it: the file describes the *whole pack* — five
profiles, nine screens, the slider list, every blend/size/program directive — so
an overlay copy would have to restate all of that just to add the two lines the
Advanced build actually needs. And then it would go **silently stale**: the next
edit to the canonical file would reach the default zip and not the Advanced one,
with nothing failing, nothing warning, and the two builds quietly diverging.
That is the same failure shape as the `clear.colortexN` bug that cost this pack
every temporal feature — a directive read by nobody, failing silently.

So the overlay ships a **fragment** instead:

```
shaders-advanced/shaders.properties.append
```

and the effective file in the Advanced build is

```
shaders/shaders.properties          (verbatim, always current)
+ a generated separator banner
+ shaders-advanced/shaders.properties.append
```

* The merge is defined **once**, in `tools/overlay_props.py`. Both
  `tools/package.py` (writing the Advanced zip) and `tools/validate.py`
  (`materialize_overlay`, staging the tree for the compile gate) call it, so the
  properties the gate validates are byte-identical to the ones that ship. A
  second implementation would recreate exactly the drift this replaces.
* `shaders.properties.append` is a **build input**: it is merged, never copied,
  and never appears inside the zip.
* Java `.properties` keeps the **last** assignment of a duplicated key, and the
  fragment is last — so it can override a base key as well as add new ones. It
  can never *lose* a base key it does not mention, which is the point.
* A full `shaders-advanced/shaders.properties` is a hard **ERROR** in both
  tools, and the message names the `.append` file.

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

Shipping one Phase 6 feature; the rest (voxel light, ray-traced shadows/GI,
3D-image volumetrics) land here later — see `docs/roadmap.md` Phase 6.

```
shaders.properties.append              iris.features.required = COMPUTE_SHADERS
lib/advanced/settings_advanced.glsl    advanced-only tunables (AL_EXPO_*)
lib/advanced/exposure_histogram.glsl   the histogram metering implementation
world0|world1|world-1/final.csh        the `final` pass's compute stage; thin,
                                       just includes the two files above
```

### Compute histogram auto-exposure (`final.csh`)

Replaces the **metering** of the Mac path's auto-exposure, and nothing else.
`composite14.fsh` meters by sampling a deep mip of colortex0 — an arithmetic
*mean* of the frame, which one bright sky, one torch in a black cave, or the sun
disc dominates, so the exposure breathes as the player turns. The compute pass
bins log2-luminance over 16384 stratified samples into a 128-bin histogram,
discards the darkest 30% and brightest 15% of the sample population (bins are
split *fractionally* at the cut points, so the estimate moves continuously
rather than stepping), and takes the weighted mean of the middle band: a trimmed
mean in log space, which outliers cannot move.

Everything downstream is the **unchanged** contract: the same asymmetric
`AL_EXPOSURE_MIN/MAX/STRENGTH` clamp (so dark nights are never lifted — that
behaviour is field-approved and does not regress), the same `AL_EXPOSURE_TAU`
exponential integrator, the same `[0.2,5.0]` range guards, and the same output
slot `colortex5.a` at texel `(0,0)`, which `final` reads. Those constants stay
in `shaders/settings.glsl` on purpose so the two builds' *adaptation* can never
fork; only the histogram tunables live in the overlay.

**Why the `final` pass and not a new `composite15`.** Iris runs a
composite-style pass's compute stage *first*, before that pass's own
vertex/fragment, and `final` lists compute as an optional stage — so `final.csh`
executes after every composite (including `composite14`) and immediately before
the only consumer of the value, `final.fsh`. A compute-only `composite15.csh`
would have been the obvious alternative, but Iris documents composite passes as
*requiring* vertex and fragment stages, so a slot holding nothing but a `.csh`
is not guaranteed to be dispatched — and that failure would be silent. Padding
the slot with a dummy fragment is worse: a fragment program's `RENDERTARGETS`
list makes Iris flip those buffers whether or not anything is written, so a
dummy pass over colortex5 would swap in the stale copy and take the AO history
and the exposure slot with it. `final.csh` is a *new* file; `final.vsh`/
`final.fsh` in `shaders/` are untouched.

**No double integration.** `composite14`'s fragment metering still runs — no
properties key can remove one MRT write from a pass, and disabling the program
would take the bloom combine with it — so it is made *inert* in both directions:
the compute stage runs after it and overwrites `(0,0)`, the texel `final.fsh`
reads (forward); and the compute integrator keeps its own previous value in
`colortex5.a` texel `(1,0)`, which `composite1` and `composite14` both pass
through byte-exact, so the fragment path's output never feeds back in
(backward). The displayed exposure is integrated exactly once per frame. Leaving
the fragment path alive is deliberate: if the compute dispatch ever fails to
run, `(0,0)` still holds a valid adapting exposure and the build degrades to the
Mac behaviour instead of freezing.

Bindings: **1 sampler** (`colortex0`) + **1 image** (`colorimg5`), one 16x16
workgroup. No SSBO, no custom images, no extra render target — so the only
capability required is `COMPUTE_SHADERS`, which the properties fragment
declares.
