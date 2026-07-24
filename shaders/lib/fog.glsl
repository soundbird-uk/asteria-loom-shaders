#ifndef AL_LIB_FOG
#define AL_LIB_FOG

/*
============================================================================
 lib/fog.glsl — aerial-perspective fog (Phase 3, FOG subsystem)
----------------------------------------------------------------------------
 The model, in one paragraph. This is NOT a uniform-density distance fade and
 NOT a hard cutoff. It is single-scattering aerial perspective with a
 SEA-LEVEL-FLOORED EXPONENTIAL HEIGHT falloff: air density is CONSTANT at and
 below sea level and thins with altitude ABOVE it (scale height AL_FOG_HEIGHT).
 The floor matters — an un-floored exp would grow without bound below sea level
 and drown caves in bright sky haze. Aerial fog is also gated by sky exposure
 (see alApplyAerialFog) so enclosed spaces get none. Along the view ray we
 integrate the floored density analytically to an optical depth tau;
 extinction = exp(-tau) darkens the scene toward the distance while in-scattered
 light is added back in. RE-TONE (0.3.3): the in-scatter is NOT the raw sky — it
 is the sky sample blended toward a DARKER, desaturated SCENE tone (analytic
 hemisphere ambient + a luminance cut of the sky), so fog reads as atmospheric
 DEPTH that darkens+desaturates distance (hazy-blue-grey by day, muted-warm at
 sunset) instead of a bright glow painted in front of terrain. A dim cool
 moon-tinted NIGHT FLOOR keeps depth-haze visible after dark (the raw sky sample
 goes black at night). The tone still tracks time of day (sun elevation drives
 both the sky sample and the scene tone). Biome and weather modulate density and
 tint. Sky pixels (depth == 1) are left untouched — the clouds pass already
 carries the sky's own transmittance and must not be fogged twice — and
 underwater is skipped entirely (Phase 4 owns it).

 Pure-math + one texture read helper. The only sampler touched here is
 colortex6, and only indirectly via alSkySample() — that sampler is declared
 and owned by lib/atmosphere.glsl (this file declares no samplers of its own).
 Everything is GLSL 3.30 / Mac-GL4.1 safe: no loops, just a couple of exp()
 calls, so the pass is trivially cheap and stays on in every profile (POTATO
 included).

 DEPENDS ON lib/atmosphere.glsl (ATMOSPHERE agent) for:
   vec3 alSkySample(vec3 worldDir)   — cheap sky-LUT read (colortex6)
 We defensively range-validate its RESULT and fall back to an analytic sky
 gradient if it is ever non-finite / out of range (first-frame colortex6
 garbage on the Apple-GL clear=false path), so fog never produces NaNs even
 if the LUT read upstream is momentarily bad.
============================================================================
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"
// Sampler-free atmosphere core: alAmbientColor() (scene-ambient tone for the
// re-toned in-scatter) and the identity tints. Guard-safe double-include (the
// includer already pulls it via lib/atmosphere.glsl); alSkySample() itself still
// comes from the includer's lib/atmosphere.glsl (the sampler side).
#include "/lib/atmosphere_common.glsl"

/* -------------------------------------------------------------------------
   Tunables (internal, not GUI — edit + hot-reload). The GUI FOG_DENSITY
   slider (settings.glsl) multiplies AL_FOG_SEA_DENSITY on top of these.
   ------------------------------------------------------------------------- */

// Extinction coefficient at sea level, per world-metre, at FOG_DENSITY = 1 and
// in a neutral biome/clear weather.
// 0.4.4 FIELD RETUNE: 0.4.3 (0.0016) over-corrected — fog read as "non-existent"
// and the void below the horizon was no longer covered. Raised to 0.0030 (half
// extinction ~231 m): a flat sea-level horizon now reaches ~62% haze at 320
// blocks (seals the far seam / void) while mid-scene terrain at 120-150 m sits at
// ~30-36% — clearly atmospheric but still not the 0.4.2 wall. Elevated terrain
// fogs less (height falloff). GUI FOG_DENSITY scales this.
#define AL_FOG_SEA_DENSITY 0.0030

// 0.4.8 DISTANCE-BASED FOG (rebuild). Pure distance from the camera — NO height
// dependence, so fog no longer thins on high terrain (the user's report). A gentle
// base aerial haze gives mid-field depth; an EDGE SEAL then ramps fog to FULL near
// the render distance so the render-distance boundary + the void below the horizon
// are completely hidden — the last band of terrain melts seamlessly into the sky.
//   DIST_HALF   — distance (blocks) at which the base haze reaches ~50%
//   EDGE_START  — fraction of `far` where the edge seal begins (mid-field stays clear)
//   EDGE_END    — fraction of `far` where fog is FULL (boundary fully hidden)
//   EDGE_CURVE  — >1 keeps the mid-field clear, then ramps hard near the edge
#define AL_FOG_DIST_HALF   340.0
#define AL_FOG_EDGE_START  0.60
#define AL_FOG_EDGE_END    0.985
#define AL_FOG_EDGE_CURVE  2.2

// 5.0.4 RENDER-DISTANCE EDGE (rebuild): a THICK grey fog wall in the last few
// chunks that completely hides the unrendered-chunk dropoff into the void and
// melts into the sky. The far fog colour is DIRECTION-INDEPENDENT (no sky sample
// in the view direction) so it can NEVER paint a horizon band on terrain.
// 5.0.9: the chunk distances are now GUI sliders (settings.glsl) so the wall and
// the patchy-ramp start make sense to tune. AL_FOG_EDGE_CHUNKS / AL_FOG_MID_CHUNKS
// alias the GUI values; the start is floored to (wall + 1) so the patchy ramp can
// never fall inside or behind the wall. EDGE_BRIGHT (internal) lifts the far fog
// toward the sky's brightness (greyish blend).
#define AL_FOG_EDGE_CHUNKS FOG_WALL_CHUNKS
#define AL_FOG_MID_CHUNKS  max(FOG_START_CHUNKS, FOG_WALL_CHUNKS + 1.0)
#define AL_FOG_EDGE_BRIGHT 1.35

// Horizon void-seal (applied to SKY pixels in composite2): fade the sky toward
// the far fog colour near the horizon so the void beyond the render edge reads as
// thick fog matching the fogged terrain (no seam). SKY = elevation over which it
// fades out; SEAL = max strength at the horizon.
#define AL_FOG_HORIZON_SKY  0.16
#define AL_FOG_HORIZON_SEAL 0.92

// Scale height (metres): altitude over which density falls by 1/e. Larger =
// fog climbs higher up mountains before thinning.
#define AL_FOG_HEIGHT 26.0

// Reference sea level (world Y). Density peaks here. MC sea level is y≈62.
#define AL_FOG_SEA_LEVEL 62.0

// Optical-depth cap before exp(): keeps extinction well-defined and avoids
// denormal underflow. exp(-40) ≈ 4e-18 (fully fogged), never NaN/inf.
#define AL_FOG_MAX_TAU 40.0

// Sky-exposure gate window (raw sky lightmap 0..1). Aerial fog is OUTDOOR haze:
// it needs open sky to scatter into the view. Optical depth is scaled by
// smoothstep(LO, HI, skyLightmap) so caves and interiors (sky-lm ~0) get ZERO
// fog while open valleys (sky-lm >= HI) get the full amount — preserving Phase
// 2's cave darkness.
// BAND FIX (0.3.x): ALIGNED to the lighting ambient-desat window
// (AL_AMBIENT_DESAT_LO/HI, 0.00-0.30). The two used to differ (0.05-0.35 here vs
// 0.05-0.30 there), so on the quantised sky lightmap they placed their contour
// steps at DIFFERENT depths underwater — a visible double band. Identical windows
// collapse that to a single, gentler transition.
#define AL_FOG_SKY_GATE_LO 0.00
#define AL_FOG_SKY_GATE_HI 0.30

// 5.0.8 DISTANCE-RELAXED GATE ("no fog when looking deep into distant caves").
// The sky gate keeps NEAR caves/interiors clear (you can see into a cave right in
// front of you), but a cave mouth / hole in the surface seen from FAR away must
// fog like any other distant terrain — otherwise it punches an unfogged dark hole
// through the haze. So the gate is forced open with distance: fully gated up to
// RELAX_NEAR, fully open beyond RELAX_FAR (absolute blocks, render-distance
// independent). This does NOT fill nearby caves — only distant low-sky pixels.
#define AL_FOG_GATE_RELAX_NEAR 42.0
#define AL_FOG_GATE_RELAX_FAR  120.0

// --- Ground-haze in-scatter softening (BUG A: sunrise/sunset white-out) ------
// The near-horizon sky is very bright at sunrise/sunset. Because distant terrain
// is viewed along rays AT or BELOW the horizon, its in-scatter would blow out to
// that peak brightness and read as a jarring white wash. We therefore soften the
// in-scatter for GROUND-WARD rays only (never the sky itself — sky pixels are
// early-returned in composite1): a soft knee compresses the blown-out (>1) part
// so noon stays natural while sunset is tamed, plus a gentle desaturation so
// ground haze reads softer than the sky's own glow. Brief §3: soft & dreamy.
//   GROUND_HI/LO — worldDir.y window over which softening ramps in (up -> down)
//   HORIZON_DESAT — how far ground in-scatter pulls toward its own luminance
#define AL_FOG_GROUND_HI     0.18   // above this elevation: no softening (sky-ward)
#define AL_FOG_GROUND_LO    -0.08   // at/below this: full softening (ground-ward)
#define AL_FOG_HORIZON_DESAT 0.30

// --- In-scatter RE-TONE (0.3.3, ISSUE 2: darker / scene-coloured haze) -------
// The old in-scatter was the raw bright sky, which read as a white glow "painted
// in front of" terrain. Instead blend the sky sample toward a DARKER scene tone:
// the analytic hemisphere ambient (cool blue-purple day / mauve dusk / cool moon
// night, from alAmbientColor) mixed with a LUMINANCE CUT of the sky, then dimmed.
// Fog then reads as atmospheric DEPTH that darkens+desaturates distance, not glow.
//   TONE_MIX   — how far the in-scatter moves from raw sky toward the scene tone
//   TONE_LUMCUT— fraction of the scene tone that is the desaturated (grey) sky
//   TONE_DIM   — overall darkening of the scene tone
// 0.4.5b: distant terrain was washing toward the BRIGHT sky horizon band because
// the fog tone still carried 45% raw sky. Pushed the mix hard toward the dark
// scene tone (0.55 -> 0.80) and dimmed it (0.75 -> 0.60) so fogged distant terrain
// reads as a dark, desaturated hazy SILHOUETTE distinct from the sky — no bleed.
#define AL_FOG_TONE_MIX    0.80
#define AL_FOG_TONE_LUMCUT 0.55
#define AL_FOG_TONE_DIM    0.60

// --- NIGHT fog floor (0.3.3, ISSUE 3: no fog at night) -----------------------
// At night alSkySample is ~black, so the sky-derived in-scatter vanishes. Add a
// dim, cool, moon-tinted haze floor scaled by the SAME night factor the lighting
// uses (1 - dayFactor, dayFactor = alSmooth(smoothstep(-0.06,0.16,sunDir.y)) —
// matched to lib/lighting.glsl / atmosphere_common so night stays consistent).
// AL_MOON_TINT is the shared identity moon colour. Kept dim: visible depth-haze,
// never a glow. Auto-gated by extinction (caves get beta0=0 -> no night fog).
// 0.4.3 FIELD FIX (ISSUE 14: "night distance too white/grey"): dropped 0.085 ->
// 0.028 so the night haze is a whisper of cool depth, not a pale wash.
#define AL_FOG_NIGHT_LEVEL 0.028

// 0.4.3 (ISSUE 14): overall night DARKENING of the whole in-scatter. At night the
// raw sky sample + scene tone still carry a dim grey that, once terrain is fogged,
// reads as pale mist over distant hills. This multiplier crushes the night
// in-scatter toward dark (cool) so distant night terrain darkens + desaturates as
// silhouettes instead of turning white. Applied via mix(this, 1.0, dayFactor) so
// noon is untouched.
#define AL_FOG_NIGHT_DIM 0.40


// Biome-modulation master switch. All biome_category / temperature / rainfall
// reads (verified Iris uniforms — see composite1.fsh header for evidence) are
// gated behind this. If a future Iris ever drops these uniforms, flip this off
// (or the profile can) and fog degrades gracefully to weather-only modulation
// with ZERO compile or runtime breakage. On by default (uniforms verified).
#define AL_FOG_BIOME_UNIFORMS

/* -------------------------------------------------------------------------
   Iris biome_category ordinals.
   VERIFIED against Iris source (1.21.11):
     common/src/main/java/net/irisshaders/iris/parsing/BiomeCategories.java
   Iris does NOT inject CAT_* macros into shader source (verified: no CAT_* in
   gl/shader/StandardMacros.java), so — contrary to a common assumption — we
   cannot rely on a predefined CAT_SWAMP etc. We therefore define our own
   constants matching the enum ORDINAL, which is exactly what the
   biome_category uniform reports (uniform1i = BiomeCategories.ordinal()).
   Values 0..16 also coincide with OptiFine's documented CAT_* numbering.
   ------------------------------------------------------------------------- */
#define AL_CAT_NONE          0
#define AL_CAT_TAIGA         1
#define AL_CAT_EXTREME_HILLS 2
#define AL_CAT_JUNGLE        3
#define AL_CAT_MESA          4   // badlands
#define AL_CAT_PLAINS        5
#define AL_CAT_SAVANNA       6
#define AL_CAT_ICY           7   // snowy
#define AL_CAT_THE_END       8
#define AL_CAT_BEACH         9
#define AL_CAT_FOREST        10
#define AL_CAT_OCEAN         11
#define AL_CAT_DESERT        12
#define AL_CAT_RIVER         13
#define AL_CAT_SWAMP         14
#define AL_CAT_MUSHROOM      15
#define AL_CAT_NETHER        16
#define AL_CAT_MOUNTAIN      17  // Iris addition (OptiFine-undocumented)
#define AL_CAT_UNDERGROUND   18  // Iris addition

/* -------------------------------------------------------------------------
   Analytic sky fallback — used only if the colortex6 LUT read comes back
   non-finite / out of range (defensive; see file header). A cheap
   horizon-warm → zenith-cool gradient so distance still reads hazy-blue even
   before the atmosphere LUT is valid.
   ------------------------------------------------------------------------- */
vec3 alFogAnalyticSky(vec3 worldDir) {
    float h = alSaturate(worldDir.y * 0.5 + 0.5);       // 0 down .. 1 up
    vec3 horizon = vec3(0.62, 0.60, 0.58);              // warm hazy band
    vec3 zenith  = vec3(0.20, 0.34, 0.62);              // cool blue
    return mix(horizon, zenith, alSmooth(h)) * SKY_BRIGHTNESS;
}

// NaN-proof in-scatter colour. alSkySample() reads the clear=false colortex6
// tile; the range test uses comparisons (NaN fails every one) rather than
// isnan/clamp alone, and self-heals to the analytic gradient. Bound 1e4 is
// well above any plausible HDR sky radiance but rejects inf/garbage.
vec3 alFogSkyInscatter(vec3 worldDir) {
    vec3 sky = alSkySample(worldDir);
    bool ok = (sky.r >= 0.0 && sky.g >= 0.0 && sky.b >= 0.0)
           && (sky.r < 1.0e4 && sky.g < 1.0e4 && sky.b < 1.0e4);
    return ok ? sky : alFogAnalyticSky(worldDir);
}

// Cheap value noise (portable, sampler-free) for PATCHY far fog — breaks the
// far-fog ramp into uneven, real-looking banks instead of a clean radial fade.
float alFogHash(vec2 p) {
    return fract(sin(dot(p, vec2(41.31, 289.17))) * 43758.5453);
}
float alFogNoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = alFogHash(i);
    float b = alFogHash(i + vec2(1.0, 0.0));
    float c = alFogHash(i + vec2(0.0, 1.0));
    float d = alFogHash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/* -------------------------------------------------------------------------
   Biome + weather modulation.
   =========================================================================
   MULTIPLIER TABLE (all deliberately SUBTLE; layered, no hard cutoffs)
   -------------------------------------------------------------------------
   BIOME (by biome_category, gated behind AL_FOG_BIOME_UNIFORMS):
     category         densityMul   scatterTint (R,G,B)        rationale
     SWAMP     (14)     x1.35       (0.90, 1.03, 0.88)   denser + slight green cast
     JUNGLE    (3)      x1.20       (0.95, 1.02, 0.93)   slightly denser, faint green
     DESERT    (12)     x0.70       (1.06, 0.98, 0.86)   thinner + warmer
     MESA      (4)      x0.75       (1.07, 0.96, 0.82)   thinner + warmer (badlands)
     ICY       (7)      x1.05       (0.92, 0.97, 1.08)   cooler
     (all others)       x1.00       (1.00, 1.00, 1.00)   neutral

   CONTINUOUS climate layer (smooth, on top of the discrete category — catches
   snowy/arid variants whose category is generic, e.g. snowy taiga = TAIGA):
     cold = saturate((0.30 - temperature) / 0.45)   → cool tint  (x up to 0.6)
     arid = saturate((0.30 - rainfall)/0.30)
          * saturate((temperature - 0.80)/0.40)      → warm tint + x0.88 density

   WEATHER (verified uniforms, always applied — no biome gate):
     rain = saturate(max(rainStrength, wetness*0.6))
       density x mix(1.0, 1.8, rain)                 rain raises density noticeably
       desat   = rain * 0.6                          in-scatter desaturates in rain
     thunder = saturate(thunderStrength)
       darken  = mix(1.0, 0.72, thunder)             thunder darkens the fog
   =========================================================================
   Outputs:
     densityMul  — multiplies the sea-level extinction coefficient
     scatterTint — multiplies the in-scatter (sky) colour
     desat       — 0..1, how far to pull in-scatter toward its own luminance
     darken      — multiplies the in-scatter brightness
   ------------------------------------------------------------------------- */
void alFogModulation(int biomeCategory, float temperature, float rainfall,
                     float rainStrength, float wetness, float thunderStrength,
                     out float densityMul, out vec3 scatterTint,
                     out float desat, out float darken) {
    densityMul  = 1.0;
    scatterTint = vec3(1.0);
    desat       = 0.0;
    darken      = 1.0;

#ifdef AL_FOG_BIOME_UNIFORMS
    // --- Discrete biome character ---
    if (biomeCategory == AL_CAT_SWAMP) {
        densityMul *= 1.35; scatterTint *= vec3(0.90, 1.03, 0.88);
    } else if (biomeCategory == AL_CAT_JUNGLE) {
        densityMul *= 1.20; scatterTint *= vec3(0.95, 1.02, 0.93);
    } else if (biomeCategory == AL_CAT_DESERT) {
        densityMul *= 0.70; scatterTint *= vec3(1.06, 0.98, 0.86);
    } else if (biomeCategory == AL_CAT_MESA) {
        densityMul *= 0.75; scatterTint *= vec3(1.07, 0.96, 0.82);
    } else if (biomeCategory == AL_CAT_ICY) {
        densityMul *= 1.05; scatterTint *= vec3(0.92, 0.97, 1.08);
    }

    // --- Continuous climate (smooth; catches generic-category variants) ---
    float cold = alSaturate((0.30 - temperature) / 0.45);
    float arid = alSaturate((0.30 - rainfall) / 0.30)
               * alSaturate((temperature - 0.80) / 0.40);
    scatterTint = mix(scatterTint, scatterTint * vec3(0.93, 0.97, 1.07), cold * 0.6);
    scatterTint = mix(scatterTint, scatterTint * vec3(1.05, 0.99, 0.88), arid * 0.5);
    densityMul *= mix(1.0, 0.88, arid);
#endif

    // --- Weather (always) ---
    // 5.0.4 FIELD ("rain makes the whole world grey"): the 1.8x density + 0.6
    // desat turned distance into a flat grey wall in any drizzle. Softened to a
    // gentle thickening + light desat so rain reads moody, not colourless.
    float rain = alSaturate(max(rainStrength, wetness * 0.6));
    densityMul *= mix(1.0, 1.25, rain);
    desat       = rain * 0.22;
    darken      = mix(1.0, 0.80, alSaturate(thunderStrength));
}

/* -------------------------------------------------------------------------
   Analytic optical depth of SEA-LEVEL-FLOORED exponential height fog.

   The density profile is CONSTANT at/below sea level and only decays ABOVE it:
       rho(y) = beta0 * exp(-max(y - sea, 0) / H)
   i.e. rho == beta0 for every y <= sea, and thins with altitude above. This is
   the fix for the cave/below-sea explosion: the old un-floored exp grew without
   bound as y dropped (34x sea density at y=-30), replacing cave walls with
   bright sky haze. Air can't densify below sea level here; it plateaus.

   Along the ray y(t) = camY + dirY*t we integrate exactly via the piecewise
   antiderivative phi of the UNIT profile (rho/beta0):
       phi(y) = (y - sea)                        for y <= sea   (constant seg.)
       phi(y) = H * (1 - exp(-(y - sea)/H))      for y >  sea   (exp segment)
   phi is continuous (phi(sea)=0) and monotonically increasing (phi' = unit
   density > 0), so it transparently handles rays that CROSS the y=sea boundary
   (part constant-density, part exponential) with no explicit split. Then
       tau = beta0 * (phi(y1) - phi(y0)) / dirY                 (dirY != 0)
   which is always >= 0 (phi monotone: numerator and dirY share sign). The
   near-horizontal limit (dirY -> 0) is beta0 * unitDensity(y0) * dist, the
   consistent limit of the ratio above. exp() args are clamped so no altitude
   can produce inf/NaN.
   ------------------------------------------------------------------------- */

// Unit-profile antiderivative phi(y) (density measured in units of beta0).
float alFogPhiUnit(float y) {
    float d = y - AL_FOG_SEA_LEVEL;
    if (d <= 0.0) return d;                              // constant density below sea
    float e = clamp(-d / AL_FOG_HEIGHT, -AL_FOG_MAX_TAU, AL_FOG_MAX_TAU);
    return AL_FOG_HEIGHT * (1.0 - exp(e));               // exponential above sea
}

// Unit density (rho/beta0) at altitude y, floored at sea level.
float alFogUnitDensity(float y) {
    float d = max(y - AL_FOG_SEA_LEVEL, 0.0);
    return exp(clamp(-d / AL_FOG_HEIGHT, -AL_FOG_MAX_TAU, AL_FOG_MAX_TAU));
}

float alFogOpticalDepth(float camY, vec3 worldDir, float dist, float beta0) {
    float y0   = camY;
    float y1   = camY + worldDir.y * dist;
    float dirY = worldDir.y;

    float tau;
    if (abs(dirY) > 0.02) {
        tau = beta0 * (alFogPhiUnit(y1) - alFogPhiUnit(y0)) / dirY;
    } else {
        tau = beta0 * alFogUnitDensity(y0) * dist;      // near-horizontal ray
    }
    // FAIL-SAFE DIRECTION (Mac world-wash fix): a bad tau must mean NO fog (the
    // scene shows through), NEVER full fog (the scene erased by sky in-scatter).
    // `clamp(NaN, 0, MAX)` returns MAX on some drivers (Apple GL) -> ext=exp(-MAX)
    // ~= 0 -> every pixel becomes uniform sky colour: the reported blinding-white
    // (day) / blue-grey (dusk) wash. A comparison rejects NaN AND Inf (neither
    // satisfies `>= 0.0`), collapsing them to tau = 0 (extinction 1, fog absent).
    if (!(tau >= 0.0)) return 0.0;
    return min(tau, AL_FOG_MAX_TAU);
}

// Soft-knee compression of the blown-out (>1) part of a colour, applied by
// `amt` in [0,1]. Channels <= 1 pass through unchanged (noon horizon stays
// natural); channels > 1 are compressed into [1,2) so a very bright sunrise/
// sunset horizon can't white-out ground haze. min() guarantees it only ever
// darkens, never brightens.
vec3 alFogSoftKnee(vec3 c, float amt) {
    vec3 excess     = max(c - 1.0, 0.0);
    vec3 compressed = 1.0 + excess / (1.0 + excess);   // [1,inf) -> [1,2)
    return mix(c, min(c, compressed), amt);
}

/* -------------------------------------------------------------------------
   FAR / horizon fog colour — a bright, DIRECTION-INDEPENDENT grey haze that both
   the render-distance edge (terrain) and the horizon sky (composite2 sky path)
   converge to, so distance melts seamlessly into the sky with NO painted band.
   Derived from the atmosphere's hemisphere ambient (already a directional
   AVERAGE — carries the time-of-day tone but no horizon band), pulled toward grey
   and lifted toward the sky's brightness, then rain/thunder/night-treated to
   match the terrain haze. Shared by alApplyAerialFog (edge) and the sky path.
   ------------------------------------------------------------------------- */
vec3 alFogFarColor(vec3 worldSunDir, float rainStrength, float wetness,
                   float thunderStrength) {
    float dayF = alSmooth(smoothstep(-0.06, 0.16, worldSunDir.y));
    vec3  amb  = alAmbientColor(worldSunDir);
    vec3  grey = mix(amb, vec3(alLuminance(amb)), 0.45) * AL_FOG_EDGE_BRIGHT;
    float rain = alSaturate(max(rainStrength, wetness * 0.6));
    grey = mix(grey, vec3(alLuminance(grey)), rain * 0.22);        // rain desat
    grey *= mix(1.0, 0.80, alSaturate(thunderStrength));           // thunder darken
    // Cool + strongly DARKEN at night so the far fog matches the dark below-horizon
    // sky (they share this function) and blends in — day is untouched (dayF==1).
    // 5.0.8: night far-fog was reading as a light grey; crushed to ~0.20x.
    vec3 nightHaze = mix(vec3(0.55, 0.64, 1.00), vec3(1.0), dayF)
                   * mix(0.20, 1.0, dayF);
    return max(grey * nightHaze, vec3(0.0));
}

/* -------------------------------------------------------------------------
   Full aerial-perspective evaluation for one pixel.
     sceneColor   — linear HDR colour under the fog (colortex0)
     camY         — camera world Y (cameraPosition.y)
     worldDir     — unit world-space view direction (camera -> fragment)
     dist         — straight-line distance camera -> fragment (metres)
     skyLightmap  — this pixel's raw sky lightmap (colortex2.a); gates fog so
                    caves/interiors (sky-lm ~0) get none. See AL_FOG_SKY_GATE_*.
     farDist      — the `far` uniform (render distance, blocks); drives the
                    far-plane convergence ramp that hides the terrain/sky seam.
     worldSunDir  — world-space unit sun direction; drives the time-of-day scene
                    tone and the night factor for the night fog floor.
     (biome/weather uniform values passed through to alFogModulation)
   Returns the fogged linear HDR colour.
   ------------------------------------------------------------------------- */
vec3 alApplyAerialFog(vec3 sceneColor, float camY, vec3 worldDir, float dist,
                      float userDensity, float skyLightmap, float farDist,
                      vec3 worldSunDir, int biomeCategory, float temperature,
                      float rainfall, float rainStrength, float wetness,
                      float thunderStrength) {
    float densityMul; vec3 scatterTint; float desat; float darken;
    alFogModulation(biomeCategory, temperature, rainfall,
                    rainStrength, wetness, thunderStrength,
                    densityMul, scatterTint, desat, darken);

#if defined AL_DIM_NETHER
    // Nether: dense, short-range ember fog EVERYWHERE (no sky gate — Nether sky-
    // lightmap is 0, so a gate would remove all fog). Pure distance; ember tint.
    float ndens = (0.6931472 / AL_NETHER_FOG_HALF) * max(userDensity, 0.0) * densityMul;
    float nFogF = 1.0 - exp(-ndens * max(dist, 0.0));
    vec3  nInsc = AL_NETHER_FOG * scatterTint * darken;
    return max(sceneColor * (1.0 - nFogF) + nInsc * nFogF, vec3(0.0));
#elif defined AL_DIM_END
    // End: purple haze, no sky gate, medium range; distant terrain fades into the
    // purple, the black-hole sky shows through where terrain is absent.
    float edens = (0.6931472 / AL_END_FOG_HALF) * max(userDensity, 0.0) * densityMul;
    float eFogF = 1.0 - exp(-edens * max(dist, 0.0));
    vec3  eInsc = AL_END_FOG * scatterTint * darken;
    return max(sceneColor * (1.0 - eFogF) + eInsc * eFogF, vec3(0.0));
#else
    // Sky-exposure gate: no open sky above -> no aerial fog (caves/interiors).
    // RELAXED with distance so distant cave mouths/holes still fog (see the tunable
    // header): near caves stay clear, far low-sky pixels fog like any terrain.
    float skyGate   = smoothstep(AL_FOG_SKY_GATE_LO, AL_FOG_SKY_GATE_HI, skyLightmap);
    float gateRelax = smoothstep(AL_FOG_GATE_RELAX_NEAR, AL_FOG_GATE_RELAX_FAR, dist);
    float effGate   = max(skyGate, gateRelax);

    float farD = max(farDist, 16.0);

    // --- DISTANCE-BASED fog amount (0.4.8) --------------------------------
    // Base aerial haze: DISTANCE only (no height term), so it never thins on high
    // terrain. userDensity (GUI FOG_DENSITY) + biome scale it.
    float density = (0.6931472 / AL_FOG_DIST_HALF) * max(userDensity, 0.0) * densityMul;
    float baseFog = 1.0 - exp(-density * max(dist, 0.0));

    // --- Patchy far gradient + solid wall (5.0.5) -------------------------
    // From ~AL_FOG_MID_CHUNKS chunks out the fog builds UNEVENLY (world-ish noise
    // -> patchy, real banks) so the far field gets progressively less clear, then
    // the last AL_FOG_EDGE_CHUNKS chunks become a SOLID wall that hides the
    // unrendered-chunk dropoff/void. Absolute chunk distance (same at any render
    // distance).
    float wallChunks = AL_FOG_EDGE_CHUNKS;
    float midStart = farD - AL_FOG_MID_CHUNKS * 16.0;
    float midEnd   = farD - wallChunks * 16.0;
    float mid = smoothstep(midStart, midEnd, dist);
    vec2  np    = worldDir.xz * (dist * 0.02);
    float patch = alFogNoise(np) * 0.6 + alFogNoise(np * 2.3 + 7.0) * 0.4;
    // FOG_PATCHINESS blends between a smooth radial ramp (0) and strongly broken
    // banks (>=1). At 0 the multiplier is a flat 1.0 (no patch modulation).
    mid *= mix(1.0, mix(0.35, 1.10, patch), FOG_PATCHINESS);
    // Solid wall in the last wallChunks. Guarded so FOG_WALL_CHUNKS = 0 => no wall
    // (smoothstep is undefined when edge0 >= edge1, so branch it out).
    float wallStart = farD - wallChunks * 16.0;
    float wallEnd   = farD - 8.0;
    float wall = (wallEnd > wallStart) ? smoothstep(wallStart, wallEnd, dist) : 0.0;
    float edge = clamp(max(mid, wall), 0.0, 1.0);

    // The NEAR base haze is sky-gated (caves/interiors stay clear), but the FAR
    // patchy+wall fog is NOT — otherwise a distant cave mouth / hole in the surface
    // (low sky lightmap) punches an unfogged dark hole through the far fog. At the
    // render edge everything must drown in fog regardless of sky access.
    float fogF = max(baseFog * effGate, edge);

    // --- Time-of-day factors ---------------------------------------------
    // SOURCE OF TRUTH: lib/lighting.glsl `alDayFactor` (the pack's canonical
    // day/night ramp). fog.glsl does not include lighting.glsl, so the exact
    // same expression is replicated here VERBATIM — fog and lighting therefore
    // transition at identical sun elevations. Do NOT diverge this smoothstep; if
    // alDayFactor changes, mirror the change here.
    float dayF   = alSmooth(smoothstep(-0.06, 0.16, worldSunDir.y));
    float nightF = 1.0 - dayF;

    // --- DIRECTION-INDEPENDENT HAZE (0.4.6b — THE real horizon fix) --------
    // ROOT CAUSE (confirmed via the debug views): aerial fog used to sample the sky
    // IN THE VIEW DIRECTION for its in-scatter. Looking at distant terrain the view
    // direction IS the horizon (dir.y ~ 0) — the bright horizon band — so the fog
    // reproduced that band ON the terrain. Softening the sky could never fix it
    // because the fog was independently re-drawing the band. The bright horizon
    // must live ONLY in the actual sky (which terrain masks), so the fog tone is now
    // DIRECTION-INDEPENDENT: a uniform, dark, time-of-day haze (analytic hemisphere
    // ambient, dimmed — like vanilla fog) + a dim cool night floor. Distant terrain
    // now fades to a flat hazy SILHOUETTE; no horizon band is ever painted on it, at
    // any view angle. `worldDir`/`farDist`/`skyGate` stay in the signature but no
    // longer steer the tone (skyGate still gates DENSITY above).
    vec3 haze = alAmbientColor(worldSunDir) * AL_FOG_TONE_DIM;          // uniform, TOD
    haze += AL_MOON_TINT * (AL_FOG_NIGHT_LEVEL * nightF);              // night floor
    haze *= scatterTint * darken;                                     // biome/weather
    haze = mix(haze, vec3(alLuminance(haze)), alSaturate(desat));      // rain desat

    // ISSUE 14: crush + cool the haze at night so fogged distance darkens into
    // moonlit silhouettes, not pale mist. mix(...,1.0,dayF) leaves noon untouched.
    vec3 nightHaze = mix(vec3(0.60, 0.70, 1.00), vec3(1.0), dayF)
                   * mix(AL_FOG_NIGHT_DIM, 1.0, dayF);
    haze *= nightHaze;

    // Mid-field = uniform dark haze (atmospheric depth). Far edge converges to the
    // DIRECTION-INDEPENDENT far/horizon fog colour (grey, sky-bright) — NOT the sky
    // sampled in the view direction, so a horizon band is NEVER painted on terrain.
    // The horizon SKY converges to the SAME colour (composite2 sky path), so far
    // terrain and the void beyond meet seamlessly.
    vec3 farCol    = alFogFarColor(worldSunDir, rainStrength, wetness, thunderStrength);
    vec3 inscatter = mix(haze, farCol, edge);

    vec3 result = sceneColor * (1.0 - fogF) + inscatter * fogF;
    return max(result, vec3(0.0));
#endif  // dimension branch
}

#endif // AL_LIB_FOG
