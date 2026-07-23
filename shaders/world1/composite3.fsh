#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
// lib/jitter.glsl OWNS viewWidth / viewHeight / frameCounter (used for the FXAA
// texel size + the temporal pass). The camera jitter itself is now a no-op there
// (0.4.4 — AA is FXAA + unjittered temporal). Do NOT redeclare viewWidth/Height.
#include "/lib/jitter.glsl"

/*
 composite3 (fragment) — TAA RESOLVE (Phase 4, contract §4).

 Runs AFTER composite2 (fog + underwater), so colortex0 is the fully composited
 HDR scene. This pass reprojects each pixel into last frame's resolved history
 (colortex8), rejects/ clamps it, blends, and writes both the anti-aliased scene
 (colortex0) and the new history (colortex8: rgb colour, a = blend confidence).
 The camera jitter that makes this work is applied per-vertex in every gbuffers
 vsh via lib/jitter.glsl (Halton 2,3, 8-frame).

 PIPELINE
   1. 3x3 CLOSEST-DEPTH velocity dilation — reproject the nearest neighbour so a
      foreground silhouette doesn't drag its motion vector across the background.
   2. REPROJECTION (lib/space.glsl previous-frame helpers + camera delta,
      depthtex0):
        - opaque pixels: reconstruct view pos -> player -> prev view -> prev
          screen; velocity = prevScreen - dilatedUV, applied to this pixel.
        - SKY pixels (depth == 1): ROTATION-ONLY reprojection (infinite distance,
          no camera-translation parallax) — the view ray is carried through the
          PREVIOUS camera orientation and reprojected, so sky/clouds get AA'd and
          stay stable. Clouds themselves DRIFT; that motion is absorbed by the
          neighbourhood clamp (step 4), not by a velocity — confidence keeps them
          converged without smear.
   3. HISTORY READ — NaN-LAW: colortex8 is clear=false, so its first-frame
      contents are UNDEFINED on Apple GL. Every acceptance gate is a range test
      (NOT a clamp) that NaN cannot pass, so poison falls through to "current
      only" and self-heals; accepted values are re-sanitised before emit. This is
      the same discipline as deferred.fsh's AO history.
   4. NEIGHBOURHOOD CLAMP — build a 3x3 min/max colour box in YCoCg and clip the
      history into it (simple variance-free box clamp; adequate at this scope per
      contract). This is the primary ghosting control for motion the velocity
      missed (moving clouds, shading changes, disocclusion residue).
   5. DISOCCLUSION — reset confidence + drop to current on: off-screen reprojection;
      depth mismatch > AL_TAA_DEPTH_REJECT (5%) relative. There is no
      previous-depth buffer, so the CURRENT depth at the reprojected UV is used as
      a proxy for the previous depth (valid for a near-static scene; the clamp
      handles the residual). Sky pixels skip the depth test (both far).
   6. BLEND — history weight = maxBlend * confidence, confidence ramps
      +AL_TAA_CONF_STEP per accepted frame to AL_TAA_CONF_MAX. HAND pixels
      (matID HAND in colortex3) use a shorter ceiling (AL_TAA_HAND_MAX_BLEND) so a
      fast weapon swing does not ghost.
   7. HDR FLICKER CONTROL — the blend is done in REINHARD-compressed space:
        c'   = c / (1 + luma(c))            (forward, per input)
        mix' = mix(cur', hist', blend)
        out  = mix' / (1 - luma(mix'))      (inverse, exact for a single colour)
      Compressing before the mix stops bright transients (specular sparkle,
      emissive fireflies) from dominating and pumping; the inverse restores HDR
      range. Documented formulation; the (1 - luma) denominator is floored.

 JITTER INTERACTION (contract §4 note): the G-buffer positions ARE jittered, but
 deferred/AO/fog reconstruct with Iris' UNJITTERED gbufferProjection(Inverse)
 against the jittered depth — an accepted sub-pixel reconstruction error that TAA
 itself resolves. This pass likewise reconstructs with the unjittered matrices;
 no per-pass un-jitter is attempted this phase.

 GATING: this program is NOT gated by program.enabled — it always runs and, when
 TAA is off (POTATO), compiles to a cheap passthrough (still writing both targets
 so the buffer chain shape is stable and the bloom agent's post-TAA colortex0
 read is always satisfied).

 Sampler count: 4 — colortex0, colortex3, colortex8, depthtex0 (<= 7 budget).
 lib/space.glsl adds only matrix/vec uniforms, no samplers.
*/

uniform sampler2D colortex0;   // current HDR scene (post fog / underwater)
uniform sampler2D colortex3;   // matID .r / flags .g  (hand detection)
uniform sampler2D colortex8;   // TAA history: rgb colour, a = confidence
uniform sampler2D depthtex0;

// viewWidth / viewHeight / frameCounter come from lib/jitter.glsl (do NOT
// redeclare — duplicate-uniform error).

in vec2 texcoord;

/* RENDERTARGETS: 0,8 */
layout(location = 0) out vec4 outColor;    // -> colortex0 (resolved scene)
layout(location = 1) out vec4 outHistory;  // -> colortex8 (colour + confidence)

// --- Range-validation ceiling (NaN-proof; shared with the HDR history read) ---
#define AL_TAA_HDR_MAX 65000.0

bool alFiniteRGB(vec3 c) {
    return (c.r >= 0.0 && c.r <= AL_TAA_HDR_MAX &&
            c.g >= 0.0 && c.g <= AL_TAA_HDR_MAX &&
            c.b >= 0.0 && c.b <= AL_TAA_HDR_MAX);
}
vec3 alSanitizeRGB(vec3 c) { return alFiniteRGB(c) ? c : vec3(0.0); }

// RGB <-> YCoCg (pure GLSL 3.30 math). Y = luma, Co/Cg = chroma axes.
vec3 alRGBToYCoCg(vec3 c) {
    return vec3( 0.25 * c.r + 0.5 * c.g + 0.25 * c.b,
                 0.5  * c.r            - 0.5  * c.b,
                -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
}
vec3 alYCoCgToRGB(vec3 y) {
    float t = y.x - y.z;
    return vec3(t + y.y, y.x + y.z, t - y.y);
}

// Reinhard luma compression for HDR-aware temporal blending (see header §7).
vec3 alReinhard(vec3 c)    { return c / (1.0 + alLuminance(c)); }
vec3 alReinhardInv(vec3 c) { return c / max(1.0 - alLuminance(c), 1e-4); }

void main() {
    vec3 current = alSanitizeRGB(texture(colortex0, texcoord).rgb);

#if DEBUG_VIEW != 0
    // Debug views (raw G-buffer channels + the deferred1 probes 7/8) must show
    // EXACTLY what the upstream pass wrote — never a TAA round-trip (Reinhard
    // compress/expand + neighbourhood clamp + history blend), which would violate
    // the settings.glsl claim that the probes are raw. Pass colortex0 through
    // untouched. Still write a VALID, non-stale history (current frame,
    // confidence 0) so re-enabling normal mode doesn't inherit history captured
    // while debug was active.
    outColor   = vec4(texture(colortex0, texcoord).rgb, 1.0);
    outHistory = vec4(current, 0.0);
    return;
#endif

#if AA_MODE == 0
    // AA off: cheap passthrough. Still writes both targets (RENDERTARGETS 0,8) so
    // the buffer chain shape is stable.
    outColor   = vec4(current, 1.0);
    outHistory = vec4(current, 0.0);
    return;
#else
    // Temporal resolve runs for BOTH FXAA and TAA modes. In FXAA mode there is NO
    // jitter, so this is a pure temporal ANTI-FLICKER (reproject + neighbourhood
    // clamp + blend) that quiets specular / emissive / edge shimmer; FXAA then
    // smooths edges spatially in final.fsh. In TAA mode the camera IS jittered, so
    // the same resolve additionally accumulates sub-pixel detail — the reprojection
    // is un-jittered so a world-static point reconstructs to a stable position.
    vec2  texel = 1.0 / vec2(viewWidth, viewHeight);
    float depth = texture(depthtex0, texcoord).r;

#ifdef AL_TAA
    vec2 jitterUV = alHaltonOffset(frameCounter % 8) / vec2(viewWidth, viewHeight);
#else
    vec2 jitterUV = vec2(0.0);   // FXAA / anti-flicker: reproject from pixel centre
#endif

    // --- 1. 3x3 closest-depth dilation ------------------------------------
    vec2  closestUV    = texcoord;
    float closestDepth = depth;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2  uv = texcoord + vec2(float(x), float(y)) * texel;
            float d  = texture(depthtex0, uv).r;
            if (d < closestDepth) { closestDepth = d; closestUV = uv; }
        }
    }

    // --- 2. Reproject -> history UV ---------------------------------------
    bool  isSky   = (closestDepth >= 1.0);
    vec2  histUV;
    float expectZ = -1.0;   // prev-frame eye depth of this surface (<0 => sky/none)

    if (isSky) {
        // Reconstruct the view ray from the UN-jittered pixel centre so the sky/
        // cloud silhouette reprojects stably (rotation-only, infinite distance).
        vec3 viewDir     = normalize(alScreenToView(texcoord - jitterUV, 1.0));
        vec3 worldDir    = mat3(gbufferModelViewInverse) * viewDir;
        vec3 prevViewDir = mat3(gbufferPreviousModelView) * worldDir;
        vec4 prevClip    = gbufferPreviousProjection * vec4(prevViewDir, 0.0);
        if (prevClip.w <= 0.0) histUV = vec2(-1.0);   // behind camera -> reject
        else                   histUV = (prevClip.xy / prevClip.w) * 0.5 + 0.5;
    } else {
        // Reconstruct the closest surface from its UN-jittered screen position;
        // the jitter cancels in histUV = texcoord + (prevScr - closestUV).
        vec3 viewPos   = alScreenToView(closestUV - jitterUV, closestDepth);
        vec3 playerPos = alViewToPlayer(viewPos);
        vec3 prevView  = alPlayerToPrevView(playerPos);
        vec3 prevScr   = alPrevViewToScreen(prevView);
        vec2 velocity  = prevScr.xy - closestUV;    // motion at the closest pixel
        histUV  = texcoord + velocity;              // applied to THIS pixel
        expectZ = alLinearEyeDepth(prevView);
    }

    // --- 3/4. Neighbourhood statistics (YCoCg) -> VARIANCE clip box --------
    // Hard min/max clamping makes distant high-contrast edges SWIM: the box
    // extremes swing frame-to-frame as the jitter flips which side of an edge each
    // sample lands on, so the clamped history jumps with them. A statistical
    // variance box (mean +/- gamma*sigma) is far steadier while still catching
    // ghosts; intersecting it with the true min/max keeps it from overshooting the
    // real neighbourhood. Together with the un-jitter above this is what stills the
    // far terrain/mountain/horizon crawl the brief calls out.
    vec3 curY = alRGBToYCoCg(current);
    vec3 m1 = vec3(0.0), m2 = vec3(0.0);
    vec3 nmin = curY, nmax = curY;
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec3 n = (x == 0 && y == 0) ? current : alSanitizeRGB(
                texture(colortex0, texcoord + vec2(float(x), float(y)) * texel).rgb);
            vec3 ny = alRGBToYCoCg(n);
            m1  += ny;
            m2  += ny * ny;
            nmin = min(nmin, ny);
            nmax = max(nmax, ny);
        }
    }
    vec3 mean   = m1 / 9.0;
    vec3 sigma  = sqrt(max(m2 / 9.0 - mean * mean, vec3(0.0)));
    vec3 boxMin = max(nmin, mean - AL_TAA_CLIP_GAMMA * sigma);
    vec3 boxMax = min(nmax, mean + AL_TAA_CLIP_GAMMA * sigma);

    // --- 5/6. Hand-aware blend ceiling ------------------------------------
    int  matID  = alDecodeMatID(texture(colortex3, texcoord).r);
    // Hand AND the block-selection outline (BASIC) use the short blend ceiling so
    // a fast weapon swing / a moving outline re-converges immediately (no ghost).
    // The base ceiling is lower in FXAA (no-jitter anti-flicker) mode so it quiets
    // shimmer without smearing moving foliage/entities.
#ifdef AL_TAA
    float baseBlend = AL_TAA_MAX_BLEND;
#else
    float baseBlend = AL_TAA_FXAA_MAX_BLEND;
#endif
    bool lowBlend = (matID == AL_MATID_HAND) || (matID == AL_MATID_BASIC);
    float maxBlend = lowBlend ? AL_TAA_HAND_MAX_BLEND : baseBlend;

    // --- Sample + validate history (NaN-law) ------------------------------
    vec3  resolved = current;
    float conf     = AL_TAA_CONF_STEP;   // fresh (no accepted history yet)

    bool onScreen = (histUV.x > 0.0 && histUV.x < 1.0 &&
                     histUV.y > 0.0 && histUV.y < 1.0);
    if (onScreen) {
        vec4 hist      = texture(colortex8, histUV);
        bool histValid = alFiniteRGB(hist.rgb) && (hist.a >= 0.0) && (hist.a <= 1.0);

        // Disocclusion via depth proxy (see header §5).
        bool depthOK = true;
        if (!isSky) {
            float dHist = texture(depthtex0, histUV).r;
            if (dHist >= 1.0) {
                depthOK = false;                    // reprojected onto sky
            } else {
                float actualZ = alLinearEyeDepth(alScreenToView(histUV, dHist));
                bool  zRangeOK = (expectZ > 0.0) && (expectZ < AL_TAA_HDR_MAX) &&
                                 (actualZ > 0.0) && (actualZ < AL_TAA_HDR_MAX);
                float relErr   = abs(expectZ - actualZ) / max(expectZ, 0.001);
                depthOK = zRangeOK && (relErr < AL_TAA_DEPTH_REJECT);
            }
        }

        if (histValid && depthOK) {
            // Clip history into the current neighbourhood box (YCoCg -> RGB).
            vec3 histY   = clamp(alRGBToYCoCg(hist.rgb), boxMin, boxMax);
            vec3 histRGB = alSanitizeRGB(alYCoCgToRGB(histY));

            float prevConf = clamp(hist.a, 0.0, AL_TAA_CONF_MAX);
            float blend    = maxBlend * prevConf;   // history weight up to maxBlend

            vec3 mixT = mix(alReinhard(current), alReinhard(histRGB), blend);
            resolved  = alReinhardInv(mixT);
            conf      = min(prevConf + AL_TAA_CONF_STEP, AL_TAA_CONF_MAX);
        }
    }

    // --- Emit (all finite; NaN cannot survive the range tests) ------------
    resolved = alSanitizeRGB(resolved);
    conf     = (conf >= 0.0 && conf <= AL_TAA_CONF_MAX) ? conf : AL_TAA_CONF_STEP;
    outColor   = vec4(resolved, 1.0);
    outHistory = vec4(resolved, conf);
    return;
#endif
}
