#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/shadow.glsl"
#include "/lib/contact.glsl"
#include "/lib/lighting.glsl"

/*
 deferred1 (fragment) — the main opaque shading pass.

 (Phase 1's `deferred` lighting pass, renamed to deferred1 in Phase 2: the
 `deferred` slot now runs the GTAO pass ahead of this one. The shadow/lighting
 logic is unchanged; the only addition here is consuming the AO term from
 colortex4.)

 Reads the G-buffer, reconstructs world position from depth, evaluates the
 shared lighting model, and writes linear HDR back to colortex0.
 Sky pixels (depth == 1.0) pass the sky colour (already in colortex0 from the
 skybasic/skytextured passes) straight through untouched.

 NOTE: gbufferProjectionInverse / gbufferModelViewInverse are declared in
 lib/space.glsl (included above) — do NOT redeclare them here.

 AO: colortex4.r (1 = unoccluded) is read ONLY behind `#ifdef AO`. The AO pass
 (deferred) is dispatched only when AO is on; with AO off, colortex4 is a
 cleared (0,0) buffer whose .r would BLACKEN the ambient terms — hence the
 compile-time gate with a 1.0 fallback, never a runtime read of cleared data.

 Sampler count (max over branches):
   colortex0,1,2,3 + depthtex0                                   = 5
   + colortex4 (AO)                                              = 1  (AO on)
   + shadow samplers via lib/shadow.glsl (SHADOWS):
       default software path : shadowtex1 (raw) + noisetex       = 2  -> 8 total
       experimental AL_SHADOW_HW : shadowtex0 + shadowtex1HW + noisetex = 3 -> 9 total
   contact shadows (CONTACT_SHADOWS) reuse depthtex0/noisetex (no new sampler).
 Well within the 16-sampler Mac limit and the contract's <=14 budget.
*/

uniform sampler2D colortex0;   // sky / scene HDR
uniform sampler2D colortex1;   // albedo
uniform sampler2D colortex2;   // normal + lightmap
uniform sampler2D colortex3;   // matID + flags
#ifdef AO
uniform sampler2D colortex4;   // AO .r (1 = unoccluded), confidence .g
#endif
uniform sampler2D depthtex0;

uniform vec3 sunPosition;          // view space
uniform vec3 shadowLightPosition;  // view space, toward dominant light

// Held-item light emission (Iris): the light value 0..15 of the item in the main
// hand / off hand. Drives the held point light so a carried torch illuminates the
// surroundings. Declared nowhere else here -> collision-free.
uniform int heldBlockLightValue;
uniform int heldBlockLightValue2;

in vec2 texcoord;

#if defined(AO) && defined(AL_AO_DENOISE)
// Depth+normal-aware bilateral denoise of the GTAO buffer, evaluated once at
// read time. GTAO leaves per-pixel grain (slice/step jitter) that temporal
// accumulation cannot fully remove because reprojection error at distance
// rejects history and falls back to the raw, noisy current frame. A spatial
// bilateral blur is deterministic — no motion vectors, no history, so it can
// never flicker or jitter with the camera — and edge-stopped on depth AND
// normal so it smooths flat surfaces without bleeding across creases/corners
// (which would erase the very contact darkening AO exists to draw).
float alDenoiseAO(vec2 uv, float centerDepth, vec3 centerN) {
    // A sky/background pixel (or a poisoned NaN sample) contributes no AO and
    // must not drag the kernel — bail to fully-lit for the degenerate center.
    if (centerDepth >= 1.0) return 1.0;
    float centerLin = alLinearEyeDepth(alScreenToView(uv, centerDepth));
    vec2  texel     = 1.0 / vec2(textureSize(colortex4, 0));

    float sum = 0.0;
    float wsum = 0.0;
    const float sig2 = 2.0 * (AL_AO_DENOISE_SIGMA) * (AL_AO_DENOISE_SIGMA);
    for (int y = -AL_AO_DENOISE_RADIUS; y <= AL_AO_DENOISE_RADIUS; ++y) {
        for (int x = -AL_AO_DENOISE_RADIUS; x <= AL_AO_DENOISE_RADIUS; ++x) {
            vec2  off = vec2(float(x), float(y));
            vec2  suv = uv + off * texel;
            // Skip taps that fell off-screen (clamp would fold the edge in).
            if (suv.x < 0.0 || suv.x > 1.0 || suv.y < 0.0 || suv.y > 1.0) continue;

            float a = texture(colortex4, suv).r;
            if (!(a >= 0.0 && a <= 1.0)) continue;         // reject NaN/garbage

            float sd = texture(depthtex0, suv).r;
            if (sd >= 1.0) continue;                        // sky neighbour
            float sLin = alLinearEyeDepth(alScreenToView(suv, sd));
            float dz   = abs(sLin - centerLin) / max(centerLin, 1e-4);
            float wDepth = exp(-(dz * dz) / (AL_AO_DENOISE_DEPTHK * AL_AO_DENOISE_DEPTHK));

            vec3  sN = alDecodeNormal(texture(colortex2, suv).rg);
            if (dot(sN, centerN) < AL_AO_DENOISE_NORMALK) continue;  // across a crease

            float r2 = off.x * off.x + off.y * off.y;
            float wSpace = exp(-r2 / sig2);

            float w = wSpace * wDepth;
            sum  += a * w;
            wsum += w;
        }
    }
    return (wsum > 1e-5) ? (sum / wsum) : 1.0;
}
#endif

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    float depth = texture(depthtex0, texcoord).r;

#if DEBUG_VIEW == 7
    // Pipeline probe A (bypasses ALL lighting): raw fullscreen interpolants +
    // this pass's own depth sample. Healthy = a smooth red(x)/green(y) screen
    // gradient with scene distance in blue. A flat/constant colour means
    // deferred1's texcoord interpolant or depth read collapsed (would explain a
    // uniform wash). composite/composite1 pass this straight through in debug.
    outColor = vec4(texcoord.x, texcoord.y, depth, 1.0);
    return;
#elif DEBUG_VIEW == 8
    // Pipeline probe B (bypasses ALL lighting): which branch each pixel takes.
    // Healthy = GREEN world, RED sky. If geometry shows RED, the sky branch
    // (depth >= 1.0) is being wrongly taken for solid pixels (a uniform sky wash
    // would then originate HERE); if geometry is GREEN, deferred1 is fine and any
    // wash is produced by a later fullscreen pass (fog/clouds/final).
    outColor = (depth >= 1.0) ? vec4(1.0, 0.0, 0.0, 1.0) : vec4(0.0, 1.0, 0.0, 1.0);
    return;
#endif

    // Sky: pass through whatever the sky passes already wrote.
    if (depth >= 1.0) {
        outColor = texture(colortex0, texcoord);
        return;
    }

    // --- Decode G-buffer --------------------------------------------------
    vec3  albedoSrgb = texture(colortex1, texcoord).rgb;
    vec3  albedoLin  = alSrgbToLinear(albedoSrgb);

    vec4  nl = texture(colortex2, texcoord);
    vec3  N  = alDecodeNormal(nl.rg);
    vec2  lm = nl.ba;                       // block, sky

    int matID = alDecodeMatID(texture(colortex3, texcoord).r);

    // Untextured primitives (selection outline, hitboxes, leads) must NOT be
    // sun/ambient shaded — pass their stored colour straight through.
    if (matID == AL_MATID_BASIC) {
        outColor = vec4(albedoLin, 1.0);
        return;
    }

    // --- Reconstruct position + light directions --------------------------
    vec3 viewPos   = alScreenToView(texcoord, depth);
    vec3 playerPos = alViewToPlayer(viewPos);

    vec3 wLightDir = normalize(alViewDirToWorld(shadowLightPosition));
    vec3 wSunDir   = normalize(alViewDirToWorld(sunPosition));
    float dayFactor = alDayFactor(wSunDir);

    // --- Shadow + shade ---------------------------------------------------
    float NdotL = max(dot(N, wLightDir), 0.0);
    // The hand is drawn with a separate (near) projection, so reconstructing
    // its world position with gbufferProjectionInverse is wrong and makes it
    // self-shadow flicker. Phase 1: skip shadowing hand pixels entirely.
    // (Proper fix later: a dedicated hand depth/projection path.)
    float shadowVis = (matID == AL_MATID_HAND)
                    ? 1.0
                    : alShadowVisibility(playerPos, N, NdotL);

    // Screen-space contact shadows multiply the shadow term for fine detail the
    // shadow map is too coarse to resolve. Hand exempt (its near projection makes
    // view reconstruction here invalid), same as the shadow-map path.
#ifdef CONTACT_SHADOWS
    // Distance-faded (0.4.4b): the screen-space march becomes coarse far away and
    // its dithered taps read as GRAIN / false distant shadows, so fade it out past
    // AL_CONTACT_MAX_DIST — contact shadows only matter for near contact detail.
    if (matID != AL_MATID_HAND && NdotL > 0.0) {
        float csFade = alSaturate(1.0 - length(viewPos) / AL_CONTACT_MAX_DIST);
        if (csFade > 0.0) {
            vec3  viewLightDir = normalize(shadowLightPosition);
            float dither = texture(noisetex, gl_FragCoord.xy / 256.0).x;
            float cs = alContactShadow(depthtex0, viewPos, viewLightDir, dither);
            shadowVis *= mix(1.0, cs, csFade);
        }
    }
#endif

    // Ambient occlusion: darkens ONLY the indirect terms (sky ambient, night
    // floor, blocklight, bounce) — never the direct sun/moon. AO_STRENGTH scales
    // the effect via pow (>1 deepens crevices, <1 softens). Gated at compile
    // time: with AO off, colortex4 is cleared and must not be read.
    float ao = 1.0;
#ifdef AO
    // Range-test the AO read (NaN fails the comparison and falls back to 1.0 =
    // fully lit, so a poisoned history frame can never blacken the scene) before
    // the pow — pow(NaN,..) would propagate NaN through all indirect light.
#ifdef AL_AO_DENOISE
    // Spatial bilateral denoise (depth+normal edge-stopped). Deterministic:
    // removes GTAO grain without the distance jitter that temporal reprojection
    // introduces on its own.
    float aoRaw = alDenoiseAO(texcoord, depth, N);
#else
    float aoRaw = texture(colortex4, texcoord).r;
#endif
    aoRaw = (aoRaw >= 0.0 && aoRaw <= 1.0) ? aoRaw : 1.0;
    ao = pow(aoRaw, AO_STRENGTH);
#endif

    // worldPos (feet + camera) drives the cloud-shadow factor inside the lib.
    vec3 worldPos = playerPos + cameraPosition;
    vec3 color = alLightPhase1(albedoLin, N, lm, shadowVis, wLightDir, wSunDir,
                               worldPos, dayFactor, ao);

    // Emissive light sources self-illuminate from their OWN texture colour, so a
    // redstone torch glows red, a torch orange, glowstone yellow, lava orange.
    // The HDR add blooms in composite4/5, spreading that colour as a halo onto the
    // surroundings (screen-space stand-in for coloured block light). Modulated by
    // the block lightmap so a redstone torch that has been turned OFF (lightmap
    // drops) stops glowing.
    if (matID == AL_MATID_EMISSIVE) {
        // Only the actually-bright emitting texels glow — a lantern's dark metal
        // frame (low luminance) must NOT emit, or the black parts light up grey.
        float emitMask = smoothstep(0.22, 0.55, alLuminance(albedoLin));
        color += albedoLin * (AL_EMISSIVE_STRENGTH * emitMask * (0.45 + 0.55 * lm.x));
    }

    // Held light: a warm point light around the camera from the held item's light
    // value, so carrying a torch/lantern/glowstone actually illuminates nearby
    // surfaces (main hand OR off hand). Distance-attenuated, facing-weighted, and
    // unshadowed (a local carried light). playerPos is camera-relative here.
    float heldLevel = float(max(heldBlockLightValue, heldBlockLightValue2)) / 15.0;
    if (heldLevel > 0.0) {
        float reach = mix(3.0, 15.0, heldLevel);
        float atten = alSaturate(1.0 - length(playerPos) / reach);
        atten *= atten;
        vec3  toCam = normalize(-playerPos);
        float facing = max(dot(N, toCam), 0.0) * 0.75 + 0.25;
        color += albedoLin * (AL_TORCH_TINT * (heldLevel * atten * facing * AL_HELD_LIGHT));
    }

    outColor = vec4(color, 1.0);
}
