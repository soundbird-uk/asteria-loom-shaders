#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/bloom.glsl"

/*
 composite14 (fragment) — BLOOM combine (final pyramid level) + AUTO-EXPOSURE.

 Two jobs, one pass:

 (1) BLOOM COMBINE -> colortex0. Folds the LAST level of the dual-filter pyramid
     into the scene: U1 = L1 + tent(U2), reading tile L1 and the coarser
     accumulated tile U2 from the colortex9 atlas (built by composite4..13, layout
     + kernels in lib/bloom.glsl). U1 is therefore the full pyramid
     L1 + tent(L2 + tent(L3 + ... )); each tent is energy-preserving, so its
     energy ~ AL_BLOOM_LEVELS x one level — normalising by the level count gives an
     energy-preserving average magnitude, which is ADDED into the scene:
         out = scene + bloom * w,   bloom = U1 / AL_BLOOM_LEVELS,
                                    w    = BLOOM_STRENGTH * AL_BLOOM_ADD
     Additive (NOT a crossfade): bright emissives GAIN a soft glow and nothing is
     dimmed — the brief's "generous bloom / emissive spill". bloom is bounded, w
     is small, and AgX's soft highlight rolloff in final absorbs the added energy
     without clipping. Tuned so a night torch/glowstone halo brightens clearly
     (~2.1x) while a noon midtone shifts <2% (see settings.glsl AL_BLOOM_ADD).

 (2) AUTO-EXPOSURE (Mac path) -> colortex5.a at texel (0,0). Samples a deep mip of
     colortex0 (colortex0MipmapEnabled below) for the average scene luminance,
     derives a GENTLE exposure correction toward a key value, and smooths it.
     final reads colortex5.a(0,0) and multiplies it in before AgX. This is the
     SAME metering + adaptation that previously lived in composite5; it was moved
     here UNCHANGED when the single combine pass became the tail of the pyramid
     chain (composite5 is now a downsample pass). colortex0MipmapEnabled is a
     legal per-program `const bool` Iris directive.

     colortex5 carries the AO temporal history (r=AO, g=confidence, b=linZ) and
     MUST survive byte-perfect except for the single exposure texel. We
     texelFetch this pixel's exact stored value and re-emit rgb (and .a everywhere
     but (0,0)) UNCHANGED, writing the exposure ONLY at (0,0).

     KNOWN LIMITATION (documented, unchanged from the former composite5): the true
     previous exposure cannot be recovered here. composite1 (clouds, out of this
     agent's ownership) rewrites colortex5.a = 1.0 fullscreen every frame BEFORE
     this pass runs, so `texelFetch(colortex5,(0,0)).a` reads composite1's 1.0,
     not last frame's exposure. The loop is therefore a STABLE partial correction:
     the metered target is a low-frequency full-screen average (it changes slowly
     as the camera moves), so blending toward it from the neutral read each frame
     is flicker-free without a real integrator. A proper multi-frame integrator
     would need a persistent single-writer exposure slot — out of scope this phase.

 Combine gated by `#ifdef BLOOM`; the pass itself always runs (auto-exposure is
 needed even with bloom off). Sampler count: 3 (colortex0, colortex9, colortex5).
*/

const bool colortex0MipmapEnabled = true;   // deep mip = average scene luminance

uniform sampler2D colortex0;   // post-TAA (or post-fog) HDR scene
uniform sampler2D colortex9;   // bloom tile atlas (tile L1, tile U2)
uniform sampler2D colortex5;   // AO history (r=AO,g=conf,b=linZ) + exposure in .a

uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;       // seconds of the last frame (Iris/OptiFine)

in vec2 texcoord;

/* RENDERTARGETS: 0,5 */
layout(location = 0) out vec4 outColor;     // -> colortex0 (scene + bloom)
layout(location = 1) out vec4 outHistory;   // -> colortex5 (AO passthrough + exp)

void main() {
    vec3 scene = texture(colortex0, texcoord).rgb;

    // ---- (1) Bloom combine: last pyramid level U1 = L1 + tent(U2) ----------
    vec3 result = scene;
#ifdef BLOOM
#if DEBUG_VIEW == 0
    vec2 atlasTexel = 1.0 / vec2(viewWidth, viewHeight);

    // L1 (tile 1) at this pixel's screen position.
    vec3 l1 = alBloomValidate(
        texture(colortex9, alBloomToAtlas(1, texcoord, atlasTexel)).rgb);

    // tent(U2): U2 lives in tile 2 (source level 2, local texel = 2^2/screenRes).
    vec2 sLocal = AL_BLOOM_TENT_RADIUS * exp2(2.0) * atlasTexel;
    vec3 u2 = alBloomValidate(
        alBloomTentTile(colortex9, 2, texcoord, sLocal, atlasTexel));

    // Full pyramid result, normalised to an energy-preserving average magnitude.
    vec3 bloom = (l1 + u2) * (1.0 / float(AL_BLOOM_LEVELS));

    float w = max(BLOOM_STRENGTH * AL_BLOOM_ADD, 0.0);
    vec3 added = scene + bloom * w;
    // NaN guard — fall back to the untouched scene.
    bool okB = (added.r >= 0.0) && (added.g >= 0.0) && (added.b >= 0.0);
    result = okB ? added : scene;
#endif
#endif
    // Debug views (7/8 probes etc.) pass the scene through untouched above.
    outColor = vec4(max(result, vec3(0.0)), 1.0);

    // ---- (2) Auto-exposure metering + adaptation --------------------------
    // Deep-mip average luminance (whole-screen). LOD just below the 1x1 top.
    float maxLod = floor(log2(max(viewWidth, viewHeight)));
    vec3  avg    = textureLod(colortex0, vec2(0.5), max(maxLod - 1.0, 0.0)).rgb;
    float avgLum = alLuminance(max(avg, vec3(0.0)));
    // Reject NaN/garbage average -> neutral.
    avgLum = (avgLum >= 0.0 && avgLum < 65000.0) ? avgLum : AL_EXPOSURE_KEY;

    // Metered exposure to bring the average toward the key, clamped and then
    // pulled toward 1.0 by STRENGTH (subtle; asymmetric bounds protect nights).
    float metered = clamp(AL_EXPOSURE_KEY / max(avgLum, 1.0e-4),
                          AL_EXPOSURE_MIN, AL_EXPOSURE_MAX);
    float target  = mix(1.0, metered, AL_EXPOSURE_STRENGTH);

    // Previous exposure (see KNOWN LIMITATION). Range-validate [0.2,5.0] (NaN
    // fails the comparisons) else reset to 1.0.
    float prevExp = texelFetch(colortex5, ivec2(0, 0), 0).a;
    prevExp = (prevExp >= 0.2 && prevExp <= 5.0) ? prevExp : 1.0;

    // Smooth toward target. Frame-time based (tau ~ AL_EXPOSURE_TAU seconds),
    // floored so a stalled frameTime can't freeze adaptation; the moderate rate
    // keeps metering effective under the composite1 alpha clobber (see above).
    float ft   = (frameTime > 0.0 && frameTime < 1.0) ? frameTime : 0.016;
    float rate = clamp(1.0 - exp(-ft / AL_EXPOSURE_TAU), AL_EXPOSURE_ADAPT_MIN, 1.0);
    float expo = mix(prevExp, target, rate);
    expo = (expo >= 0.2 && expo <= 5.0) ? expo : 1.0;

    // ---- colortex5 passthrough (byte-exact) + exposure at (0,0) ------------
    ivec2 pxh  = ivec2(gl_FragCoord.xy);
    vec4  hist = texelFetch(colortex5, pxh, 0);   // exact stored AO-history texel
    float outA = (pxh.x == 0 && pxh.y == 0) ? expo : hist.a;
    outHistory = vec4(hist.rgb, outA);
}
