# Asteria Loom — Phase 5 Architecture Contract (LOCKED)

Binding contract for Phase 5 (dimensions & signature extras): End black hole +
purple haze (world1), Nether pass (world-1), loom crepuscular rays + aurora,
Distant Horizons support. Phase 1-4 contracts and all standing LAWS remain in
force (NaN-law on clear=false reads, formats only in final.fsh comment block,
three-way options, surgical shared-file edits, Mac GL4.1 only, fail-safe
direction on every new screen-space/temporal effect).

## 0. World-folder migration (orchestrator, BEFORE implementation wave)

Iris rule: once ANY worldN folder exists, programs load ONLY from worldN folders.
Therefore the orchestrator performs a mechanical migration first:
- `git mv` every program (`*.vsh`, `*.fsh`) from `shaders/` into `shaders/world0/`.
- Stays at `shaders/` root: shaders.properties, block.properties, settings.glsl,
  lang/, lib/ (all includes use absolute `/lib/...` and `/settings.glsl` paths —
  they resolve identically from world folders).
- tools/validate.py gains worldN awareness FIRST (CI agent): discover programs per
  world folder, compile every world × profile × target; world-less packs stay
  supported (self-test keeps both layouts).
- shaders.properties program directives (program.X.enabled, blend.*) are global
  and apply per-world by program name — unchanged.

## 1. world1 — The End (END agent, HIGH effort; brief §2/§5/§6 verbatim)

Program set in `shaders/world1/`: copies/shims of world0 programs where behaviour
is shared (terrain/entities/etc. may be thin `#include`-free duplicates only if
needed — prefer including shared bodies is NOT possible with #version headers, so
DUPLICATE the small gbuffers files verbatim and note it; deferred/composite chain
is world1-specific where the sky differs):
- **Black-hole sky**: fully procedural raymarched black hole rendered in the
  End's deferred sky region (depth==1): bend view rays with an impact-parameter
  approximation of Schwarzschild lensing (NO geodesic integration), procedural
  accretion disc (temperature gradient warm inner → cool outer, Doppler
  brightening on the approach side, two visually-doubled arcs above/below via
  lensing), photon ring at the capture threshold, background = procedural
  starfield (reuse lib/nightsky.glsl starfield with a denser parameter set) +
  **purple Rayleigh-ish haze** rising from the horizon; End fog (its composite2)
  tinted to match the haze. Black hole direction: fixed high-elevation azimuth
  (document); size tunable (END_BLACKHOLE_SIZE option, small default).
- gbuffers_skybasic (world1): suppress vanilla End sky/void via renderStage as
  Overworld does; the deferred pass paints the hole/starfield/haze.
- Lighting: End has no sun — use the existing End light direction uniforms
  (shadowLightPosition still exists in the End; verify) with a cool violet key
  + purple ambient; keep AO/TAA/bloom/grade passes working (duplicate the
  composite chain files into world1; fog pass becomes End-haze; clouds pass
  SKIPPED in world1 — no volumetric clouds in the End: either omit composite1
  or make it a passthrough that still maintains the AO history copy — CAREFUL:
  the AO history copy currently lives in composite1; if omitted, move that
  responsibility into the world1 fog or a minimal composite1 — keep the temporal
  chains intact; document the world1 pass chain in a header table).
- `endFlashPosition`/`endFlashIntensity` (Iris): brief violet-white flash lift.
- Options: END_BLACKHOLE_SIZE slider (small set), no new screens (reuse SKY).

## 2. world-1 — Nether (NETHER agent, MEDIUM effort)

Program set in `shaders/world-1/`:
- No shadow pass (no file → no pass), no clouds, no atmosphere LUT (prepare
  omitted). Lighting: no directional key; ambient = warm ember base modulated by
  biome (crimson red-tinted / warped teal-tinted / soul sand valley cold blue /
  basalt deltas grey — biome uniforms work in the Nether? verify biome_category
  values for nether biomes from Iris source; fall back to fogColor-derived tint
  if not), blocklight unchanged (it carries the Nether), AO pass kept.
- Dense warm fog (its composite2): short-range, ember-red base modulated per
  biome as above; ceiling-safe (no skylight gate — Nether skyLm is 0 everywhere:
  bypass the gate, use pure distance fog; document).
- Keep TAA/bloom/grade. gbuffers duplicated from world0 where shared.
- No new options (reuse FOG_DENSITY etc.).

## 3. Loom motif — crepuscular rays + aurora (LOOM agent, MEDIUM-HIGH; world0)

- **Crepuscular rays** (the "light-weave" signature): screen-space radial
  god rays in the fog stage — occlusion mask from depth (sky vs geometry) around
  the sun's screen position, radial march (~24 taps, dithered), decay, warm sun
  tint from atmosphere, active near sunrise/sunset and modest at noon; the WEAVE:
  modulate ray intensity by a slow angular interference pattern (two overlapping
  angular frequencies around the sun axis → interwoven band look, subtle).
  Implemented in lib/rays.glsl, called from composite2 (surgical edit, after fog,
  before its far-fade output; behind GODRAYS toggle default on, POTATO off).
  Off-screen sun → rays fade smoothly (no pop at screen edge; standard falloff).
- **Aurora**: woven-band aurora on CLEAR COLD NIGHTS only (temperature uniform
  < ~0.2, rainStrength == 0, deep night via the canonical alDayFactor ramp):
  2-3 flowing vertical-curtain bands (FBM-driven curtains along a sky arc,
  green-teal core with violet fringes, slow undulation), additive in the sky
  path — lib/aurora.glsl called from gbuffers_skybasic next to alNightSky
  (surgical one-line call + include). Subtle luminance (below moon), fades near
  the horizon. AURORA toggle default on; lang/screen SKY.
- Both effects respect the dreamy identity: soft, interwoven, never neon.

## 4. Distant Horizons (DH agent, MEDIUM effort; world0)

- `#ifdef DISTANT_HORIZONS` everywhere; programs `world0/dh_terrain.vsh/.fsh`
  and `world0/dh_water.vsh/.fsh` (compatibility profile — same #version line as
  the rest) writing the same G-buffer/forward conventions as their gbuffers
  cousins (dh_terrain → G-buffer with matID TERRAIN, simple normals from
  dhMaterialId/vertex normals; dh_water → forward water WITHOUT waves/SSR aux
  writes (keep it simple: tinted forward + matID TRANSLUCENT)); `dh_shadow` pass.
- **dhDepthTex compositing**: everywhere depth gates far-field behaviour —
  composite1 (cloud terrain-occlusion), composite2 (fog distance + far-fade to
  sky), deferred1 sky test — read `dhDepthTex0/1` when DISTANT_HORIZONS is
  defined and the vanilla depth says sky: if DH depth < 1, reconstruct distance
  with `dhProjection` inverse and fog/occlude with DH's farther plane instead of
  treating the pixel as sky. Centralize the merged-depth helper in lib/space.glsl
  (alMergedDepth → linear distance + is-sky flag) and convert call sites to it.
  far-fade uses dhFarPlane when DH active.
- All DH code compiles OUT cleanly when DISTANT_HORIZONS is undefined (validator:
  CI agent adds a DH macro-toggle dimension to the targets or a spot-check pass —
  their call, keep matrix growth sane e.g. DH only on the mac target).

## 5. Ownership map

| Agent | Owns |
|---|---|
| CI | tools/validate.py worldN + DH-define coverage; runs FIRST |
| END | shaders/world1/** + END options/lang |
| NETHER | shaders/world-1/** |
| LOOM | lib/rays.glsl, lib/aurora.glsl, surgical calls in world0/composite2.fsh + world0/gbuffers_skybasic.fsh, GODRAYS/AURORA options |
| DH | world0/dh_*.{vsh,fsh}, lib/space.glsl merged-depth helper, DH-guarded edits in world0/{deferred1,composite1,composite2}.fsh |

LOOM and DH both touch world0/composite2.fsh — LOOM edits the rays call site
(post-fog), DH edits depth sourcing (pre-fog): disjoint regions, surgical Edits,
orchestrator resolves any collision at integration.

## 6. Definition of done

validate green (all worlds × profiles × targets), adversarial review (lensing
math sanity, world pass-chain integrity incl. temporal histories per world,
Nether/End fog behaviour, DH depth merge, ray/aurora gating, option consistency),
fixes re-reviewed, CHANGELOG 0.5.0, zip delivered, main synced.
