# ASTERIA LOOM — Minecraft Iris Shaderpack: Full Build Prompt

You are building **Asteria Loom**, a from-scratch, high-end Minecraft Java shaderpack for the **Iris** pipeline. This document is the complete, decision-locked brief. Do not re-litigate decisions marked LOCKED. Everything technical below has already been verified against the Iris docs (shaders.properties), the shaderLABS wiki, and source-level surveys of Photon, Revelation, Alpha-Piscium, Bliss, and Rethinking Voxels — treat it as ground truth, but re-verify version-specific details against the live Iris docs if something fails to compile.

---

## 1. Orchestration rules (LOCKED — read first)

- **You (the main session) are the ORCHESTRATOR ONLY.** You do not write shader code yourself. You plan, dispatch, integrate, and verify.
- **All implementation work is done by Opus subagents** (Task/Agent tool, `model: opus`), with reasoning effort tiered by difficulty:
  - **HIGH effort** — atmosphere & sky LUTs, TAA/reprojection, volumetric clouds, the End black-hole raymarcher, PCSS shadows, voxel RT GI (advanced tier).
  - **MEDIUM effort** — gbuffers programs, water/SSR/caustics, fog/aerial perspective, SSAO/GTAO, bloom chain, tonemapping/grading, flood-fill colored light, DH programs.
  - **LOW effort** — settings.glsl, shaders.properties, lang files, block.properties, CI scripts, README, repo housekeeping.
- **Full-scale mode:** each phase fans out parallel Opus implementers (one per subsystem), then **adversarial Opus reviewers** attempt to break each deliverable before integration. Reviewers specifically hunt: GL-4.1 syntax violations on the Mac path, >16 fragment samplers in any Mac-path program, missing `#ifdef` gates around compute/SSBO/image code, preset/profile combinations that fail to compile, and RENDERTARGETS/buffer-format mismatches between passes.
- A finding must be CONFIRMED by a reviewer with a concrete failure scenario before it blocks integration; fix, re-review, then integrate.
- Keep a task list current throughout; one task per subsystem per phase.

## 2. Product decisions (LOCKED — from user interview)

| Decision | Choice |
|---|---|
| Distribution | **Single auto-adapting pack.** One zip; advanced features unlock automatically on capable machines via Iris feature flags, compile out cleanly on macOS. |
| Code reuse | **100% from scratch.** Photon/Revelation/etc. are architectural reference ONLY — no copied GLSL. (Photon: study-only license. Bliss/Complementary/Rethinking Voxels/Kappa: all-rights-reserved, learn-only. Do not copy from any of them.) User owns the result; license the repo MIT unless the user says otherwise. |
| Advanced (Windows/Linux-only) tier | ALL of: flood-fill colored voxel light (LPV-style), voxel ray-traced shadows/GI, compute histogram auto-exposure, 3D-image-cached volumetric upgrades. |
| Target | **Latest Minecraft release + latest stable Iris (1.11.x line)**, Fabric. |
| Test hardware | User's **M4 Mac mini** (macOS, GL 4.1) — primary dev loop. Windows tier verified later on a Windows machine. |
| End sky | **Fully procedural raymarched black hole** (gravitational lensing, photon ring, doubled accretion disc) + purple atmospheric haze — pure fragment, macOS-compatible, rendered in the End's deferred sky pass. |
| Visual feel | **Soft filmic / dreamy**: gentle contrast, generous bloom, hazy aerial perspective, AgX-style tonemap, painterly golden hours. |
| Signature extras | ALL of: "loom" light-weave motif (interwoven crepuscular rays + woven-band aurora on clear cold nights), rich procedural night sky (galaxy band, twinkling stars, shooting stars), biome-adaptive grading, weather storytelling (storm build-up, lightning-flash illumination, post-rain wetness). |
| Distant Horizons | **Supported from day one** (dh_terrain, dh_water, dh_shadow, dhDepthTex compositing). |
| Repo | **Public GitHub repo `asteria-loom`** under the user's account, CI shader validation, tagged release zips. |
| Presets | Five profiles: **Potato, Low, Medium, High, Ultra**. High targets 60 fps @ 1080p on RTX 3060. Potato targets integrated graphics: shadows, volumetric clouds, SSR, SSAO, TAA all OFF. |

## 3. Visual specification (LOCKED — user's original spec)

**Lighting.** Warm amber sun bias at all times of day (never neutral white). Shadowed regions receive cool blue-purple sky irradiance via a hemisphere ambient model — strong warm/cool contrast is the pack's core look. PCSS with wide penumbrae (soft edges, contact-hardening). Indirect bounce approximation so unlit faces are never pure black. Emissive blocks bloom and spill light onto neighbours. Sample the block lightmap colour to tint diffuse (coloured light from redstone torches etc. even on the Mac path). SSAO contact shadows in corners/crevices/under objects. Night has a minimum cool-blue ambient floor — terrain always readable.

**Sky.** Physically based Rayleigh + Mie scattering (no static textures/gradients). Horizon visibly warmer and hazier than zenith. Colour driven by sun elevation: accurate sunrise/midday/sunset/dusk. Visible HDR sun disc with bloom and subtle lens character. **End:** merge the two reference looks — Gargantua-style black hole centrepiece surrounded by purple atmospheric haze — into one cohesive skybox.

**Clouds.** Volumetric, genuinely 3D, dark shadowed undersides, soft anti-aliased edges, zero visible grain or hard cutoffs. Layered 3D FBM/Worley noise shaping. Density and coverage vary with weather state.

**Fog.** Aerial perspective, not uniform density: distance shifts things bluer and desaturated. Colour/density vary by time of day, weather, and biome. No flat cutoffs.

**Water.** SSR reflecting sky + geometry. Animated voronoi caustics projected on seabed and nearby surfaces. Real specularity + normal-mapped ripples. Underwater: refraction-style distortion, volumetric haze, green-blue tint.

**Temporal stability.** TAA in every preset except Potato. Temporal accumulation on shadows and SSAO where possible.

## 4. Hard platform constraints (verified research — do not violate)

**macOS = OpenGL 4.1 core, permanently.** Unavailable on Mac at any cost: compute shaders (4.3), SSBOs (4.3), image load/store & atomic counters (4.2). Tessellation (4.0) IS available. Additionally macOS enforces a **hard 16 active fragment-sampler limit per program** — this is what breaks Bliss on Apple Silicon. Iris on Mac exposes all 16 colortex buffers (unlike OptiFine's 8). Budget samplers explicitly for every Mac-path program.

**Capability gating — the single-codebase mechanism:**
```
# shaders.properties
iris.features.optional = COMPUTE_SHADERS SSBO CUSTOM_IMAGES SEPARATE_HARDWARE_SAMPLERS
```
Each optional flag Iris supports emits `IRIS_FEATURE_<NAME>`. Combine with the OS macro:
```glsl
#if defined IRIS_FEATURE_COMPUTE_SHADERS && defined IRIS_FEATURE_SSBO \
    && defined IRIS_FEATURE_CUSTOM_IMAGES && !defined MC_OS_MAC
    #define AL_ADVANCED_TIER
#endif
```
Gate ALL advanced-tier programs, samplers, and declarations behind `AL_ADVANCED_TIER`. The Mac build must never even *see* GL 4.2+ syntax. Never use `#version` above what Mac supports in shared files; Iris recommends `#version 330 compatibility` (its patcher normalizes profiles). Useful macros: `MC_OS_MAC/WINDOWS/LINUX`, `MC_GL_VERSION` (e.g. 410/460), `MC_GLSL_VERSION`, `IS_IRIS`, `DISTANT_HORIZONS`, `MC_GL_VENDOR_*`.

**Feature split (verified):** GL 4.1 CAN do — PCSS, SSR, TAA, fragment-raymarched volumetric clouds/fog/god rays, SSAO/GTAO, analytic/LUT atmospheric scattering, bloom, DOF, tonemapping, the black-hole raymarch, lightmap-tinted coloured light. GL 4.3+ ONLY — flood-fill voxel coloured light (3D image ping-pong), voxel RT shadows/GI, LPV, compute histogram exposure (Mac fallback: mipmap-average exposure), clustered lighting, 3D-cached volumetrics.

## 5. Iris pipeline facts (verified — architecture must follow these)

**Pass order per frame:** `setup` (compute-only, runs once) → `begin` → `shadow` + `shadowcomp` → `prepare` → opaque gbuffers → `deferred*` → translucent gbuffers → `composite*` → `final`. Numbered passes run ascending; compute (`.csh`) allowed in setup/begin/shadowcomp/prepare/deferred/composite/final, never gbuffers/shadow.

**Buffers:** colortex0–15 (Iris 1.10.5+ allows up to 31; stay ≤15 for safety). Write-target selection via `/* RENDERTARGETS: 6,2,5 */` (modern form, use exclusively). Formats via `const int colortexNFormat = RGBA16F;` — prefer `R11F_G11F_B10F` where alpha isn't needed. Ping-pong flipping is automatic between passes (`flip.<program>.<buffer>` to override). Depth: depthtex0 (all), depthtex1 (no translucents), depthtex2 (no translucents/hand). Shadow: shadowtex0/1, shadowcolor0/1; for PCSS use `shadowHardwareFiltering=true` + `SEPARATE_HARDWARE_SAMPLERS` flag so `shadowtex0HW` does hardware PCF while raw depth stays readable on shadowtex0 (needed for blocker search). noisetex = 256×256 RGB8; supply a custom blue-noise via `texture.noise = ...`.

**Key gbuffers programs** (fallback chain in parens): terrain(→textured_lit), water(→terrain), entities, block, hand, hand_water, weather, skybasic, skytextured, clouds, particles (Iris-split translucent variants exist; use `separateEntityDraws=true` for hybrid deferred translucents). Minimum viable pack = gbuffers_basic + shadow + composite + final.

**Dimensions:** once any `worldN` folder exists, shaders load ONLY from worldN folders — cover world0 (Overworld), world-1 (Nether), world1 (End). The End's custom sky lives in `world1/`: override gbuffers_skybasic/skytextured (use `renderStage` to suppress vanilla stars/void) and raymarch the black hole + haze in a `deferred` pass against far-plane depth. End flash uniforms available: `endFlashPosition`, `endFlashIntensity`.

**Profiles (the preset mechanism):**
```
profile.POTATO = !SHADOWS !VOLUMETRIC_CLOUDS !SSR !SSAO !TAA !program.deferred1 ...
profile.HIGH   = profile.MEDIUM SHADOW_SAMPLES=16 VC_QUALITY=2 ...
screen = <profile> [LIGHTING] [SKY] [WATER] [POST] ...
```
Real perf wins come from `!program.<name>` (pass not even dispatched), not just #defines. Options are `#define` comments in GLSL (`#define X 4 // [1 2 4 8]` → auto GUI; `sliders = ...` in shaders.properties). All tunables live in a heavily commented **settings.glsl** included everywhere; shaders.properties holds profiles/screens/buffer configs. Localize via `lang/en_us.lang`.

**Weather/environment uniforms for the spec:** `rainStrength`, `wetness`, `thunderStrength` (Iris), `lightningBoltPosition` (Iris), `biome`/`biome_category`/`temperature`/`rainfall` (Iris) for biome-adaptive grading/fog, `sunAngle`, `moonPhase`, `isEyeInWater` (1 water/2 lava/3 powder snow), `eyeBrightnessSmooth`, `fogColor`/`skyColor`.

**Distant Horizons:** `#ifdef DISTANT_HORIZONS`; programs `dh_terrain`, `dh_water`, `dh_shadow` (compatibility profile required); uniforms `dhProjection*`, `dhNearPlane/dhFarPlane`, `dhRenderDistance`; depth `dhDepthTex0/1`; `dhMaterialId` with `DH_BLOCK_*` constants. Composite near-field depthtex with DH far-field everywhere fog/sky/SSR read depth.

**Dev workflow:** live shaderpack folder in `.minecraft/shaderpacks/`; `R` hot-reloads; Ctrl+D debug mode shows compile errors; Iris dumps preprocessed GLSL to `.minecraft/patched_shaders/` — error line numbers refer to patched files. CI: run `glslangValidator` against patched-shader dumps (raw source contains non-standard Iris directives), or a strip-and-stub preprocessor step.

## 6. Technique guidance (from source-level survey; implement from scratch)

- **PCSS:** blocker search (Vogel disc, ~3–4 taps) → penumbra estimate from blocker depth → Vogel-disc PCF with dynamic tap count (8–16 on High), rotated per-pixel by blue-noise + frame-index (R1/R2 sequence). Shadow-map distortion warp concentrates resolution near camera so 2048–3072 maps suffice. Screen-space contact-shadow raymarch for fine detail.
- **Clouds:** raymarch 2 layers (cumulus + cirrus) with 3D Worley/FBM (two frequencies: base shape + detail erosion), view-adaptive primary steps (more at horizon), few light steps with exponential step growth, multiple-scattering approximation (Wrenninge-style octaves: per-octave extinction/phase decay), powder effect, ambient sky term. **Render at half res and temporally reproject/upscale** — this is the crucial perf trick. Cloud shadows projected onto terrain. Coverage driven by `mix(clear, storm, rainStrength)`.
- **Atmosphere:** analytic Rayleigh+Mie+ozone with Chapman-function transmittance (LUT-free is fine at this scope), Henyey-Greenstein phase (g≈0.76). Render the full sky ONCE per frame into a small sky map/LUT buffer, then sample it everywhere (sky pixels, reflections, ambient); derive the hemisphere ambient (cool sky fill) from it. Warm amber sun bias applied to direct light colour; horizon-warmth handled in the sky model, not a grade hack.
- **TAA:** camera jitter (Halton 2,3), closest-depth 3×3 velocity dilation, reprojection, neighbourhood clamp in YCoCg (variance clip), history blend ~0.9 with off-screen/disocclusion rejection, blend in tonemapped space. Optional TAAU render-scale (0.7–0.85) as High/Ultra perf lever.
- **SSAO/GTAO:** horizon-based, 2 slices × 3–4 steps at High, blue-noise rotated, temporally accumulated, bilateral-upsampled from half res.
- **Water:** normal-mapped Gerstner-ish ripples; SSR = screen-space depth raymarch (16–32 steps, binary-search refine) with sky-map fallback; voronoi caustics animated 2-octave, projected along light dir onto submerged surfaces; underwater volumetric haze via short raymarch + `isEyeInWater` tint/distortion.
- **Bloom:** mip-chain dual-filter (13-tap downsample, tent upsample), threshold-free (energy-conserving), drives emissive spill. **Tonemap:** AgX-style with soft-filmic grade; exposure via mipmap-average (Mac) / compute histogram (advanced tier).
- **Black hole (End):** fragment raymarch in world1 deferred sky pass: bend view rays with an impact-parameter approximation of Schwarzschild lensing (no full geodesic integration needed), sample procedural accretion disc (temperature gradient → warm inner/cool outer, doppler brightening on approach side), photon ring from ray-capture threshold, background = procedural starfield + purple Rayleigh-ish haze fading up from horizon; End fog tinted to match.
- **Flood-fill coloured light (advanced tier):** voxelize block IDs in shadow pass; 3D custom image ping-pong (`AL_ADVANCED_TIER` only), compute pass propagates 6-neighbour with decay per frame; falls back to lightmap-colour tinting on Mac.
- **Perf budget (High/RTX 3060/1080p/60fps):** half-res temporally-upscaled volumetrics, sky-once-per-frame LUT, deferred shading, temporal amortization everywhere, mip bloom, distortion-warped 2048 shadow map. These levers are proven sufficient.

## 7. Repository & deliverables

Use public GitHub repo attached to project **: `shaders/` (pack source, layout per §5), `docs/` (architecture, per-subsystem notes), `.github/workflows/validate.yml` (CI: preprocess + glslangValidator over every program × every profile), `tools/` (packaging + validation scripts), README with install instructions + screenshots, LICENSE (MIT), CHANGELOG. Tagged releases ship the installable zip (zip root = `shaders/` folder). Deliver a zip to the user at the end of every phase for on-Mac testing.

## 8. Build phases (each = fan-out implementers → adversarial review → integrate → deliver zip)

1. **Scaffold + foundation** — repo, CI, settings.glsl skeleton, shaders.properties with all five profiles + screens, full gbuffers set writing a well-defined G-buffer, basic deferred shading, final pass. Loads and renders correctly on the Mac at this point.
2. **Lighting & shadows** — PCSS + distortion + contact shadows, hemisphere ambient (warm/cool contrast), lightmap-colour tinting, SSAO/GTAO + temporal accumulation, night ambient floor.
3. **Sky, clouds, fog** — atmosphere model + sky map, sun disc, volumetric clouds + temporal upscale + cloud shadows, aerial perspective + biome/weather fog, rich night sky.
4. **Water & post** — SSR, caustics, underwater; TAA; bloom; AgX grade + biome-adaptive grading; weather storytelling.
5. **Dimensions & extras** — End black hole + purple haze (world1), Nether pass (world-1), loom crepuscular rays + aurora, DH programs.
6. **Advanced tier (Windows)** — flood-fill coloured light, voxel RT shadows/GI, histogram exposure, 3D-cached volumetrics; all cleanly gated; verify Mac build unaffected.
7. **Tuning & release** — per-profile perf validation (Potato→Ultra each meaningfully distinct), sampler audits, README/screenshots, v1.0.0 release.

**Definition of done per phase:** every program compiles under Iris on macOS (user hot-reloads with R and reports/screenshots), CI green across all profiles, adversarial review findings resolved, zip delivered, CHANGELOG updated.

Begin with Phase 1. Ask the user only when a decision is genuinely theirs; otherwise proceed.
