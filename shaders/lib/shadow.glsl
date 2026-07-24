#ifndef AL_LIB_SHADOW
#define AL_LIB_SHADOW

/*
 lib/shadow.glsl — Phase-2 shadows: distortion warp + PCSS + Mac fallback.

 This file owns ALL shadow-space math. Two entry points are exported:

   alShadowDistort(vec3 ndc)      — the distortion warp. Applied in shadow.vsh
                                    (warps the rendered geometry) AND in every
                                    lookup here (warps the sample coordinate).
                                    Both MUST use the same function or the map
                                    and the lookups disagree and everything
                                    self-shadows.
   alShadowVisibility(playerPos,  — direct-light visibility in [0,1]. Signature
                      worldN,       is UNCHANGED from Phase 1 so lib/lighting.glsl
                      NdotL)        and the forward translucent passes need no
                                    edits; they just get softer, distorted,
                                    contact-hardening shadows for free.

 ---------------------------------------------------------------------------
 DISTORTION WARP (documented formula + its local texel-scale derivative)
 ---------------------------------------------------------------------------
 Working in shadow-projection NDC (p.xy in [-1,1], p.z the light-axis depth):

     len    = length(p.xy)
     factor = (1 - k) + k*len          , k = AL_SHADOW_DISTORT  in (0,1)
     p.xy  /= factor                   , p.z unchanged

 This is the classic `p.xy /= (const + length(p.xy))` family the contract
 mandates, normalized so the map stays in range: the per-axis maximum of the
 output over the square [-1,1]^2 is reached on an axis (p_y = 0, |p_x| = 1),
 where factor = 1 and output_x = 1 exactly; every off-axis point has len > 1,
 factor > 1, |output| < 1. So NOTHING maps outside [-1,1] (corners pull inward)
 — no clipping at any k. At the centre (len = 0) factor = (1 - k), so geometry
 is magnified by 1/(1-k): with k = 0.85 that is ~6.7x LINEAR resolution right at
 the camera, tapering to 1x on the edge-midpoints. The useful near-camera gain
 averaged over the frustum is roughly 3x, which is what lets a 2048 map look
 sharp up close (brief §6, phase2 §3).

 Local texel scale (needed for bias / normal-offset that "account for the LOCAL
 warped texel size"): the radial magnification of the map is
     M_r = d(distorted)/d(undistorted) = (1-k) / factor^2
 (tangential magnification is the larger 1/factor, so M_r is the worst case for
 acne — the direction along which one distorted texel covers the MOST world).
 We therefore express a world radius as an *undistorted*-then-distorted-UV
 radius through the inverse, localScale = factor^2 / (1-k) = 1 / M_r:

     alShadowDistortDerivScale(p)  ==  factor^2 / (1 - k)

 localScale = 0.15 at the centre (texels tiny -> tiny bias needed) rising to
 ~6.7 on the edge (texels huge -> larger bias/offset needed). Every world->UV
 conversion below multiplies by it, so bias, normal-offset AND the PCSS
 penumbra are all position-dependent, exactly as required.
*/

#include "/lib/common.glsl"

// ---------------------------------------------------------------------------
// Distortion warp (always compiled; used by shadow.vsh and by lookups here).
// ---------------------------------------------------------------------------

// Warp a shadow-NDC position. Only xy is distorted; z (light-axis depth) is
// left untouched so depth comparisons stay linear in the map.
vec3 alShadowDistort(vec3 p) {
    float len    = length(p.xy);
    float factor = (1.0 - AL_SHADOW_DISTORT) + AL_SHADOW_DISTORT * len;
    return vec3(p.xy / factor, p.z);
}

// Local world-per-texel multiplier at shadow-NDC xy `pxy` (see header maths).
// Multiply a base (undistorted) texel/world size by this to get the LOCAL
// warped size.
float alShadowDistortDerivScale(vec2 pxy) {
    float len    = length(pxy);
    float factor = (1.0 - AL_SHADOW_DISTORT) + AL_SHADOW_DISTORT * len;
    return (factor * factor) / (1.0 - AL_SHADOW_DISTORT);
}

// The shadow reading block is skipped in the shadow *pass* vertex shader
// (which only needs the warp, and must not declare shadow samplers).
#if (defined SHADOWS || defined CONTACT_SHADOWS) && !defined AL_SHADOW_VSH
uniform sampler2D noisetex;        // 256x256 blue-ish noise, for per-pixel rotation / dither
#endif

#if defined SHADOWS && !defined AL_SHADOW_VSH

// --- Shadow samplers ------------------------------------------------------
// DEFAULT (robust, shipping) PATH — shadowHardwareFiltering = false: shadowtex0
// and shadowtex1 are PLAIN depth textures. We read RAW opaque depth and do the
// compare + soft PCF in-shader (`step(ref, stored)`), exactly the manual compare
// the field-correct 0.1.1 build used. This is IDENTICAL on Windows and macOS —
// no platform-divergent sampler semantics, no hardware-compare early-out — and
// PCSS's blocker search is just extra raw reads of the SAME texture, so
// contact-hardening still works. shadowtex1 is the OPAQUE depth (no translucent
// self-casting), matching 0.1.1.
//
// EXPERIMENTAL hardware path (AL_SHADOW_HW, OFF by default; see settings.glsl):
// compare samplers + hardware PCF. QUARANTINED — this path produced the 0.2.x
// field regressions (zero shadows on Windows via the blocker-search early-out;
// over-shadowing on macOS) and cannot be proven correct in CI. Enabling it also
// requires shadowHardwareFiltering = true in shaders.properties.
#ifdef AL_SHADOW_HW
    #ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
    uniform sampler2D       shadowtex0;    // raw depth of everything (blocker search)
    uniform sampler2DShadow shadowtex1HW;  // hardware-PCF opaque depth (filter taps)
    #else
    uniform sampler2DShadow shadowtex1;    // HWF=true makes this a compare sampler
    #endif
#else
    uniform sampler2D shadowtex1;          // RAW opaque depth: manual compare + PCSS blocker search
#endif

uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform int  frameCounter;

// PCSS needs a raw depth read for the blocker search.
//  * software path (default): shadowtex1 is raw -> always available.
//  * hardware path: only where SEPARATE_HARDWARE_SAMPLERS exposes raw shadowtex0.
#if defined SHADOW_PCSS && (!defined AL_SHADOW_HW || defined IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS)
    #define AL_SHADOW_PCSS_ACTIVE
#endif

// --- Vogel disc + R2 temporal rotation ------------------------------------
// Golden-angle Vogel disc: even, low-variance tap distribution. Per-pixel
// rotation phi comes from a noisetex value + an R2 low-discrepancy advance by
// frameCounter, so the noise pattern animates and averages out over frames.
vec2 alVogel(int i, int n, float phi) {
    float r     = sqrt((float(i) + 0.5) / float(n));
    float theta = float(i) * 2.399963230 + phi;   // 2.3999... = golden angle
    return r * vec2(cos(theta), sin(theta));
}

float alShadowRotation() {
    vec2 nz = texture(noisetex, gl_FragCoord.xy / 256.0).xy;
    // R2 sequence: a1 = 1/plastic-number. Advancing phi by it per frame gives a
    // maximally-spread temporal offset — BUT that only denoises if the frames are
    // temporally resolved. Under FXAA/Off (no temporal resolve) the animated
    // rotation just CRAWLS as grain on soft shadow edges (field report). So the
    // per-frame advance is applied ONLY under TAA; otherwise the rotation is a
    // STABLE per-pixel pattern (from noisetex) that FXAA smooths spatially and that
    // does not shimmer in motion.
#ifdef AL_TAA
    float r2 = fract(float(frameCounter) * 0.75487766624669276);
#else
    float r2 = 0.0;
#endif
    return (nz.x + r2) * AL_TAU;
}

// One shadow tap. Returns 1.0 = lit, 0.0 = occluded, at `uv` vs reference depth
// `refD` (the biased receiver depth). The default path does the compare manually
// on RAW depth: step(refD, stored) == (stored >= refD) == lit — the field-proven
// 0.1.1 convention. Averaged over the Vogel disc this gives the soft edge.
float alShadowCompare(vec2 uv, float refD) {
#ifdef AL_SHADOW_HW
    #ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
    return texture(shadowtex1HW, vec3(uv, refD));
    #else
    return texture(shadowtex1,   vec3(uv, refD));
    #endif
#else
    return step(refD, texture(shadowtex1, uv).r);
#endif
}

// Raw opaque depth read for the PCSS blocker search (only compiled when PCSS is
// active). Software path reads shadowtex1; the hardware separate-sampler path
// reads shadowtex0 (its raw-depth alias).
#ifdef AL_SHADOW_PCSS_ACTIVE
float alShadowRawDepth(vec2 uv) {
    #if defined AL_SHADOW_HW && defined IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
    return texture(shadowtex0, uv).r;
    #else
    return texture(shadowtex1, uv).r;
    #endif
}
#endif

// Maximum penumbra softness as a WORLD constant (metres), NOT texels. A texel
// cap would shrink the max world softness as shadowMapResolution rises, making
// ULTRA (3072) ~1.5x HARDER than MEDIUM (2048) and inverting the brief's
// "higher preset = softer/dreamier" intent. Keeping it in world units makes
// maximum softness resolution-independent. Tuned to preserve MEDIUM's look:
// realistic penumbrae stay well under this, so the cap only bounds extremes.
// (Lives here rather than settings.glsl because this fix is scoped to
// lib/shadow.glsl; guarded so a future settings.glsl definition wins.)
#ifndef AL_SHADOW_MAX_PEN_WORLD
#define AL_SHADOW_MAX_PEN_WORLD 1.8
#endif

// --- Distant-shadow + flat-grazing acne fixes (field bugs from 0.2.0) ------
// (Local to lib/shadow.glsl; guarded so a future settings.glsl value wins.)
//
// BUG A: the distortion's ~6.7x edge magnification made localScale huge at
// range, so a LINEAR offset/bias scaling pushed distant sample points ~1-2.5m
// off their occluders/receivers and deleted far shadows. We (1) hard-cap the
// world-space normal offset, (2) scale depth bias by sqrt(localScale) instead
// of localScale, and (3) cap the absolute depth bias. Together these keep far
// bias/offset near the pre-distortion (0.1.1) magnitudes that behaved.
#ifndef AL_SHADOW_OFFSET_MAX_WORLD
#define AL_SHADOW_OFFSET_MAX_WORLD 0.30   // metres — absolute normal-offset cap
#endif
#ifndef AL_SHADOW_BIAS_MAX_NDC
#define AL_SHADOW_BIAS_MAX_NDC 0.0025     // absolute depth-bias cap (shadow NDC)
#endif
// BUG B: flat translucent surfaces (ice) shade through the forward water path
// with only vertex normals; at grazing sun that is classic acne/moiré. Two
// universal levers (no per-pass detection needed): a quadratic grazing bias
// term, and a minimum PCF radius floor so the per-pixel-rotated Vogel disc
// smears any residual coherent moiré into fine (temporally-averaged) noise.
#ifndef AL_SHADOW_GRAZE_BIAS
#define AL_SHADOW_GRAZE_BIAS 0.0006       // extra bias * (1-NdotL)^2
#endif
#ifndef AL_SHADOW_ACNE_FLOOR_TEXELS
#define AL_SHADOW_ACNE_FLOOR_TEXELS 2.5   // min PCF radius (texels) vs flat moiré
#endif

// World radius (metres) -> distorted-UV radius at local warp scale. The shadow
// ortho spans 2*shadowDistance world units across the [0,1] UV range; the
// distortion then magnifies by 1/localScale (see header).
float alWorldToShadowUV(float worldR, float localScale) {
    return worldR / (2.0 * shadowDistance * localScale);
}

/*
 Direct-light visibility in [0,1]. 1.0 = fully lit.
   playerPos : world position relative to camera (player/feet space)
   worldN    : world-space geometric normal (normal offset)
   NdotL     : clamped N.L (drives slope-scaled bias + offset growth)
*/
float alShadowVisibility(vec3 playerPos, vec3 worldN, float NdotL) {
    // Project once WITHOUT the normal offset to read the local warp scale.
    vec4 vpos0 = shadowModelView * vec4(playerPos, 1.0);
    vec4 cpos0 = shadowProjection * vpos0;
    vec3 ndc0  = cpos0.xyz / cpos0.w;
    float localScale = alShadowDistortDerivScale(ndc0.xy);

    // Normal offset: push along the surface normal by one LOCAL warped texel,
    // grown at grazing angles where the projected footprint is largest.
    float baseTexelWorld = 2.0 * shadowDistance / float(shadowMapResolution);
    float offsetWorld = baseTexelWorld * localScale
                      * (AL_SHADOW_NOFFSET_BASE + (1.0 - NdotL) * AL_SHADOW_NOFFSET_SLOPE);
    // Cap the ABSOLUTE offset: near-camera localScale<1 keeps it tiny/crisp, but
    // at the map edge (localScale ~6.7) the uncapped value reaches ~1.75m and
    // shoves distant samples clean off their occluders (BUG A: far shadows gone).
    offsetWorld = min(offsetWorld, AL_SHADOW_OFFSET_MAX_WORLD);
    vec3 samplePos = playerPos + worldN * offsetWorld;

    // Re-project the offset point and warp it.
    vec4 cpos = shadowProjection * (shadowModelView * vec4(samplePos, 1.0));
    vec3 ndc  = cpos.xyz / cpos.w;
    vec3 warp = alShadowDistort(ndc);
    vec3 uvz  = warp * 0.5 + 0.5;               // -> [0,1]

    // Outside the map (or past the far plane) -> fully lit (never wrongly dark).
    if (uvz.x <= 0.0 || uvz.x >= 1.0 ||
        uvz.y <= 0.0 || uvz.y >= 1.0 || uvz.z >= 1.0) {
        return 1.0;
    }

    // Depth bias: slope-scaled, plus a quadratic grazing term (flat-surface /
    // ice acne), scaled by SQRT(localScale) not localScale. Linear localScale
    // made the far bias 0.3-0.7m and vanished distant shadows (BUG A); sqrt
    // keeps the edge bias ~0.15-0.28m while staying tiny near camera. A hard
    // absolute cap bounds the very-grazing + low-res worst case.
    float graze = 1.0 - NdotL;
    float depthBias = (AL_SHADOW_BIAS
                     + AL_SHADOW_SLOPE_BIAS * graze
                     + AL_SHADOW_GRAZE_BIAS * graze * graze) * sqrt(localScale);
    depthBias = min(depthBias, AL_SHADOW_BIAS_MAX_NDC);
    float refD  = uvz.z - depthBias;

    float texel = 1.0 / float(shadowMapResolution);
    float phi   = alShadowRotation();

    // --- Penumbra radius (distorted UV) ----------------------------------
    float radiusUV;
#ifdef AL_SHADOW_PCSS_ACTIVE
    // Blocker search: 4 Vogel taps on RAW depth (alShadowRawDepth -> shadowtex1
    // on the software path, shadowtex0 on the HW path). Average the depth of taps
    // that are closer to the light than the receiver.
    float searchUV = clamp(alWorldToShadowUV(AL_SHADOW_SEARCH_WORLD, localScale),
                           1.5 * texel, 24.0 * texel);
    float avgBlocker = 0.0;
    float blockers   = 0.0;
    for (int i = 0; i < 4; i++) {
        vec2 o = alVogel(i, 4, phi) * searchUV;
        float sd = alShadowRawDepth(uvz.xy + o);
        if (sd < refD) { avgBlocker += sd; blockers += 1.0; }
    }
    float minRadius = max(AL_SHADOW_MIN_PEN_TEXELS, AL_SHADOW_ACNE_FLOOR_TEXELS) * texel;
    if (blockers < 0.5) {
        // ROBUSTNESS: the coarse 4-tap search found no blocker. Do NOT early-return
        // "fully lit" — that is exactly what turned a single unreliable raw read into
        // ZERO SHADOWS everywhere on the old hardware path. Instead fall through with
        // the tightest penumbra and let the full SHADOW_SAMPLES-tap PCF below make the
        // actual lit/shadowed decision (a genuinely unoccluded point simply reads all
        // taps lit -> ~1.0, at no visual cost).
        radiusUV = minRadius;
    } else {
        avgBlocker /= blockers;

        // Penumbra from occluder distance: contact-hardening. depthDiff is in NDC
        // depth; * (2*shadowDistance) -> world metres along the light axis. The sun
        // angular radius (+ artistic softness) sets how fast it widens.
        float depthDiff = max(uvz.z - avgBlocker, 0.0);
        float penWorld  = depthDiff * (2.0 * shadowDistance)
                        * tan(AL_SUN_ANGULAR_RADIUS) * AL_SHADOW_SOFTNESS;
        // MAX in WORLD units (resolution-independent softness); MIN in texels (hides
        // sampling noise at the map's actual resolution).
        penWorld = min(penWorld, AL_SHADOW_MAX_PEN_WORLD);
        radiusUV = max(alWorldToShadowUV(penWorld, localScale), minRadius);
    }
#else
    // Non-PCSS (LOW profile) and the no-hardware-flag Mac fallback: a fixed
    // world-radius soft edge, shared PCF loop below. World-based (resolution-
    // independent), floored at one texel to hide sampling noise.
    float penWorld = min(AL_SHADOW_FIXED_PEN_WORLD, AL_SHADOW_MAX_PEN_WORLD);
    radiusUV = max(alWorldToShadowUV(penWorld, localScale),
                   AL_SHADOW_ACNE_FLOOR_TEXELS * texel);
#endif

    // --- Vogel-disc PCF (shared by all paths) ----------------------------
    float sum = 0.0;
    for (int i = 0; i < SHADOW_SAMPLES; i++) {
        vec2 o = alVogel(i, SHADOW_SAMPLES, phi) * radiusUV;
        sum += alShadowCompare(uvz.xy + o, refD);
    }
    return sum / float(SHADOW_SAMPLES);
}

#else  // SHADOWS off (and not the vsh sampler-free include)

#ifndef AL_SHADOW_VSH
float alShadowVisibility(vec3 playerPos, vec3 worldN, float NdotL) {
    return 1.0;
}
#endif

#endif // SHADOWS

#endif // AL_LIB_SHADOW
