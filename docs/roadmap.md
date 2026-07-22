# Asteria Loom — Roadmap

The build is staged into seven phases (from the product brief, §8). Each phase is a
self-contained milestone: implement, adversarially review, integrate, and deliver a testable
zip. This checklist tracks scope at a glance; the brief is authoritative for detail.

Legend: `[x]` done · `[ ]` planned.

## Phase 1 — Scaffold & foundation _(current)_

- [x] Public repo, MIT license, CHANGELOG, `.gitignore`, contributor docs
- [x] CI: strip-and-stub preprocessor + `glslangValidator` over every program × every profile
- [x] `settings.glsl` skeleton (heavily commented, color-identity constants)
- [x] `shaders.properties` with all five profiles + settings screens
- [x] Full gbuffers set writing a well-defined G-buffer
- [x] Provisional simple shadow pass (depth-only, `SHADOWS`-gated)
- [x] Basic deferred shading with warm-sun / cool-ambient identity
- [x] Composite passthrough + final pass (exposure, placeholder tonemap, debug views)
- [x] Loads and renders correctly under Iris on macOS (GL 4.1)

## Phase 2 — Lighting & shadows

- [ ] PCSS with blocker search + wide penumbrae, shadow-map distortion warp
- [ ] Screen-space contact shadows
- [ ] Hemisphere ambient (warm/cool contrast) driven from the sky
- [ ] Lightmap-color tinting of diffuse (colored light on the Mac path)
- [ ] SSAO/GTAO with temporal accumulation
- [ ] Night ambient floor for readability

## Phase 3 — Sky, clouds & fog

- [ ] Analytic Rayleigh + Mie + ozone atmosphere, rendered once per frame into a sky LUT
- [ ] HDR sun disc with bloom and lens character
- [ ] Volumetric clouds (2 layers) with half-res temporal upscale + cloud shadows
- [ ] Aerial-perspective fog varying by time, weather, and biome
- [ ] Rich procedural night sky (galaxy band, twinkling + shooting stars)

## Phase 4 — Water & post

- [ ] Screen-space reflections with sky-map fallback
- [ ] Animated voronoi caustics + normal-mapped ripples
- [ ] Underwater refraction distortion + volumetric haze
- [ ] TAA (jitter, reprojection, neighbourhood clamp)
- [ ] Mip-chain bloom + emissive spill
- [ ] AgX-style tonemap + biome-adaptive grading
- [ ] Weather storytelling (storm build-up, lightning flash, post-rain wetness)

## Phase 5 — Dimensions & extras

- [ ] `world1` End: raymarched black hole (lensing, photon ring, accretion disc) + purple haze
- [ ] `world-1` Nether pass
- [ ] "Loom" light-weave motif: interwoven crepuscular rays + woven-band aurora
- [ ] Distant Horizons programs (`dh_terrain`, `dh_water`, `dh_shadow`, depth compositing)
- [ ] `worldN` folder migration via include shims

## Phase 6 — Advanced tier (Windows/Linux)

- [ ] Flood-fill colored voxel light (LPV-style, 3D image ping-pong)
- [ ] Voxel ray-traced shadows / GI
- [ ] Compute histogram auto-exposure (Mac fallback: mipmap-average)
- [ ] 3D-image-cached volumetric upgrades
- [ ] All gated behind `AL_ADVANCED_TIER`; Mac build verified unaffected

## Phase 7 — Tuning & release

- [ ] Per-profile performance validation (Potato→Ultra each meaningfully distinct)
- [ ] Sampler-count audits across all programs
- [ ] README screenshots + polish
- [ ] v1.0.0 tagged release
