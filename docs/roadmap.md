# Asteria Loom — Roadmap

The build is staged into seven phases (from the product brief, §8). Each phase is a
self-contained milestone: implement, adversarially review, integrate, and deliver a testable
zip. This checklist tracks scope at a glance; the [changelog](../CHANGELOG.md) is the
authoritative release history and the brief is authoritative for detail.

Legend: `[x]` done · `[~]` implemented, pending field verification · `[ ]` planned.

## Phase 1 — Scaffold & foundation _(complete, released 0.1.0)_

- [x] Public repo, MIT license, CHANGELOG, `.gitignore`, contributor docs
- [x] CI: strip-and-stub preprocessor + `glslangValidator` over every program × every profile
- [x] `settings.glsl` skeleton (heavily commented, color-identity constants)
- [x] `shaders.properties` with all five profiles + settings screens
- [x] Full gbuffers set writing a well-defined G-buffer
- [x] Provisional simple shadow pass (depth-only, `SHADOWS`-gated)
- [x] Basic deferred shading with warm-sun / cool-ambient identity
- [x] Composite passthrough + final pass (exposure, placeholder tonemap, debug views)
- [x] Loads and renders correctly under Iris on macOS (GL 4.1)

_Field hardening (0.1.1): moved buffer-format directives into a comment block and made
`shadowMapResolution`/`shadowDistance` literal const GUI options — the M4 Mac couldn't
compile `final.fsh` and silently ignored shadow-map sizing until this._

## Phase 2 — Lighting & shadows _(complete, released 0.2.0)_

- [x] PCSS with blocker search + wide penumbrae, shadow-map distortion warp
- [x] Screen-space contact shadows (High/Ultra)
- [x] Hemisphere ambient (warm/cool contrast) driven from the sky
- [x] Lightmap-color tinting of diffuse (colored light on the Mac path)
- [x] GTAO with temporal accumulation
- [x] Night ambient floor for readability, warm blocklight ramp

_Field hardening (0.2.1): fixed a never-cleared AO-history buffer whose undefined/NaN first
frame blackened the whole world on Apple GL, distance shadows deleted by distortion-scaled
bias, ice moiré, a missing profile selector in the GUI, and over-bright washed-out nights._

## Phase 3 — Sky, clouds & fog _(complete, released 0.3.0)_

- [x] Analytic Rayleigh + Mie + ozone atmosphere, baked once per frame into a sky-view LUT
- [x] Procedural limb-darkened HDR sun disc
- [x] Volumetric clouds (2 layers) with temporal accumulation + cloud shadows
- [x] Aerial-perspective fog varying by time, weather, and biome
- [x] Rich procedural night sky (galaxy band, twinkling + shooting stars)

_Field hardening (0.3.1): forensic hotfix — replaced the platform-split hardware-sampler
shadow path with one software compare path (shadows were missing on Windows / over-dark on
Mac), stopped aerial fog flooding the frame with sky colour on non-finite optical depth,
re-lifted night to the 0.1.1 reference, fixed submerged-terrain purple banding and dark
particles. (0.3.2) cloud temporal-history veil rejected off-screen, a much slower default
cloud speed, clouds/fog dissolving into the same distance haze, render-distance seam
removed, softened sunset white-out. (0.3.3) properly dark scene-toned nights and thicker,
darker fog on one shared day/night ramp._

## Phase 4 — Water & post _(implemented, in adversarial review — 0.4.0 pending)_

- [~] Screen-space reflections with sky-map fallback
- [~] Animated caustics + normal-mapped water ripples + depth-based absorption
- [~] Underwater refraction distortion + volumetric media (lava/powder-snow variants)
- [~] TAA (Halton jitter, reprojection, neighbourhood clamp; off on Potato)
- [~] Mip-chain bloom + emissive spill
- [~] AgX tonemap + mip-average auto-exposure with temporal adaptation
- [~] Biome-adaptive grading + weather storytelling (rain, thunder, wetness, lightning flash)

_Code-complete and green in CI across all profiles; not yet verified on-device. Field
hardening notes will be added once 0.4.0 ships._

## Phase 5 — Dimensions & extras

- [ ] `world1` End: raymarched black hole (lensing, photon ring, accretion disc) + purple haze
- [ ] `world-1` Nether pass
- [ ] "Loom" light-weave motif: interwoven crepuscular rays + woven-band aurora
- [ ] Distant Horizons programs (`dh_terrain`, `dh_water`, `dh_shadow`, depth compositing)
- [ ] `worldN` folder migration via include shims

## Phase 6 — Advanced tier (Windows/Linux)

- [x] `AL_ADVANCED_TIER` gate + `[ADVANCED]` options; CI compiles `.csh` on the
      `advanced` target only; Mac matrix proven byte-identical (compiles out)
- [x] Compute histogram auto-exposure (Mac fallback: mipmap-average)
- [ ] Flood-fill colored voxel light (LPV-style, 3D image ping-pong)
- [ ] Voxel ray-traced shadows / GI
- [ ] 3D-image-cached volumetric upgrades

_Advanced-tier features are syntax-validated by the CI compile gate only — no GPU
in CI, maintainer on macOS — so they are compute-capable scaffolding, not yet
runtime-verified. All gated behind `AL_ADVANCED_TIER`; the portable path (macOS
included) is unaffected. See `docs/architecture/phase6-contract.md`._

## Phase 7 — Tuning & release

- [ ] Per-profile performance validation (Potato→Ultra each meaningfully distinct)
- [ ] Sampler-count audits across all programs
- [ ] README screenshots + polish
- [ ] v1.0.0 tagged release
