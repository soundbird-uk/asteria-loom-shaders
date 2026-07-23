# Asteria Loom — Phase 4 Architecture Contract (LOCKED)

Binding contract for Phase 4 (water & post: SSR, caustics, underwater; TAA; bloom;
AgX grade + biome-adaptive grading; weather storytelling). Phase 1-3 contracts stay
in force. Brief: docs/brief.md §3 (Water, Temporal stability, Visual feel), §6
(Water/Bloom/Tonemap/TAA guidance), §8.4. Standing LAWS: NaN-proof range-validated
reads on every clear=false buffer (fail toward identity/transparent); formats only
in final.fsh's comment block; three-way option consistency; surgical edits in
shared files; Mac GL4.1 only (no compute/SSBO/images/scale directives).

## 0. Field-tuning context (binding tone guidance)

The user's on-device verdicts so far: nights must be dark/moody (fix in flight),
fog thicker + darker/scene-toned (fix in flight), soft dreamy identity confirmed.
Phase 4's grade must PRESERVE the fixed tone work — AgX replaces the placeholder
tonemap but the perceived brightness/mood at noon/night must carry over (calibrate
so the default AgX look matches current exposure targets within ~10%, then improve
contrast character, not levels).

## 1. Pass chain after Phase 4 (LOCKED — includes renames)

The orchestrator performs the mechanical renames BEFORE implementation wave:
current composite(clouds)→composite1, current composite1(fog)→composite2
(properties gate becomes program.composite2.enabled = AERIAL_FOG). Then:

| Pass | Role | Writes |
|---|---|---|
| deferred | GTAO (unchanged) | 4 |
| deferred1 | Lighting (unchanged this phase) + CAUSTICS on submerged opaques (see §3) | 0 |
| translucents | gbuffers_water now ALSO writes surface data (see §3) | 0 + 2,3 |
| **composite** (NEW) | WATER effects: SSR on water/ice, absorption tint of submerged scene | 0 |
| composite1 | Volumetric clouds + AO/cloud histories (former composite; unchanged) | 0,5,7 |
| composite2 | Aerial fog + UNDERWATER medium (former composite1 + §3 underwater) | 0 |
| **composite3** (NEW) | TAA resolve | 0,8 |
| **composite4** (NEW) | Bloom downsample tile chain | 9 |
| **composite5** (NEW) | Bloom upsample/combine + apply to scene | 0 |
| final | Exposure (mip-average + temporal) → AgX → biome/weather grade → sRGB + debug views | — |

## 2. New buffers (ATMOSPHERE-agent-style: formats added to final.fsh comment block by the TAA agent)

| Buffer | Format | Contents | Clear |
|---|---|---|---|
| colortex8 | RGBA16F | TAA history (rgb colour, a = blend confidence) | **no** (NaN-law) |
| colortex9 | RGBA16F | Bloom tile atlas (mip chain packed as tiles, documented layout in lib/bloom.glsl) | yes |

colortex5.a (spare channel of AO history) additionally carries the ADAPTED EXPOSURE
value at texel (0,0), written by final's predecessor chain — see §6. (Document in
final.fsh; writes must preserve the AO history rgb semantics exactly.)

## 3. Water (WATER agent — HIGH effort)

- **gbuffers_water rewrite**: procedural animated ripples — 2-3 octave directional
  wave-noise normal perturbation (Gerstner-flavoured, wind-aligned, subtle; pure
  math, frameTimeCounter), Fresnel-driven opacity, water tinted by biome water
  colour (glcolor). CRITICAL ARCHITECTURE: after deferred1 has consumed the opaque
  G-buffer, translucents may overwrite it — gbuffers_water now ALSO writes
  `RENDERTARGETS: 0,2,3`: colortex2 = water surface octahedral normal + lightmap,
  colortex3 = matID WATER (+ flags). Ice (translucent) keeps its current path
  (no SSR this phase; matID stays non-water). hand_water minimal (no G-buffer
  write; RENDERTARGETS: 0 only).
- **composite (NEW pass)**: for matID==WATER pixels — SSR: screen-space raymarch
  in view space against depthtex0 (16/24/32 steps by SSR_QUALITY with binary-search
  refine, thickness heuristic, dithered start), reflecting the post-translucent
  colortex0; ray-miss/off-screen fallback = alSkySample(reflectDir) (+ night sky
  handled by sky sample being dark — acceptable). Fresnel blend (Schlick, f0≈0.02)
  over the water colour. Also applies ABSORPTION to the submerged scene: where
  depthtex0 (water surface) differs from depthtex1 (opaque behind), tint the
  opaque contribution by water-depth-dependent Beer-Lambert (green-blue). Budget
  ≤8 samplers.
- **Caustics** (in deferred1, small surgical addition — coordinate: WATER agent
  owns this edit): for submerged opaques (pixel where depthtex1 < ... actually at
  deferred1 time translucents haven't drawn; detect submersion by world height vs
  sea level is wrong — INSTEAD apply caustics in the composite pass to the
  absorbed scene: animated 2-octave voronoi-ish caustic pattern projected along
  the sun direction onto the submerged surface position, modulating the submerged
  scene contribution (±30% max), fading with water depth and sky lightmap. This
  keeps deferred1 untouched. Document.
- **Underwater medium (composite2 surgical addition — WATER agent edits ONLY the
  isEyeInWater branch that currently skips fog)**: when isEyeInWater==1: blue-green
  exponential distance haze toward a depth-dimmed water colour, gentle UV
  refraction wobble of the scene sample (small amplitude, time-animated), and the
  existing aerial fog stays skipped. isEyeInWater==2 (lava): simple dense warm
  haze; ==3 (powder snow): dense white haze. Keep every NaN fail-safe pattern.
- Options: `SSR` toggle (on), `SSR_QUALITY` 1/2/3 (default 2 → 16/24/32 steps),
  `WATER_WAVES` toggle (on), `WATER_CAUSTICS` toggle (on), new [WATER] screen.
  Profiles: POTATO !SSR !WATER_CAUSTICS (waves stay — cheap); LOW SSR_QUALITY=1;
  MEDIUM 2; HIGH 2; ULTRA 3.

## 4. TAA (TAA agent — HIGH effort)

- `lib/jitter.glsl`: `vec4 alJitter(vec4 clipPos)` applying Halton(2,3) 8-sample
  sub-pixel jitter (scaled by 1/viewWidth,1/viewHeight uniforms, frameCounter mod 8),
  behind `#ifdef TAA` (identity otherwise). Applied as the LAST line of gl_Position
  in EVERY gbuffers vsh (terrain, water, entities, entities_translucent, block,
  hand, hand_water, weather, particles, textured, textured_lit, basic, clouds,
  skybasic, skytextured — yes sky too, it must move with the jitter or it shimmers;
  NOT shadow.vsh, NOT fullscreen passes). WATER agent applies the same include to
  its rewritten water vsh files (interface locked here).
- **composite3**: TAA resolve — reproject via previous matrices + camera delta
  (existing lib/space.glsl helpers), 3×3 closest-depth velocity dilation,
  neighbourhood min/max clamp in YCoCg (simple variance-free clamp acceptable at
  this scope but document), history blend 0.9 scaled by confidence; disocclusion
  (depth mismatch / off-screen) → drop to current + confidence reset; NaN-law on
  colortex8 reads; blend in tonemapped-ish space via reinhard pre-weight to tame
  HDR flicker (document exactly; invert after blend). Writes colortex0 + history
  colortex8. Depth for reprojection: depthtex0.
- Handles the jittered G-buffer: deferred/composite passes reconstruct with the
  SAME jittered projection Iris feeds them (gbufferProjection already carries no
  jitter — our jitter is manual in vsh only, so RECONSTRUCTION in lighting/AO/fog
  uses unjittered matrices against jittered depth: acceptable sub-pixel error,
  document; do NOT attempt to unjitter individual passes this phase).
- Options: `TAA` toggle — default ON; profile POTATO sets !TAA (brief: TAA in
  every preset except Potato). Screen: POST.

## 5. Bloom (BLOOM/GRADE agent — MEDIUM effort)

- Threshold-free energy-conserving mip bloom: composite4 builds a 6-level tile
  atlas in colortex9 (tile layout + UV helpers in lib/bloom.glsl, sky-LUT-tile
  pattern: each level samples the PREVIOUS pass's output — since a single pass
  cannot read its own target, structure as: composite4 samples colortex0 (post-TAA)
  and writes ALL tiles using progressively wider 13-tap-style downsample fans
  computed FROM colortex0 mips: enable `const bool colortex0MipmapEnabled = true;`
  for composite4 so hardware mips supply the pre-blur — document the
  quality/simplicity trade); composite5 tent-upsamples the tile chain, sums with
  per-level weights (soft, generous — dreamy identity), and mixes into colortex0:
  `scene + bloom * BLOOM_STRENGTH * 0.0x` energy-conserving formulation.
- Emissive spill: blocklight-bright pixels naturally exceed 1.0 and bloom; verify
  torch/campfire/glowstone bloom visibly at night (tie into the darker nights).
- Options: `BLOOM` toggle (on, POTATO off), `BLOOM_STRENGTH` slider
  [0.5 0.75 1.0 1.25 1.5] default 1.0. Screen: POST.

## 6. Tonemap, exposure, grading, weather storytelling (BLOOM/GRADE agent)

- **AgX**: replace the placeholder ACES-ish curve in final.fsh with a proper AgX
  fit (base + golden/punchy-neutral look tuned to the pack: gentle contrast, soft
  highlights rolloff, slightly lifted blacks — the soft filmic identity). Pure
  330 math (matrix + polynomial fit, no LUT textures). Calibrate default exposure
  so noon/night match current field-approved levels within ~10%.
- **Auto exposure (Mac path)**: `const bool colortex0MipmapEnabled = true;` on
  final; sample a deep mip (≈average scene luminance) → target EV; temporal
  adaptation: read previous adapted value from colortex5.a texel (0,0) (composite5
  writes it back alongside its colour output — composite5 gains RENDERTARGETS 0,5
  writing colortex5 with rgb passthrough of AO history and a=exposure ONLY at
  texel (0,0), preserving AO history semantics everywhere else — implement
  carefully and document; NaN-law with sane clamps [0.25, 4.0] EV range, smooth
  adaptation ~1s up/down). `EXPOSURE` option becomes a bias multiplier.
- **Biome-adaptive grading**: subtle per-biome-category grade nudges (desert
  warmer/golden, swamp green-mossy, snow cool-crisp, jungle lush) via
  temperature/rainfall/category uniforms — small (≤10%) shifts, smooth.
- **Weather storytelling**: rainStrength desaturates + cools + softens contrast;
  thunderStrength darker/steelier; `wetness` adds post-rain freshness (slight
  saturation lift as wetness decays); lightning flash: `lightningBoltPosition`
  uniform (w>0 when a bolt exists) → brief cool-white ambient boost in deferred1
  is OUT of scope for the grade agent — instead approximate in final as a subtle
  full-frame flash lift when lightningBoltPosition.w > 0 (document; deferred1
  untouched).
- All in final.fsh + lib/tonemap.glsl + lib/grade.glsl. Debug views preserved.

## 7. Ownership map (parallel wave)

| Agent | Owns |
|---|---|
| WATER | gbuffers_water.*, gbuffers_hand_water.*, lib/water.glsl (new), composite.* (new pass), the isEyeInWater branch of composite2.fsh, [WATER] options sections |
| TAA | lib/jitter.glsl (new), composite3.* (new), one-line jitter include in every gbuffers vsh EXCEPT water/hand_water (WATER agent does those two), colortex8 + colortex9 format consts in final.fsh comment block, TAA option |
| BLOOM/GRADE | composite4.*, composite5.*, lib/bloom.glsl, lib/tonemap.glsl, lib/grade.glsl, final.fsh body (tonemap/exposure/grade — coordinate: TAA agent only touches final.fsh's format comment block, one surgical edit each), BLOOM/EXPOSURE options, weather/biome grade |

Nobody touches: deferred.fsh, deferred1.fsh, composite1.* (clouds), composite2.*
except WATER's isEyeInWater branch, lib/lighting.glsl, lib/fog.glsl, tools/, docs/.

## 8. Definition of done

- validate --target all green, all profiles; adversarial review (SSR ray math,
  TAA reprojection/ghosting, bloom energy, exposure loop stability, jitter
  coverage, option consistency, sampler budgets ≤16) with confirmed findings
  fixed + re-reviewed; CHANGELOG 0.4.0; zip delivered; main pushed.
- Visual bar: water reflects sky+terrain with soft ripples; submerged scenes
  tinted with dancing caustics; no TAA ghosting on hand/entities in normal play;
  torches bloom against dark nights; AgX look is soft-filmic, not flat.
