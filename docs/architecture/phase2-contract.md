# Asteria Loom — Phase 2 Architecture Contract (LOCKED)

Binding contract for Phase 2 (lighting & shadows). Builds on `phase1-contract.md`;
everything there stays in force unless amended here. Brief: `docs/brief.md` §3, §6, §8.2.

## 0. Scope

- **PCSS shadows** with shadow-map distortion warp and contact-hardening penumbrae.
- **Screen-space contact shadows** for fine detail.
- **GTAO/horizon-based AO** with temporal accumulation, applied to ambient terms.
- **Hemisphere ambient refinement + lightmap-colour blocklight tinting** and
  field-feedback fixes from the 0.1.1 Mac test:
  1. blocklight far too dim (campfire barely warms nearby grass) — raise default
     intensity/curve and make emissive spill readable;
  2. underwater/under-surface terrain reads too purple — moderate the cool ambient
     saturation when sky lightmap is low;
  3. keep the warm/cool identity but ensure albedo isn't fighting a colour cast.

OUT of scope: TAA (Phase 4 — but AO temporal accumulation IS in scope), volumetric
clouds/atmosphere (Phase 3), SSR, bloom. Everything stays Mac-GL4.1-safe; no
compute/SSBO/images; `#version 330 compatibility` everywhere.

## 1. Pass restructure (LOCKED)

Phase 1's single `deferred` lighting pass becomes two deferred passes:

| Pass | Role | Reads | Writes |
|---|---|---|---|
| `deferred` | GTAO: raw AO from depth+normal, temporal blend with history | colortex2 (normal), colortex5 (history), depthtex0, noisetex | `RENDERTARGETS: 4` |
| `deferred1` | Lighting (Phase 1's deferred logic + Phase 2 shadows/AO) | colortex0-4, depthtex0, shadow textures, noisetex | `RENDERTARGETS: 0` |
| `composite` | Passthrough of colour AND AO-history copy | colortex0, colortex4, depthtex0 | `RENDERTARGETS: 0,5` |

`final` unchanged apart from optional new DEBUG_VIEW modes (6 = AO).

## 2. New buffers

| Buffer | Format | Contents | Clear |
|---|---|---|---|
| colortex4 | RG16F | r = AO term (1 = unoccluded), g = temporal sample count/confidence | yes |
| colortex5 | RGBA16F | AO history: r = AO, g = confidence, b = linearized depth of history sample | **no** (`clear.colortex5=false`) |

Formats go into the existing comment block in `final.fsh` (single canonical source).
AO may be computed at reduced quality (fewer slices/steps) — NOT at reduced
resolution in Phase 2 (Iris per-pass viewport scaling is not verified; do not use
`size.buffer`/`scale.*` without verifying against Iris ShaderDoc on GitHub —
shaders.properties docs site is blocked from this environment).

## 3. Shadows (LOCKED design)

- `shadowHardwareFiltering = true` in shaders.properties. Sampling uses
  `shadowtex0HW`/`shadowtex1HW` (`sampler2DShadow`, hardware PCF) **only** behind
  `#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS`; the fallback path (flag absent)
  keeps `shadowHardwareFiltering = false` semantics via manual depth compares on
  `shadowtex1`. Structure lib/shadow.glsl so both paths share the Vogel-disc loop.
  NOTE: `shadowHardwareFiltering` is a global; if the separate-samplers feature is
  unavailable, raw depth reads from shadowtex0 change meaning — implementer must
  verify the exact Iris behaviour from ShaderDoc and keep the fallback compiling and
  correct (worst case: PCSS blocker search disabled on that path, plain Vogel PCF).
- **Distortion warp** in shadow.vsh AND in every shadow-space lookup:
  `p.xy /= (AL_SHADOW_DISTORT_FACTOR + length(p.xy))`-family, normalized so map
  corners stay in range; inverse applied consistently; keep ALL warp math in
  lib/shadow.glsl (one function pair: distort / undistortDerivativeScale).
  `shadowDistanceRenderMul = 1.0` stays unset for now.
- **PCSS**: blocker search 4 taps (Vogel) on raw depth (shadowtex0) → penumbra from
  avg blocker depth (clamped min/max radius) → Vogel-disc PCF with
  `SHADOW_SAMPLES` taps (option), per-pixel rotation from noisetex + frameCounter
  (R2 sequence). Sun angular radius constant in settings (drives min penumbra).
- **Contact shadows** (`CONTACT_SHADOWS` toggle): screen-space raymarch from the
  shaded point toward the light in view space, 12–16 steps, fixed world-length
  (~0.5–1.0m), depth-thickness rejection, dithered start offset. Result multiplies
  the shadow term. Lives in lib/contact.glsl, called from deferred1 only.
- Shadow acne budget: normal-offset (world texel derived from distortion-local
  texel size) + slope-scaled depth bias; must hold at all five presets.

## 4. GTAO (LOCKED design)

- Horizon-based: `AO_QUALITY` 1/2/3 → (slices × steps) = (2×3)/(2×4)/(3×4).
  View-space position from depth; horizon search in screen space with per-pixel
  rotation (noisetex) + per-frame R2 offset; cosine-weighted visibility.
- Temporal accumulation in the same `deferred` pass: reproject current pixel to
  previous frame via `gbufferPreviousModelView/Projection` + `cameraPosition`
  deltas; reject history when |linear depth − history depth| relative error > ~5%
  or reprojected UV off-screen; blend factor up to ~0.9 scaled by confidence
  channel; store confidence for next frame.
- Applied in deferred1: multiplies **ambient sky, bounce, and blocklight** terms
  (NOT direct sun/moon). `AO_STRENGTH` option scales the effect via pow.
- `composite` copies colortex4 → colortex5 (with linear depth in .b) for history.

## 5. Lighting refinements (LOCKED intent, implementer tunes numbers)

- Blocklight: retune curve+intensity so a torch/campfire visibly warms a ~6-block
  radius at night (field fix #1); keep highlights below sun intensity. Add
  **lightmap-colour tinting**: sample the vanilla lightmap texture in gbuffers
  (where the `lightmap` sampler exists), store nothing new — instead derive the
  blocklight TINT in lib/lighting.glsl from the blocklight level (warm ramp:
  candle-amber high, ember-orange low). True per-source coloured light is the
  Phase 6 flood-fill tier; this is the Mac-path approximation the brief specifies.
- Hemisphere ambient: keep cool blue-purple identity but desaturate as sky
  lightmap falls (field fix #2 — caves/underwater shouldn't glow purple);
  night floor stays readable.
- All lighting maths stays in lib/lighting.glsl, shared by deferred1 + forward
  translucent passes (water/particles/entities_translucent/weather must pick up
  the same changes automatically — verify no forward pass needs new samplers
  beyond budget).

## 6. Options / profiles / GUI additions

New options (names LOCKED; all in settings.glsl with lang + screens):
`SHADOW_PCSS` (toggle, default on), `SHADOW_SAMPLES` (8/12/16/24, default 12),
`CONTACT_SHADOWS` (toggle, default off), `AO` (toggle, default on),
`AO_QUALITY` (1/2/3, default 2), `AO_STRENGTH` (0.5/0.75/1.0/1.25/1.5, default 1.0),
`BLOCKLIGHT_TINT` (toggle, default on).

Profile deltas (LOCKED):
- POTATO: `!SHADOWS !AO !CONTACT_SHADOWS` (unchanged otherwise)
- LOW: shadows on, `!SHADOW_PCSS` (plain 4-tap Vogel), `!AO`, `!CONTACT_SHADOWS`, SHADOW_SAMPLES=8
- MEDIUM (defaults): PCSS on, SHADOW_SAMPLES=12, AO on Q2, contact off
- HIGH: SHADOW_SAMPLES=16, AO_QUALITY=3, CONTACT_SHADOWS on
- ULTRA: SHADOW_SAMPLES=24, shadowMapResolution=3072 (existing), contact on
- Pass gating: `program.deferred.enabled = AO` (AO pass skipped when off; deferred1
  must then treat AO=1.0 — read gated by `#ifdef AO`).

Screens: SHADOWS screen gains PCSS/samples/contact; new AO entries under LIGHTING
(or a new AO screen if cleaner — implementer's call, keep three-way consistency).

## 7. Sampler budgets (recount and annotate)

deferred (AO): ≤5. deferred1 (lighting): colortex0,1,2,3,4 + depthtex0 + shadowtex0
+ shadowtex1 (+HW variants share bindings? NO — each declared sampler counts) +
noisetex → budget ≤12; count HW samplers separately and keep total ≤14 with margin.
composite: 3. Forward passes: must stay ≤4 each. Every changed .fsh updates its
sampler-count comment; validator enforces ≤16.

## 8. Definition of done (Phase 2)

- `tools/validate.py --target both` green (all profiles), self-test green.
- Adversarial review (shadow/AO correctness, reprojection math, Mac constraints,
  option consistency) — confirmed findings fixed and re-reviewed.
- On-device M4 check: visible soft contact-hardening shadows, AO in crevices,
  warmer/stronger blocklight, no purple cast in caves/underwater, stable perf.
- CHANGELOG 0.2.0, zip delivered.
