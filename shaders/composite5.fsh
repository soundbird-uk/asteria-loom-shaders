#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/bloom.glsl"

/*
 composite5 (fragment) — BLOOM combine + AUTO-EXPOSURE metering (phase4 §5/§6).

 Two jobs, one pass:

 (1) BLOOM COMBINE -> colortex0. Reads the 6 tiles composite4 wrote into the
     colortex9 atlas, sums them with per-level weights (lib/bloom.glsl —
     normalised to 1.0, gently favouring the wide levels for the pack's soft,
     dreamy halo), and mixes into the scene with an ENERGY-CONSERVING lerp:
         out = mix(scene, bloomSum, w),  w = BLOOM_STRENGTH * AL_BLOOM_MIX
     Because bloomSum is a weighted AVERAGE of the level blurs (not a sum of raw
     energy) and w is small, noon barely changes while night torches/glowstone —
     which sit far above 1.0 in the HDR scene — spread a clear glow into the dark
     surroundings (the emissive spill the brief asks for). This is a single-pass
     gather, NOT a strict tent-cascade upsample; the deviation is intentional and
     documented in lib/bloom.glsl (the tiles are already dual-filter blurred, so
     a bilinear gather reads identically for a fraction of the passes).

 (2) AUTO-EXPOSURE (Mac path) -> colortex5.a at texel (0,0). Samples a deep mip
     of colortex0 (colortex0MipmapEnabled below) for the average scene
     luminance, derives a GENTLE exposure correction toward a key value, and
     smooths it. final reads colortex5.a(0,0) and multiplies it in before AgX.

     colortex5 carries the AO temporal history (r=AO, g=confidence, b=linZ) and
     MUST survive byte-perfect except for the single exposure texel. We
     texelFetch this pixel's exact stored value and re-emit rgb (and .a
     everywhere but (0,0)) UNCHANGED, writing the exposure ONLY at (0,0).

     KNOWN LIMITATION (documented, in-ownership): the true previous exposure
     cannot be recovered here. composite1 (clouds, out of this agent's
     ownership) rewrites colortex5.a = 1.0 fullscreen every frame BEFORE
     composite5 runs, so `texelFetch(colortex5,(0,0)).a` reads composite1's 1.0,
     not last frame's exposure. The loop is therefore written as a STABLE
     partial correction: the metered target is a low-frequency full-screen
     average (it changes slowly as the camera moves), so blending toward it from
     the neutral read each frame is flicker-free without a real integrator. The
     smoothing constant is kept moderate so metering still visibly applies. A
     proper multi-frame integrator would need a persistent single-writer
     exposure slot (e.g. moving composite1's AO-alpha write, or a dedicated
     clear=false buffer) — out of scope this phase. The exposure is also kept
     deliberately gentle + asymmetric (see settings.glsl AL_EXPOSURE_*) so it
     never undoes the field-approved dark nights.

 Sampler count: 3 (colortex0, colortex9, colortex5). Budget <=16.
*/

const bool colortex0MipmapEnabled = true;   // deep mip = average scene luminance

uniform sampler2D colortex0;   // post-TAA (or post-fog) HDR scene
uniform sampler2D colortex9;   // bloom tile atlas
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

    // ---- (1) Bloom combine ------------------------------------------------
    vec3 result = scene;
#ifdef BLOOM
#if DEBUG_VIEW == 0
    vec2 atlasTexel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 bloomSum = vec3(0.0);
    for (int L = 1; L <= AL_BLOOM_LEVELS; L++) {
        vec2 uv = alBloomToAtlas(L, texcoord, atlasTexel);
        vec3 b  = alBloomValidate(texture(colortex9, uv).rgb);
        bloomSum += alBloomLevelWeight(L) * b;
    }
    float w = alSaturate(BLOOM_STRENGTH * AL_BLOOM_MIX);
    vec3 mixed = mix(scene, bloomSum, w);
    // NaN guard — fall back to the untouched scene.
    bool okB = (mixed.r >= 0.0) && (mixed.g >= 0.0) && (mixed.b >= 0.0);
    result = okB ? mixed : scene;
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
    ivec2 px   = ivec2(gl_FragCoord.xy);
    vec4  hist = texelFetch(colortex5, px, 0);   // exact stored AO-history texel
    float outA = (px.x == 0 && px.y == 0) ? expo : hist.a;
    outHistory = vec4(hist.rgb, outA);
}
