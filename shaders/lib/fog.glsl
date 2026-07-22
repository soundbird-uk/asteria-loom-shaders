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
 extinction = exp(-tau) darkens
 the scene toward the distance while in-scattered light — sampled from the
 atmosphere's own sky LUT in the view direction, alSkySample(viewDir) — is
 added back in. Because the in-scatter colour IS the sky, distance naturally
 shifts bluer + desaturated with a warm hazy horizon, and the whole thing
 tracks time of day for free (the LUT already encodes sun elevation). Biome
 and weather nudge density and tint the in-scatter (tables below). Sky pixels
 (depth == 1) are left untouched — the clouds pass already carries the sky's
 own transmittance and must not be fogged twice — and underwater is skipped
 entirely (Phase 4 owns it).

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

/* -------------------------------------------------------------------------
   Tunables (internal, not GUI — edit + hot-reload). The GUI FOG_DENSITY
   slider (settings.glsl) multiplies AL_FOG_SEA_DENSITY on top of these.
   ------------------------------------------------------------------------- */

// Extinction coefficient at sea level, per world-metre, at FOG_DENSITY = 1 and
// in a neutral biome/clear weather. Tuned so a horizontal view reaches ~half
// extinction near ~150 m of clear air (ln2 / 0.0046 ≈ 150) — a soft dreamy
// haze, not soup.
#define AL_FOG_SEA_DENSITY 0.0046

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

/* -------------------------------------------------------------------------
   Full aerial-perspective evaluation for one pixel.
     sceneColor   — linear HDR colour under the fog (colortex0)
     camY         — camera world Y (cameraPosition.y)
     worldDir     — unit world-space view direction (camera -> fragment)
     dist         — straight-line distance camera -> fragment (metres)
     skyLightmap  — this pixel's raw sky lightmap (colortex2.a); gates fog so
                    caves/interiors (sky-lm ~0) get none. See AL_FOG_SKY_GATE_*.
     (biome/weather uniform values passed through to alFogModulation)
   Returns the fogged linear HDR colour.
   ------------------------------------------------------------------------- */
vec3 alApplyAerialFog(vec3 sceneColor, float camY, vec3 worldDir, float dist,
                      float userDensity, float skyLightmap, int biomeCategory,
                      float temperature, float rainfall, float rainStrength,
                      float wetness, float thunderStrength) {
    float densityMul; vec3 scatterTint; float desat; float darken;
    alFogModulation(biomeCategory, temperature, rainfall,
                    rainStrength, wetness, thunderStrength,
                    densityMul, scatterTint, desat, darken);

    // Sky-exposure gate: no open sky above -> no aerial fog (caves/interiors).
    float skyGate = smoothstep(AL_FOG_SKY_GATE_LO, AL_FOG_SKY_GATE_HI, skyLightmap);

    float beta0 = AL_FOG_SEA_DENSITY * max(userDensity, 0.0) * densityMul * skyGate;
    float tau   = alFogOpticalDepth(camY, worldDir, dist, beta0);
    float ext   = exp(-tau);                 // 1 = clear, 0 = fully fogged

    // In-scatter = sky radiance in the view direction, biome-tinted, thunder-
    // darkened, rain-desaturated. This is what makes distance read bluer/hazier
    // and warm at the horizon — the colour comes straight from the atmosphere.
    vec3 inscatter = alFogSkyInscatter(worldDir) * scatterTint * darken;
    inscatter = mix(inscatter, vec3(alLuminance(inscatter)), desat);

    vec3 result = sceneColor * ext + inscatter * (1.0 - ext);
    return max(result, vec3(0.0));
}

#endif // AL_LIB_FOG
