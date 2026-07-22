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
// shadowHardwareFiltering = true (shaders.properties). Verified against Iris
// ShaderDoc (iris-features.md, "Separate Hardware Shadow Samplers"):
//   * WITH the SEPARATE_HARDWARE_SAMPLERS feature flag, plain shadowtex0/1
//     "no longer function as hardware samplers" -> shadowtex0 gives RAW depth
//     for the PCSS blocker search, and shadowtex1HW is a sampler2DShadow that
//     does hardware PCF for the filter taps. Full PCSS on this path.
//   * WITHOUT the flag, hardware filtering turns plain shadowtex1 INTO a
//     compare (sampler2DShadow) sampler, so a raw `.r` read is invalid and no
//     blocker search is possible. We compare-sample shadowtex1 and fall back
//     to a fixed-radius Vogel PCF (no PCSS). This is the documented worst case
//     and it still gives soft, distorted shadows. The macOS GL4.1 compile
//     target exercises exactly this branch.
#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
uniform sampler2D       shadowtex0;    // raw depth of everything (blocker search)
uniform sampler2DShadow shadowtex1HW;  // hardware-PCF opaque depth (filter taps)
#else
uniform sampler2DShadow shadowtex1;    // HWF=true makes this a compare sampler
#endif

uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform int  frameCounter;

// PCSS is only possible where a raw depth read exists (blocker search).
#if defined SHADOW_PCSS && defined IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
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
    // maximally-spread temporal offset.
    float r2 = fract(float(frameCounter) * 0.75487766624669276);
    return (nz.x + r2) * AL_TAU;
}

// Compare-sample the opaque shadow depth with hardware PCF. Returns fraction
// (0 = fully occluded .. 1 = fully lit) at `uv` against reference depth `refD`.
float alShadowCompare(vec2 uv, float refD) {
#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS
    return texture(shadowtex1HW, vec3(uv, refD));
#else
    return texture(shadowtex1,   vec3(uv, refD));
#endif
}

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

    // Slope-scaled depth bias, itself scaled by the local (coarser-at-edge)
    // texel size. Tiny near camera (crisp), larger near the map edge.
    float depthBias = (AL_SHADOW_BIAS + AL_SHADOW_SLOPE_BIAS * (1.0 - NdotL)) * localScale;
    float refD  = uvz.z - depthBias;

    float texel = 1.0 / float(shadowMapResolution);
    float phi   = alShadowRotation();

    // --- Penumbra radius (distorted UV) ----------------------------------
    float radiusUV;
#ifdef AL_SHADOW_PCSS_ACTIVE
    // Blocker search: 4 Vogel taps on RAW depth (shadowtex0). Average the depth
    // of taps that are closer to the light than the receiver.
    float searchUV = clamp(alWorldToShadowUV(AL_SHADOW_SEARCH_WORLD, localScale),
                           1.5 * texel, 24.0 * texel);
    float avgBlocker = 0.0;
    float blockers   = 0.0;
    for (int i = 0; i < 4; i++) {
        vec2 o = alVogel(i, 4, phi) * searchUV;
        float sd = texture(shadowtex0, uvz.xy + o).r;
        if (sd < refD) { avgBlocker += sd; blockers += 1.0; }
    }
    if (blockers < 0.5) return 1.0;             // nothing occluding -> fully lit
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
    radiusUV = max(alWorldToShadowUV(penWorld, localScale),
                   AL_SHADOW_MIN_PEN_TEXELS * texel);
#else
    // Non-PCSS (LOW profile) and the no-hardware-flag Mac fallback: a fixed
    // world-radius soft edge, shared PCF loop below. World-based (resolution-
    // independent), floored at one texel to hide sampling noise.
    float penWorld = min(AL_SHADOW_FIXED_PEN_WORLD, AL_SHADOW_MAX_PEN_WORLD);
    radiusUV = max(alWorldToShadowUV(penWorld, localScale), 1.0 * texel);
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
