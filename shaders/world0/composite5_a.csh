#version 460 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"

/*
 composite5_a (COMPUTE) — advanced-tier auto-exposure, stage 1 of 2: REDUCE.
 Phase 6, world0. Runs (with composite5_b) BEFORE composite5.fsh on the compute-
 capable path only; on macOS no .csh is ever loaded (compute unsupported).

 OptiFine/Iris runs a program's compute shaders in suffix order (…_a then _b)
 ahead of its fragment stage, so within a frame this ordering holds:
   _a: REDUCE last frame's accumulated histogram -> a robust average luminance,
       write it to the colortex5 scratch texel, then CLEAR the bins.
   _b: ACCUMULATE this frame's luminance into the freshly-cleared bins.
 The SSBO is persistent across frames, so the reduce reads a complete histogram
 (a one-frame lag — invisible, exposure adapts over seconds).

 Robustness: a plain deep-mip average is skewed by tiny bright/dark outliers (the
 sun disc, a torch, a cave mouth). A histogram lets us take a TRIMMED MEAN —
 discard the darkest AL_HISTO_LOW_CLIP and the brightest (1-AL_HISTO_HIGH_CLIP)
 of the population and average the middle band — so exposure tracks what the eye
 actually adapts to. The metered luminance lands in colortex5's scratch texel
 (.a at AL_HISTO_TEXEL); the portable composite5.fsh reads it there.

 VERIFICATION: syntax-validated by the CI compile gate (glslang, advanced target)
 only — no GPU in CI, maintainer on macOS — so on-device behaviour is unverified.
*/

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);   // a single reduce thread

#ifdef AL_ADVANCED_TIER
// Histogram SSBO — INTERNAL to the two compute stages (kept out of the #version
// 330 fragment pass, which can't declare SSBOs). Binding shared with _b.
layout(std430, binding = 0) buffer AlExposureHistogram {
    uint alHistoBins[AL_HISTO_BINS];
};

// Iris binds colorimgN -> colortexN; colortex5 is RGBA16F. We write ONLY the
// scratch texel's .a and preserve its rgb (AO-history bytes).
layout(rgba16f) uniform image2D colorimg5;

// Representative linear luminance for a bin (its centre), inverting _b's mapping.
float alBinToLum(int b) {
    float f    = (float(b) + 0.5) / float(AL_HISTO_BINS);
    float logL = mix(AL_HISTO_LOG_MIN, AL_HISTO_LOG_MAX, f);
    return exp2(logL);
}
#endif

void main() {
#ifdef AL_ADVANCED_TIER
    // Total population of last frame's histogram.
    uint total = 0u;
    for (int i = 0; i < AL_HISTO_BINS; i++) total += alHistoBins[i];

    float metered = AL_EXPOSURE_KEY;   // fallback for an empty histogram
    if (total > 0u) {
        float loCount = float(total) * AL_HISTO_LOW_CLIP;
        float hiCount = float(total) * AL_HISTO_HIGH_CLIP;
        float cum  = 0.0;
        float sumL = 0.0;
        float sumW = 0.0;
        for (int i = 0; i < AL_HISTO_BINS; i++) {
            float c0 = cum;
            float c1 = cum + float(alHistoBins[i]);
            cum = c1;
            // Portion of this bin inside the kept cumulative band [lo, hi].
            float lo = max(c0, loCount);
            float hi = min(c1, hiCount);
            float w  = max(hi - lo, 0.0);
            if (w > 0.0) {
                sumL += alBinToLum(i) * w;
                sumW += w;
            }
        }
        if (sumW > 0.0) metered = sumL / sumW;
    }
    metered = clamp(metered, 1.0e-4, 65000.0);

    // Deposit the metered luminance in the scratch texel's .a, keeping its rgb.
    ivec2 t    = AL_HISTO_TEXEL;
    vec4  prev = imageLoad(colorimg5, t);
    imageStore(colorimg5, t, vec4(prev.rgb, metered));

    // Clear the bins for THIS frame's accumulation in _b.
    for (int i = 0; i < AL_HISTO_BINS; i++) alHistoBins[i] = 0u;
#endif
}
