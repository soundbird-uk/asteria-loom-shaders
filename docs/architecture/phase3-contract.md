# Asteria Loom — Phase 3 Architecture Contract (LOCKED)

Binding contract for Phase 3 (sky, clouds, fog). Phase 1/2 contracts stay in force.
Brief: `docs/brief.md` §3 (Sky/Clouds/Fog), §6 (technique guidance), §8.3.
Everything must stay Mac-GL4.1-safe (`#version 330 compatibility`, no compute/SSBO/
images, no unverified Iris directives). Lessons already learned that are now LAW:
- Any `clear=false` buffer read MUST be range-validated NaN-proof (comparisons, not
  clamp/isnan alone) and self-healing — the Apple-GL undefined-first-frame bug.
- Buffer format consts go in `final.fsh`'s comment block ONLY.
- Every new option: settings.glsl + exactly one screen + lang (three-way).
- Surgical Edits in shared files (settings/properties/lang); own sections only.

## 0. Scope

Physically-based analytic atmosphere (Rayleigh+Mie+ozone, Chapman-function
transmittance, HG phase g≈0.76) rendered ONCE per frame into a sky-view LUT tile;
procedural HDR sun disc; atmosphere-driven light/ambient colours (keeping the warm
amber sun bias — applied to the direct light colour, per brief); volumetric 2-layer
clouds with temporal accumulation and cheap cloud shadows; aerial-perspective fog
with biome/weather modulation; rich procedural night sky (stars, galaxy band,
shooting stars). OUT: SSR/water/bloom/TAA (Phase 4), aurora/crepuscular loom motif
(Phase 5), End/Nether (Phase 5).

## 1. Pass chain after Phase 3 (LOCKED)

| Pass | Role | Writes |
|---|---|---|
| `prepare` (NEW) | Sky-view LUT tile render | `RENDERTARGETS: 6` |
| gbuffers_skybasic | Sky = LUT sample + sun disc + night sky; suppress vanilla stars AND vanilla void tint via renderStage as before | 0 |
| gbuffers_skytextured | Vanilla sun texture DISCARDED (procedural disc replaces it); vanilla moon kept, HDR-boosted | 0 |
| `deferred` | GTAO (unchanged) | 4 |
| `deferred1` | Lighting (atmosphere-driven colours; direct term gains cloud-shadow factor via lighting lib) | 0 |
| translucents | forward (unchanged; pick up new colours/cloud shadow via lighting lib) | 0 |
| `composite` | Volumetric clouds raymarch + temporal blend; KEEPS the AO-history copy | `RENDERTARGETS: 0,5,7` |
| `composite1` (NEW) | Aerial-perspective fog (biome/weather aware) | 0 |
| `final` | unchanged (+ new format consts in comment block) | — |

## 2. New buffers (formats added to final.fsh comment block by the ATMOSPHERE agent)

| Buffer | Format | Contents | Clear |
|---|---|---|---|
| colortex6 | RGBA16F | Sky-view LUT tile: top-left **256×128 px** region = lat-long radiance map of the full sphere (azimuth × elevation, horizon-biased mapping is implementer's choice but must be documented in lib/atmosphere.glsl and used via shared helpers alSkyMapUV(dir)/alSkySample(dir)). Rest of buffer unused. | **no** |
| colortex7 | RGBA16F | Cloud history: rgb = in-scattered radiance, a = transmittance | **no** |

Both are clear=false → BOTH reads must use the NaN-proof range-validation pattern.
Tile addressing must clamp UVs inside the tile with a half-texel inset (no bleed).
The LUT is regenerated fully every frame by `prepare` (fragments outside the tile
discard), so staleness is not a concern — only first-frame garbage is.

## 3. Atmosphere (ATMOSPHERE agent — HIGH effort)

- `lib/atmosphere.glsl`: analytic single-scattering Rayleigh + Mie + ozone with
  Chapman-function transmittance (LUT-free per brief §6); HG phase g≈0.76 for Mie;
  planet-shadow/horizon handling; sun AND moon contributions (moon = scaled cool
  sun); exposed helpers:
  - `vec3 alSkyRadiance(vec3 dir)` — full-cost path (used by prepare only)
  - `vec3 alSkySample(vec3 dir)` — cheap LUT read (everyone else)
  - `vec3 alSunTransmittance(float sunHeight)`-style helpers to derive:
  - `vec3 alDirectColor()` / `vec3 alAmbientColor()` — atmosphere-driven; the WARM
    AMBER BIAS is applied here to the direct colour (brief: never neutral white;
    horizon warmth comes from the sky model itself). Cool blue-purple ambient is
    derived from average hemisphere sky + existing identity tinting. Night floor,
    blocklight, desaturation logic from Phase 2 stay.
- `prepare.vsh/.fsh` (NEW): fullscreen; fragments outside the 256×128 tile discard;
  inside, decode tile UV → direction → `alSkyRadiance(dir)`. Budget ≤3 samplers.
- `gbuffers_skybasic`: replace the vanilla gradient with `alSkySample(dir)` + a
  procedural HDR sun disc (angular radius from the existing AL_SUN_ANGULAR_RADIUS,
  limb-darkened, intensity such that it blooms later but tonemaps now) + call
  `alNightSky(dir, nightFactor)` (NIGHT SKY agent's lib) additively.
- `gbuffers_skytextured`: discard the sun render stage (procedural disc replaces
  it); keep the moon, boost stays. Verify the correct renderStage constants.
- `lib/lighting.glsl`: source direct/ambient colours from lib/atmosphere.glsl
  (replacing the hardcoded AL_SUN_TINT/AL_SKY_AMBIENT day colours; keep the
  constants as tint MODIFIERS so settings still let the user push warmth).
  Also multiply the direct term by `alCloudShadow(worldPos)` (CLOUDS agent's
  sampler-free helper — declare the include; see §4 interface).
- `sunPathRotation = -35.0` const (settings-driven define, documented).
- settings/screens/lang: SKY section additions (turbidity/mie strength, sun disc
  size/intensity, SKY_BRIGHTNESS retained; remove or repurpose nothing silently).

## 4. Volumetric clouds (CLOUDS agent — HIGH effort)

- `lib/clouds_common.glsl` (NO samplers; includable by lighting lib): 2D FBM value-
  noise cloud coverage function `float alCloudCoverage2D(vec2 worldXZ)` (pure math,
  shared by the raymarcher and the cloud shadow), and
  `float alCloudShadow(vec3 worldPos)` = coverage sampled where the sun ray from
  worldPos pierces the cumulus layer, smoothed, mixed by rainStrength; cheap
  (≤2 coverage evaluations); behind `#ifdef VOLUMETRIC_CLOUDS` (1.0 otherwise).
- `lib/clouds.glsl` + `composite.fsh`: 2-layer raymarch (cumulus 3D + cirrus 2D):
  cumulus = 3D FBM/value-noise base + detail erosion (procedural, noisetex-seeded
  hashing allowed; NO new texture assets this phase), view-adaptive primary steps
  (VC_QUALITY tiers: 12/20/32 steps), 3-4 light steps with exponential growth,
  Wrenninge multi-scatter octaves (2-3), powder term, ambient from alSkySample;
  coverage `mix(clear, storm, rainStrength)`; wind drift via frameTimeCounter.
  Ray domain: only sky pixels AND terrain beyond ~2km merge; depth-test against
  depthtex1 so terrain occludes clouds. Blend result over colortex0.
- **Temporal**: reproject previous cloud result from colortex7 (camera-translation
  aware for the cloud layer parallax — planar reprojection at layer altitude is
  acceptable and must be documented), NaN-proof range-validated reads, blend ~0.85,
  confidence-free (transmittance-carrying) is fine; step-count noise dithered by
  noisetex + R2 so accumulation converges. Write history to colortex7 in the same
  pass (RENDERTARGETS: 0,5,7 — coordinate the out-declaration order with the
  existing AO-history copy which MUST keep working; sampler budget ≤9).
- Options: `VOLUMETRIC_CLOUDS` (toggle), `VC_QUALITY` (1/2/3, default 2),
  `VC_COVERAGE` (0.3-0.7 slider, default 0.45), new `[CLOUDS]` screen; VANILLA_CLOUDS
  default flips OFF (kept as fallback option; screen moves it under CLOUDS).
  Profiles: POTATO/LOW `!VOLUMETRIC_CLOUDS VANILLA_CLOUDS`; MEDIUM VC_QUALITY=1;
  HIGH VC_QUALITY=2; ULTRA VC_QUALITY=3. (MEDIUM gets volumetric per the brief's
  "TAA in every preset except Potato" spirit — clouds are the phase headline.)

## 5. Aerial fog (FOG agent — MEDIUM effort)

- `lib/fog.glsl` + `composite1.vsh/.fsh` (NEW): aerial perspective — NOT uniform
  density: in-scatter toward `alSkySample(viewDir)` + extinction, distance/altitude
  falloff (exponential height fog), so distance shifts blue/desaturated per brief.
  Sky pixels untouched (fog=0 at depth==1; clouds already carry their own).
  Biome modulation via Iris uniforms (`biome_category`, `temperature`, `rainfall`
  — verify exact names against ShaderDoc/raw docs; gate with sane fallbacks if a
  uniform is unavailable): swamps denser/greener, deserts thinner/warmer, snow
  cooler; weather: rainStrength raises density + desaturates; thunderStrength
  darkens. `isEyeInWater != 0` → skip aerial fog (Phase 4 owns underwater).
  Vanilla fogColor NOT used (atmosphere is the source of truth).
- Options: `AERIAL_FOG` (toggle, on), `FOG_DENSITY` (0.5-2.0 slider, default 1.0),
  `[FOG]` screen; all profiles keep fog on (cheap); POTATO keeps it (it replaces
  vanilla fog visually — verify cost is trivial).
- Budget ≤5 samplers (colortex0, colortex6, depthtex0, depthtex1 if needed, noisetex).

## 6. Night sky (NIGHT SKY agent — MEDIUM effort)

- `lib/nightsky.glsl` (self-contained, NO samplers — pure procedural, hash-based):
  `vec3 alNightSky(vec3 worldDir, float nightFactor)` returning ADDITIVE radiance:
  - starfield: hash-cell stars, magnitude distribution, subtle twinkle
    (frameTimeCounter), colour temperature variation;
  - galaxy band: FBM density along a tilted great circle, faint warm/cool dust hues;
  - shooting stars: rare time-hashed streaks (a few per minute, brief lifetime);
  - everything fades in/out with nightFactor and must stay BELOW moon brightness
    (tasteful, dreamy — not a planetarium poster).
  Interface is called by gbuffers_skybasic (ATMOSPHERE agent) — signature is LOCKED.
- Options: `NIGHT_SKY` (toggle, on), `STARS_DENSITY` slider (0.5-2.0, default 1.0),
  entries in the SKY screen (coordinate: ATMOSPHERE agent owns the screen line —
  NIGHT SKY agent adds its options to settings/lang and posts the exact screen
  tokens in its report; orchestrator merges if needed).

## 7. Ownership map (parallel safety)

| Agent | Owns exclusively |
|---|---|
| ATMOSPHERE | lib/atmosphere.glsl, prepare.*, gbuffers_skybasic.*, gbuffers_skytextured.*, lib/lighting.glsl, final.fsh (format block additions for 6+7), SKY sections of settings/properties/lang, `screen =` top line if it needs [CLOUDS]/[FOG] slots added — ADD THEM (coordinating tokens are fixed: [CLOUDS], [FOG]) |
| CLOUDS | lib/clouds.glsl, lib/clouds_common.glsl, composite.fsh/.vsh, CLOUDS sections |
| FOG | lib/fog.glsl, composite1.*, FOG sections |
| NIGHT SKY | lib/nightsky.glsl, its settings/lang entries |

Nobody touches: deferred.fsh, deferred1.fsh (cloud shadow + colours arrive via
lib/lighting.glsl / includes), tools/, docs/, git.

## 8. Definition of done (Phase 3)

- `tools/validate.py --target all` green, all profiles; self-test green.
- Adversarial review: atmosphere correctness (horizon/transmittance/night),
  LUT tile addressing (bleed/first-frame), cloud temporal chain NaN-proofing,
  RENDERTARGETS 0,5,7 wiring, profile combos, sampler budgets; findings fixed +
  re-reviewed.
- On-device: sunrise/noon/sunset/night sky readable and warm-biased; clouds 3D
  with dark undersides, no grain/banding; distance reads hazy-blue; night sky
  rich but subtle; no regressions in Phase 1/2 features.
- CHANGELOG 0.3.0, zip delivered, main pushed after review.
