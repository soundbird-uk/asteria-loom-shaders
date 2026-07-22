# Asteria Loom — Phase 1 Architecture Contract (LOCKED)

This document is the binding contract for Phase 1 (scaffold + foundation). Every
implementer and reviewer works against this. Deviations require orchestrator sign-off.
The full product brief lives at `docs/brief.md` — read it first.

## 0. Scope of Phase 1

Deliver a pack that **loads and renders correctly under Iris on macOS (GL 4.1)**:

- Repo scaffold: README, LICENSE (MIT), CHANGELOG, .gitignore, docs.
- CI: strip-and-stub preprocessor + `glslangValidator` over every program × every profile.
- `shaders/` source: `shaders.properties` with all five profiles + settings screens,
  heavily commented `settings.glsl`, full gbuffers set writing a well-defined G-buffer,
  a shadow pass (provisional simple shadows — PCSS is Phase 2), basic deferred shading
  honouring the pack's warm-sun / cool-ambient identity, composite passthrough, final
  pass with exposure + placeholder filmic tonemap + optional debug views.

Explicitly OUT of Phase 1: PCSS/shadow distortion, SSAO, TAA, volumetric clouds,
atmosphere model, SSR, bloom, AgX grade, DH programs, world folders, advanced tier.
Do not add half-implementations of these; leave clean seams (documented TODOs).

## 1. Repository layout

```
/                       repo root
├── shaders/            ← the pack (zip root when packaged; folder dropped into shaderpacks/)
│   ├── shaders.properties
│   ├── settings.glsl           # every tunable; included by all programs
│   ├── lang/en_us.lang
│   ├── lib/                    # shared includes only, no programs
│   │   ├── common.glsl         # constants, small helpers, debug plumbing
│   │   ├── encoding.glsl       # octahedral normal encode/decode, material ID pack
│   │   ├── color.glsl          # sRGB<->linear, luminance, tonemap placeholder
│   │   ├── lighting.glsl       # phase-1 lighting model (shared by deferred + forward translucents)
│   │   ├── shadow.glsl         # shadow-space transforms, provisional sampling
│   │   └── space.glsl          # screen<->view<->world transforms
│   ├── shadow.vsh/.fsh
│   ├── gbuffers_*.vsh/.fsh     # see §3
│   ├── deferred.vsh/.fsh
│   ├── composite.vsh/.fsh
│   └── final.vsh/.fsh
├── docs/
├── tools/                      # validate.py, package.py
└── .github/workflows/validate.yml
```

No `worldN` folders in Phase 1 (once any exists Iris loads ONLY worldN folders;
migration happens in Phase 5 via 2-line include shims per program — note this in docs).

## 2. GLSL conventions (Mac-safe, all phases)

- Every program starts `#version 330 compatibility` and `#include "/settings.glsl"`.
- Nothing beyond GLSL 3.30 syntax in any file: **no** `packUnorm2x16`/`packHalf2x16`
  (GLSL 4.00+), no explicit binding/location layout qualifiers on samplers/uniforms,
  no compute/SSBO/image syntax anywhere in Phase 1. Manual bit packing only via
  float math within channel precision.
- Write-target selection: `/* RENDERTARGETS: N,M */` (modern form) in every fragment
  program, matching exactly the `layout` of what it writes (order = out variable order,
  declared as `out vec4 outN;` in declaration order).
- Buffer format `const` declarations live in **one canonical file**: `final.fsh`
  (comment block near the top). Nowhere else.
- Include guards in every lib file (`#ifndef AL_LIB_X ... #define AL_LIB_X ... #endif`).
- Prefix all pack-internal defines/macros `AL_` except user-facing option defines
  (those live in settings.glsl and are named plainly, e.g. `SHADOWS`).
- Fragment sampler budget: **hard max 16 per program**; each program file carries a
  comment listing its sampler count. Phase 1 programs should be ≤8.
- Uniforms: declare only what each program uses (sampler count discipline).
- `alphaTestRef` uniform for cutout alpha testing in terrain/entities/particles.

## 3. Program set + G-buffer layout (LOCKED)

### Buffers

| Buffer | Format | Contents | Cleared |
|---|---|---|---|
| colortex0 | RGBA16F | HDR scene colour (sky from skybasic/skytextured, lit scene from deferred, translucents/weather forward-blend on top) | yes (0,0,0,0) |
| colortex1 | RGBA8 | G-buffer: albedo.rgb, a = vanilla AO/spare | yes |
| colortex2 | RGBA16 | G-buffer: octahedral normal in .rg, lightmap (block,sky) in .ba | yes |
| colortex3 | RGBA8 | G-buffer: r = material ID /255, g = flag bits (see encoding.glsl), ba spare | yes |

depthtex0/1 as usual. Shadow: shadowtex0/1 (+ shadowcolor0 declared for Phase 2, unused now).
Stay within colortex0–3 for Phase 1. Formats + `shadowMapResolution` etc. declared in `final.fsh` only.

### Opaque gbuffers → write G-buffer (`RENDERTARGETS: 1,2,3`)

`gbuffers_terrain`, `gbuffers_entities`, `gbuffers_block`, `gbuffers_hand`,
`gbuffers_basic`, `gbuffers_textured`, `gbuffers_textured_lit`, `gbuffers_particles`
(particles opaque path). They do **no lighting** — albedo (texture × vertex colour ×
`entityColor` where relevant), encoded normal, lightmap, material ID. Cutout via alphaTestRef.

### Sky programs → write colour directly (`RENDERTARGETS: 0`)

`gbuffers_skybasic` (vanilla sky gradient reproduced simply; suppress vanilla stars via
renderStage check — procedural sky is Phase 3), `gbuffers_skytextured` (sun/moon textures,
modest HDR boost e.g. ×3 so the sun reads through tonemap), `gbuffers_clouds`
(vanilla clouds, simple lit forward — a `VANILLA_CLOUDS` toggle defaults ON until Phase 3).

### shadow (vsh/fsh)

Plain depth-only render (fragment samples gtexture for cutout alpha only; sampler count 1).
No distortion in Phase 1 (Phase 2 adds warp — keep the shadow-space math in `lib/shadow.glsl`
so the warp slots in one place). `shadowMapResolution` from settings (default 2048),
`shadowDistance` 128.

### deferred (vsh/fsh) — fullscreen

Reads colortex0 (sky), colortex1/2/3, depthtex0, shadowtex1, noisetex if needed.
Writes `RENDERTARGETS: 0`. If depth==1.0 → pass sky colour through. Else Phase 1 lighting:

- **Direct sun/moon**: warm amber sun colour (settings; never neutral white) ×
  NdotL × provisional shadow (single/2×2 tap from shadowtex1 with normal-offset +
  slope-scaled bias; behind `SHADOWS` define). Moonlight cool + dim at night via
  `sunAngle`-derived day factor.
- **Sky ambient (hemisphere)**: cool blue-purple ambient colour (settings) ×
  lightmap.sky² × (0.6 + 0.4 × wrap on N·up) — shadowed regions read cool. Night floor:
  clamp ambient to a minimum cool-blue so terrain stays readable.
- **Blocklight**: warm torch colour × animated-free simple curve of lightmap.block.
- **Fallback bounce term**: small albedo-tinted constant so unlit faces are never black.

Keep the whole model in `lib/lighting.glsl` so translucent forward passes reuse it.

### Translucent forward (`RENDERTARGETS: 0`, blend on)

`gbuffers_water` (lit forward with same lighting lib; plain vanilla-texture water for now,
slightly tinted/transparent — real water is Phase 4), `gbuffers_hand_water`,
`gbuffers_weather` (rain/snow, faint, lightmap-lit).

### composite (vsh/fsh)

Structural passthrough of colortex0 (reserved seam for Phases 2–4). Cheap; keep it
(documented) so the pass chain shape is stable.

### final (vsh/fsh)

Exposure (fixed `EXPOSURE` slider for now) → placeholder filmic tonemap (simple
Hejl/ACES-fit style, clearly marked for replacement by AgX in Phase 4) → linear→sRGB →
optional `DEBUG_VIEW` (0 off / albedo / normals / lightmap / depth / material ID).
Holds the canonical buffer-format const block.

## 4. shaders.properties (LOCKED shape)

- `iris.features.optional = COMPUTE_SHADERS SSBO CUSTOM_IMAGES SEPARATE_HARDWARE_SAMPLERS`
  (future-proofing; nothing uses them yet).
- `separateEntityDraws = true`. `shadowHardwareFiltering = false` for now (Phase 2 flips).
- `program.shadow.enabled = SHADOWS` so Potato genuinely skips the pass.
- Five profiles: `profile.POTATO/LOW/MEDIUM/HIGH/ULTRA`, each building on the previous
  where sensible. Phase 1 differentiators: `SHADOWS` on/off, `shadowMapResolution`
  (1024/1536/2048/2048/3072), `VANILLA_CLOUDS`. Only reference options that exist.
  Comment placeholders for future per-phase settings — do NOT invent dead options.
- `screen = <profile> <empty> [LIGHTING] [SKY] [POST] [DEBUG]` with sub-screens; every
  option in settings.glsl appears in exactly one screen; `sliders = ...` for numerics.
- Defaults = MEDIUM-equivalent values.

## 5. settings.glsl

Single include, heavily commented, sectioned (Profiles note / Lighting / Shadows / Sky /
Post / Debug). Option syntax `#define X 4 // [1 2 4 8]` for GUI. Colour identity constants
(warm sun tint, cool ambient tint, torch colour, night floor) live here as tweakable
defines with comments explaining the visual intent.

## 6. lang/en_us.lang

`option.X`, `option.X.comment`, `value.X.N`, `profile.POTATO`… entries for every option +
profile, screen titles. Tone: short, friendly, descriptive.

## 7. CI / tools contract

- `tools/validate.py` (python3, stdlib only): for each profile × each program:
  1. Resolve `#include` (Iris semantics: absolute `/path` from shaders/ root, else relative).
  2. Strip/translate Iris-isms: `/* RENDERTARGETS: */` comments stay (they're comments);
     inject `#define` set for the profile (parse shaders.properties profiles incl.
     `profile.X = profile.Y ...` chaining and `!DEFINE` removal); stub Iris-injected
     uniforms ONLY if missing (prefer real declarations in source).
  3. Emit patched file, run `glslangValidator` with correct stage flag (.vsh→vert,
     .fsh→frag); collect and report all failures; non-zero exit on any.
  4. Also assert: every `.fsh` has RENDERTARGETS or is shadow/final; sampler count per
     fragment program ≤16 (grep `sampler` declarations post-include); formats declared
     exactly once.
- `tools/package.py`: build `AsteriaLoom-<version>.zip` with the **contents of
  `shaders/`** under a top-level `shaders/` dir in the zip (Iris expects zip root to
  contain the `shaders` folder), version from CHANGELOG or `--version`.
- `.github/workflows/validate.yml`: ubuntu-latest, install glslang (apt
  `glslang-tools`), run validate.py across all profiles, then package.py as artifact.

## 8. Definition of done (Phase 1)

- `tools/validate.py` green for all five profiles locally and in CI.
- Reviewer findings CONFIRMED-with-scenario are fixed and re-reviewed.
- Zip delivered to user for M4 Mac hot-reload testing; CHANGELOG updated.
