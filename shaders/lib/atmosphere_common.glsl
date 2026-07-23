#ifndef AL_LIB_ATMOSPHERE_COMMON
#define AL_LIB_ATMOSPHERE_COMMON

/*
 lib/atmosphere_common.glsl — the SAMPLER-FREE core of the Asteria Loom
 atmosphere model. Pure GLSL 3.30 math: no samplers, no uniform declarations,
 no state. Every function takes the directions it needs as arguments so this
 file can be included ANYWHERE (including lib/lighting.glsl, and therefore the
 forward translucent passes) without pulling in a single sampler.

 The LUT read (alSkySample) lives in lib/atmosphere.glsl, which includes this
 file and adds the one sampler (colortex6). Passes that shade geometry
 (deferred1, water, particles, ...) include ONLY the lighting lib, so they get
 the analytic direct/ambient colours here and NEVER the LUT sampler — this is
 the hard sampler-budget requirement of the Phase-3 contract.

 ---------------------------------------------------------------------------
 MODEL — analytic single-scattering (Nishita-style), LUT-free.
 ---------------------------------------------------------------------------
 A spherical planet (radius Rg) inside an atmosphere shell (radius Rt). For a
 view direction we ray-march the view segment; at each sample we add Rayleigh
 and Mie in-scattering weighted by:
   * the view transmittance from the camera to the sample (accumulated), and
   * the sun/moon transmittance from the sample out to space, obtained by a
     short secondary optical-depth integration of the exponential slant path
     (the Chapman grazing-incidence integral, evaluated numerically so it stays
     robust and NaN-free at every zenith angle — the brief's "Chapman-function
     transmittance, LUT-free" requirement, integrated rather than approximated
     with a rational fit so no acos/pow/exp ever leaves its domain).
 Ozone is carried as pure extinction (a tent around ~25 km) so the zenith reads
 the characteristic deep blue instead of washing out.

 Rayleigh phase = 3/(16pi)(1+mu^2); Mie phase = Henyey-Greenstein g=0.76.
 Planet shadow: a sun ray that intersects the planet returns ~zero
 transmittance, so nights and the anti-sun horizon go dark correctly.

 NUMERICAL DISCIPLINE (Apple GL 4.1, #version 330): every acos/asin input is
 clamped to [-1,1], every sqrt argument to >=0, every divisor guarded, every
 exp argument bounded. No helper can emit a NaN or Inf.

 ---------------------------------------------------------------------------
 SKY-VIEW LUT TILE MAPPING (shared by the prepare write side and the
 alSkySample read side via alSkyMapUV / alSkyDecodeDir — they are exact
 inverses so the two sides can never diverge).
 ---------------------------------------------------------------------------
 The tile is the top-left AL_SKY_TILE_W x AL_SKY_TILE_H (256x128) texels of
 colortex6. It is a full-sphere lat-long map:
   u (azimuth)  = atan(dir.z, dir.x) / TAU, wrapped to [0,1)
   v (elevation)= 0.5 + 0.5 * sign(dir.y) * sqrt(|dir.y|)
 The signed-sqrt elevation warp packs extra resolution around the HORIZON
 (dir.y ~ 0, v ~ 0.5) where the gradient is steepest, at the expense of the
 zenith/nadir where the sky is nearly flat. Decode inverts it exactly:
   dir.y = sign(v-0.5) * (2|v-0.5|)^2.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"

// Sky-view LUT tile dimensions (texels), top-left of colortex6.
#define AL_SKY_TILE_W 256.0
#define AL_SKY_TILE_H 128.0

// --- Planet / atmosphere geometry (metres) --------------------------------
#define AL_RG 6360000.0          // planet radius
#define AL_RT 6420000.0          // atmosphere top radius
#define AL_HR 8000.0             // Rayleigh scale height
#define AL_HM 1200.0             // Mie scale height
#define AL_CAM_ALT 500.0         // fixed viewer altitude above the surface

// Scattering / extinction coefficients (per metre).
// Rayleigh (wavelength dependent — blue scatters most).
#define AL_BETA_R vec3(5.8e-6, 13.5e-6, 33.1e-6)
// Mie scattering (grey); extinction is a touch higher (single-scatter albedo ~0.9).
#define AL_BETA_M_S 21e-6
#define AL_BETA_M_E 23.3e-6
// Ozone extinction (tent around ~25 km); keeps the zenith blue rich.
#define AL_BETA_O vec3(3.426e-7, 8.298e-7, 3.550e-8)

// Sun/moon disc-integrated radiance feeding the sky (arbitrary HDR units; the
// tonemap + EXPOSURE bring it to display range).
#define AL_SUN_SKY_INTENSITY 22.0
#define AL_MOON_SKY_INTENSITY 0.28   // cool, dim night key

#define AL_MIE_G 0.76

// ------------------------------------------------------------------------
// LUT tile mapping (shared write/read).
// ------------------------------------------------------------------------

// Direction -> tile UV in [0,1]^2 (azimuth x horizon-biased elevation).
vec2 alSkyMapUV(vec3 dir) {
    dir = normalize(dir);
    float u = atan(dir.z, dir.x) * (1.0 / AL_TAU);   // (-0.5 .. 0.5]
    u = fract(u + 1.0);                              // wrap to [0,1)
    float y = clamp(dir.y, -1.0, 1.0);
    float v = 0.5 + 0.5 * sign(y) * sqrt(abs(y));
    return vec2(u, clamp(v, 0.0, 1.0));
}

// Tile UV in [0,1]^2 -> unit direction (exact inverse of alSkyMapUV).
vec3 alSkyDecodeDir(vec2 uv) {
    float phi = uv.x * AL_TAU;
    float t = clamp(uv.y, 0.0, 1.0) * 2.0 - 1.0;     // (-1 .. 1)
    float y = sign(t) * t * t;                        // horizon-biased elevation
    y = clamp(y, -1.0, 1.0);
    float r = sqrt(max(1.0 - y * y, 0.0));
    return normalize(vec3(r * cos(phi), y, r * sin(phi)));
}

// ------------------------------------------------------------------------
// Geometry helpers.
// ------------------------------------------------------------------------

// Ray-sphere (sphere centred at the origin = planet centre). Returns the two
// signed roots (near, far). No intersection -> vec2(-1, -1). NaN-safe: the
// sqrt argument is clamped to >= 0.
vec2 alRaySphere(vec3 ro, vec3 rd, float R) {
    float b = dot(ro, rd);
    float c = dot(ro, ro) - R * R;
    float d = b * b - c;
    if (d < 0.0) return vec2(-1.0, -1.0);
    float s = sqrt(max(d, 0.0));
    return vec2(-b - s, -b + s);
}

// Ozone density tent (unitless 0..1), peaking near 25 km.
float alOzoneDensity(float h) {
    return max(0.0, 1.0 - abs(h - 25000.0) / 15000.0);
}

// Combined per-metre extinction at altitude h (metres above the surface).
vec3 alExtinctionAt(float h, float mie) {
    h = max(h, 0.0);
    float dR = exp(-h / AL_HR);
    float dM = exp(-clamp(h / AL_HM, 0.0, 60.0));
    float dO = alOzoneDensity(h);
    return AL_BETA_R * dR + (AL_BETA_M_E * mie) * dM + AL_BETA_O * dO;
}

// Optical depth (per-channel integrated extinction) from point p along dir out
// to the atmosphere top. If the ray hits the planet first the path is blocked
// (planet shadow) and we return a very large depth so exp(-depth) -> 0.
// This numerically evaluates the Chapman slant-path integral; 6 exponential
// samples are ample for a smooth transmittance term.
vec3 alOpticalDepth(vec3 p, vec3 dir, float mie) {
    // Blocked by the planet? (grazing into the ground)
    vec2 pg = alRaySphere(p, dir, AL_RG);
    if (pg.x > 0.0) return vec3(1e6);

    vec2 atmo = alRaySphere(p, dir, AL_RT);
    float far = max(atmo.y, 0.0);
    if (far <= 0.0) return vec3(0.0);

    const int N = 6;
    float seg = far / float(N);
    vec3 od = vec3(0.0);
    for (int i = 0; i < N; i++) {
        vec3 xp = p + dir * (seg * (float(i) + 0.5));
        float h = length(xp) - AL_RG;
        od += alExtinctionAt(h, mie) * seg;
    }
    return od;
}

// Rayleigh phase.
float alPhaseR(float mu) {
    return (3.0 / (16.0 * AL_PI)) * (1.0 + mu * mu);
}

// Henyey-Greenstein Mie phase.
float alPhaseM(float mu, float g) {
    float g2 = g * g;
    float denom = 1.0 + g2 - 2.0 * g * mu;
    denom = max(denom, 1e-4);
    return (1.0 - g2) / (4.0 * AL_PI * pow(denom, 1.5));
}

// ------------------------------------------------------------------------
// FULL single-scatter radiance for one view direction (prepare-only cost).
// dir and sunDir are world-space unit vectors (+y = up). Returns linear HDR
// radiance BEFORE SKY_BRIGHTNESS (prepare bakes that in).
// ------------------------------------------------------------------------
vec3 alSkyRadiance(vec3 dir, vec3 sunDir) {
    dir = normalize(dir);
    sunDir = normalize(sunDir);
    vec3 moonDir = -sunDir;

    float mie = MIE_STRENGTH * TURBIDITY;

    // Camera just above the surface, looking along dir.
    vec3 ro = vec3(0.0, AL_RG + AL_CAM_ALT, 0.0);

    vec2 atmo = alRaySphere(ro, dir, AL_RT);
    float tFar = max(atmo.y, 0.0);
    // If the view ray strikes the planet, march only to the ground hit so the
    // horizon/void reads the (dim) ground-scattered colour, not through-planet.
    vec2 grnd = alRaySphere(ro, dir, AL_RG);
    if (grnd.x > 0.0) tFar = min(tFar, grnd.x);
    if (tFar <= 0.0) return vec3(0.0);

    const int N = 16;
    float seg = tFar / float(N);

    vec3 odView = vec3(0.0);          // accumulated view-path optical depth
    vec3 sunR = vec3(0.0), sunM = vec3(0.0);
    vec3 moonR = vec3(0.0), moonM = vec3(0.0);

    for (int i = 0; i < N; i++) {
        vec3 xp = ro + dir * (seg * (float(i) + 0.5));
        float h = max(length(xp) - AL_RG, 0.0);
        float dR = exp(-h / AL_HR);
        float dM = exp(-clamp(h / AL_HM, 0.0, 60.0));

        // Advance the view optical depth to this sample's midpoint.
        odView += alExtinctionAt(h, mie) * seg;

        // Sun contribution.
        vec3 odSun = alOpticalDepth(xp, sunDir, mie);
        vec3 Tsun = exp(-min(odView + odSun, vec3(30.0)));
        sunR += Tsun * (dR * seg);
        sunM += Tsun * (dM * seg);

        // Moon contribution (much dimmer; same machinery, opposite dir).
        vec3 odMoon = alOpticalDepth(xp, moonDir, mie);
        vec3 Tmoon = exp(-min(odView + odMoon, vec3(30.0)));
        moonR += Tmoon * (dR * seg);
        moonM += Tmoon * (dM * seg);
    }

    float muSun = clamp(dot(dir, sunDir), -1.0, 1.0);
    float muMoon = clamp(dot(dir, moonDir), -1.0, 1.0);

    vec3 betaMs = vec3(AL_BETA_M_S * mie);

    vec3 sun = (sunR * AL_BETA_R * alPhaseR(muSun)
              + sunM * betaMs * alPhaseM(muSun, AL_MIE_G)) * AL_SUN_SKY_INTENSITY;

    // Moon light is cool: bias its colour and keep it dim.
    vec3 moon = (moonR * AL_BETA_R * alPhaseR(muMoon)
               + moonM * betaMs * alPhaseM(muMoon, AL_MIE_G))
               * AL_MOON_SKY_INTENSITY * AL_MOON_TINT;

    vec3 result = sun + moon;
    // Final NaN/Inf guard (comparisons, not isnan): anything out of a sane
    // range collapses to a safe dark value rather than poisoning the LUT.
    if (!all(greaterThanEqual(result, vec3(0.0))) ||
        !all(lessThan(result, vec3(1e4)))) {
        result = vec3(0.0);
    }
    return result;
}

// ------------------------------------------------------------------------
// Cheap analytic sky fallback (sun-independent) — used ONLY when a LUT read
// is out of range (the clear=false first-frame garbage). It must never be
// black. A soft horizon-warm / zenith-cool gradient, SKY_BRIGHTNESS-scaled to
// match the baked LUT.
// ------------------------------------------------------------------------
vec3 alSkyFallback(vec3 dir) {
    float up = clamp(dir.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 horizon = vec3(0.42, 0.52, 0.70);
    vec3 zenith  = vec3(0.16, 0.30, 0.62);
    vec3 c = mix(horizon, zenith, smoothstep(0.45, 0.9, up));
    return c * SKY_BRIGHTNESS;
}

// ------------------------------------------------------------------------
// Analytic sunlight colour (no march) for the DIRECT lighting term.
// Returns ~white at the zenith, reddening as the sun descends (blue attenuates
// first along the longer air path). Normalised so the brightest channel stays
// ~1: the pack's warm-amber identity comes from AL_SUN_TINT as a MODIFIER, so
// noon direct light == AL_SUN_TINT (no regression from the 0.2.x look) and low
// sun adds reddening on top.
// ------------------------------------------------------------------------
vec3 alSunlightColor(float sunHeight) {
    float cosZ = max(sunHeight, 0.04);
    // Smooth, bounded relative air mass (~1 at zenith, ~25-40 at the horizon).
    float airmass = 1.0 / (cosZ + 0.025 * exp(-11.0 * cosZ));
    // Per-channel relative optical depth (blue > green > red), scaled by
    // turbidity so hazier air reddens the sun as it descends.
    // GOLDEN-HOUR RETUNE (0.4.3, ISSUE 3/4): the old (0.20,0.55,1.30)*0.35 ramp
    // crushed the low sun to a near-BLACK deep red (T ~= (0.19,0.01,0.00) at the
    // horizon), so sunrise/sunset had almost no directional key — flat, weak
    // shadows. We (a) lower the per-channel taus so the reddening is gentler, and
    // (b) RE-NORMALISE the result to its brightest channel, so a low sun keeps its
    // LUMINANCE and shifts HUE toward warm orange instead of dimming to black.
    // The warmth is then a colour shift (bright golden key) — physically the sun's
    // *radiance* barely falls until it grazes; the visible dimming at sunset is
    // aerial extinction of the whole scene (fog), not the key going dark. This is
    // exactly the strong, warm, directional low-sun light the brief wants.
    vec3 tau = vec3(0.14, 0.34, 0.80) * (0.30 * TURBIDITY);
    vec3 T = exp(-tau * max(airmass - 1.0, 0.0));    // zenith -> (1,1,1)
    T /= max(max(T.r, T.g), max(T.b, 0.02));         // keep luminance, shift hue
    return clamp(T, 0.0, 1.0);
}

// Direct key-light colour: warm sun by day, cool dim moon by night. The warm
// amber bias (AL_SUN_TINT) is applied HERE as a multiplicative modifier.
vec3 alDirectColor(vec3 worldSunDir) {
    float h = clamp(normalize(worldSunDir).y, -1.0, 1.0);
    float day = smoothstep(-0.06, 0.16, h);          // matches alDayFactor ramp
    vec3 sun = alSunlightColor(h) * AL_SUN_TINT;
    vec3 moon = AL_MOON_TINT * 0.16;
    return mix(moon, sun, day) * SUN_INTENSITY;
}

// Cool hemisphere sky-fill colour for the AMBIENT term. A cheap analytic
// stand-in for the hemisphere-averaged sky (the per-pixel lighting path cannot
// read the LUT sampler): AL_AMBIENT_SKY identity tint, day-scaled brightness,
// warming toward a dusk mauve at low sun. Tuned so noon == AL_AMBIENT_SKY.
vec3 alAmbientColor(vec3 worldSunDir) {
    float h = clamp(normalize(worldSunDir).y, -1.0, 1.0);
    float bright = mix(0.18, 1.0, smoothstep(-0.12, 0.20, h));
    vec3 dayTone  = vec3(1.00, 1.00, 1.00);
    vec3 duskTone = vec3(1.25, 0.85, 0.95);
    vec3 tone = mix(duskTone, dayTone, smoothstep(-0.02, 0.22, h));
    return AL_AMBIENT_SKY * tone * bright;
}

#endif // AL_LIB_ATMOSPHERE_COMMON
