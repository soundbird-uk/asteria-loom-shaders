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
// 0.4.3 FIELD FIX (ISSUE 15: "fog far too thick / whole mid-distance washes to
// haze / forms a band"): the 0.3.3 value of 0.0068 put HALF extinction at only
// ~102 m, so at a 20-24 chunk (320-384 block) render distance everything beyond a
// hundred blocks drowned in haze and the flat horizon blew out to a bright band.
// Dropped ~4.3x to 0.0016: half extinction now at ln2/0.0016 ≈ 433 m, i.e. at
// 320 blocks a flat sea-level horizon reaches ~40% haze (gentle, seals the seam)
// while mid-scene terrain at 120-150 m sits at ~17-21% — subtle aerial depth, not
// a wall. Elevated terrain (mountains) fogs even less (height falloff). GUI
// FOG_DENSITY still scales this for anyone who wants a soupier look.
#define AL_FOG_SEA_DENSITY 0.0016

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
#define AL_FOG_TONE_MIX    0.55
#define AL_FOG_TONE_LUMCUT 0.50
#define AL_FOG_TONE_DIM    0.75

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

// --- Distance convergence to sky (0.4.2 REWORK, ISSUE 1: kill the band) ------
// The terrain/sky boundary must be seamless WITHOUT a bright horizontal band.
// Root cause of the 0.4.1 band: the old convergence blended toward the RAW BRIGHT
// sky on a DISTANCE plane ([0.92,0.985]·far), painting bright sky over legitimate
// mid-distance terrain (a horizontal line across mountains, since the fog tone is
// darker than the sky). Fix — make convergence PRIMARILY a function of OPTICAL
// DEPTH, not distance:
//   * PRIMARY (CONVERGE_A/B): the in-scatter colour lerps fogTone -> raw sky by
//     smoothstep(A, B, 1-ext). Mid haze (tau ~0.5-1.5, 1-ext < ~0.86) stays the
//     dark scene tone; only heavily-extincted rays (tau >~2.5-3, 1-ext > ~0.9)
//     approach the raw sky, so terrain converges to EXACTLY the sky colour
//     asymptotically — no plane, no band, at ANY render distance. Crucially,
//     ELEVATED terrain (mountains) has LOW optical depth, so it stays dark: the
//     band across mountains cannot form. Haze instead rises smoothly up a slope
//     (base fogs, peak stays crisp) — correct aerial perspective.
//   * EDGE INSURANCE (EDGE_*): a thin strip [0.965,0.995]·far for LOW render
//     distances, where even the horizon ground can't reach convergence tau. It is
//     gated by skyGate AND a SHARP fog-thickness gate smoothstep(FOG_LO,FOG_HI,
//     1-ext) so ONLY the heavily-fogged flat horizon converges — low-tau silhou-
//     ettes (mountain peaks) at the very edge are excluded and keep their colour.
// Numeric check (horizon terrain vs sky, 0.995·far): delta 0% at far>=256, ~5-7%
// at far=192 — imperceptible, and no band at any distance.
// 0.4.3 (ISSUE 13: "orange ring / skybox through terrain"): pushed the whole
// convergence LATE (A 0.86->0.93, B 0.975->0.995) so terrain keeps the dark,
// scene-referenced fogTone far longer and only the genuinely near-opaque flat
// horizon (fogF -> ~1) reaches the raw sky. With the 4x thinner density this means
// convergence happens ONLY at the true horizon line, never as a mid-distance ring
// painted over legitimate terrain — so no orange circle follows the camera.
#define AL_FOG_CONVERGE_A   0.93     // 1-ext where sky-convergence begins
#define AL_FOG_CONVERGE_B   0.995    // 1-ext where it completes
// Edge-insurance strip: kept only as a razor-thin seam seal at the very far plane
// and gated harder on fog thickness, so mountain silhouettes at the edge keep
// their colour and the strip never reads as a coloured band/ring.
#define AL_FOG_EDGE_START   0.985    // edge-insurance strip start (fraction of far)
#define AL_FOG_EDGE_END     0.999    // edge-insurance strip end
#define AL_FOG_EDGE_FOG_LO  0.60     // fog-thickness gate: below -> excluded (peaks)
#define AL_FOG_EDGE_FOG_HI  0.85     // fog-thickness gate: above -> converge (ground)

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
    float rain = alSaturate(max(rainStrength, wetness * 0.6));
    densityMul *= mix(1.0, 1.8, rain);
    desat       = rain * 0.6;
    darken      = mix(1.0, 0.72, alSaturate(thunderStrength));
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

    // Sky-exposure gate: no open sky above -> no aerial fog (caves/interiors).
    float skyGate = smoothstep(AL_FOG_SKY_GATE_LO, AL_FOG_SKY_GATE_HI, skyLightmap);

    float beta0 = AL_FOG_SEA_DENSITY * max(userDensity, 0.0) * densityMul * skyGate;
    float tau   = alFogOpticalDepth(camY, worldDir, dist, beta0);
    float ext   = exp(-tau);                 // 1 = clear, 0 = fully fogged
    float fogF  = 1.0 - ext;                 // how fogged this pixel is (0..1)

    // Single NaN-safe sky read, reused for the in-scatter tone AND the far-fade
    // target (one colortex6 read).
    vec3 sky = alFogSkyInscatter(worldDir);

    // --- Time-of-day factors ---------------------------------------------
    // SOURCE OF TRUTH: lib/lighting.glsl `alDayFactor` (the pack's canonical
    // day/night ramp). fog.glsl does not include lighting.glsl, so the exact
    // same expression is replicated here VERBATIM — fog and lighting therefore
    // transition at identical sun elevations. Do NOT diverge this smoothstep; if
    // alDayFactor changes, mirror the change here.
    float dayF   = alSmooth(smoothstep(-0.06, 0.16, worldSunDir.y));
    float nightF = 1.0 - dayF;

    // --- RE-TONE the in-scatter (ISSUE 2: darker, scene-coloured) ---------
    // Move the bright sky toward a muted SCENE tone: analytic hemisphere ambient
    // (cool blue-purple day / mauve dusk / cool moon night) mixed with a
    // luminance cut of the sky, then dimmed. Fog reads as depth, not white glow.
    float skyLum   = alLuminance(sky);
    vec3  sceneTone = mix(alAmbientColor(worldSunDir), vec3(skyLum), AL_FOG_TONE_LUMCUT)
                    * AL_FOG_TONE_DIM;
    vec3  fogColor  = mix(sky, sceneTone, AL_FOG_TONE_MIX);

    // Night floor (ISSUE 3): a dim cool moon-tinted haze so distance still reads
    // as depth after dark (sky sample is ~black at night). Auto-gated by ext via
    // the (1-ext) weight below (no night fog in caves).
    fogColor += AL_MOON_TINT * (AL_FOG_NIGHT_LEVEL * nightF);

    // Biome tint + thunder darkening on the re-toned colour.
    fogColor *= scatterTint * darken;

    // Ground-ward softening (ISSUE 1b / old BUG A): compress any residual >1 for
    // rays at/below the horizon (toward-sun haze) + gentle desaturation, so haze
    // never reads as a bright layer painted in front of terrain. This is the
    // MID-DISTANCE fog colour ("fogTone") — dark, scene-referenced.
    float groundy = 1.0 - smoothstep(AL_FOG_GROUND_LO, AL_FOG_GROUND_HI, worldDir.y);
    vec3  fogTone = alFogSoftKnee(fogColor, groundy);
    float totalDesat = alSaturate(desat + AL_FOG_HORIZON_DESAT * groundy);
    fogTone = mix(fogTone, vec3(alLuminance(fogTone)), totalDesat);

    // --- PRIMARY convergence to sky by OPTICAL DEPTH (ISSUE 1, 0.4.2) ------
    // As the ray becomes heavily extincted the in-scatter COLOUR approaches the
    // RAW sky, so distant/grazing terrain merges into the sky asymptotically —
    // no distance plane, no bright band, at any render distance. Mid haze stays
    // the dark fogTone; ELEVATED terrain (mountains) has low tau -> stays dark
    // (no band across it — haze rises smoothly up a slope instead).
    float hTau = smoothstep(AL_FOG_CONVERGE_A, AL_FOG_CONVERGE_B, fogF);
    vec3  inscatter = mix(fogTone, sky, hTau);

    // ISSUE 14 ("night distance too white/grey"): crush + cool the WHOLE in-scatter
    // at night. The raw sky sample and scene tone still carry a dim grey that, once
    // terrain is fogged, reads as pale mist over distant hills; multiplying by a
    // cool, dim night factor turns that into dark, desaturated, moonlit silhouettes.
    // mix(...,1.0,dayF) makes noon provably untouched.
    vec3  nightHaze = mix(vec3(0.60, 0.70, 1.00), vec3(1.0), dayF)   // cool by night
                    * mix(AL_FOG_NIGHT_DIM, 1.0, dayF);              // dim by night
    inscatter *= nightHaze;

    vec3 aerial = sceneColor * ext + inscatter * fogF;

    // --- EDGE INSURANCE (thin, low-render-distance only) ------------------
    // Where even the horizon ground can't reach convergence tau (small render
    // distance), a thin strip [START,END]·far closes the residual seam. Gated by
    // skyGate AND a SHARP fog-thickness gate so ONLY the heavily-fogged flat
    // horizon converges — low-tau silhouettes (mountain peaks) at the very edge
    // are excluded and keep their colour, so this can never paint a band either.
    float f = max(farDist, 1.0);
    float edge = smoothstep(AL_FOG_EDGE_START, AL_FOG_EDGE_END, dist / f)
               * skyGate
               * smoothstep(AL_FOG_EDGE_FOG_LO, AL_FOG_EDGE_FOG_HI, fogF);
    // Converge the seam seal to the SAME night-dimmed haze, not the raw (brighter)
    // sky, so the far edge stays dark at night instead of glowing.
    vec3  result = mix(aerial, sky * nightHaze, edge);

    return max(result, vec3(0.0));
}

#endif // AL_LIB_FOG
