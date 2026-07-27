#ifndef AL_LIB_ADVANCED_EXPOSURE_HISTOGRAM
#define AL_LIB_ADVANCED_EXPOSURE_HISTOGRAM

#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/advanced/settings_advanced.glsl"

/*
============================================================================
 lib/advanced/exposure_histogram.glsl — ADVANCED-TIER auto-exposure METERING
----------------------------------------------------------------------------
 The body of each world folder's final.csh (the `final` pass's COMPUTE stage,
 which Iris runs before that pass's fragment and therefore after every
 composite). It lives in a shared include rather than being copy-pasted into
 three world folders for the same reason the overlay appends shaders.properties
 instead of replacing it: three copies of a shader drift, and drift here is
 invisible — the End would silently meter differently from the Overworld and
 nobody would know why the Nether "looks off".

 WHAT THIS REPLACES
 ------------------
 composite14.fsh (the Mac path, still shipped and still correct) meters by
 sampling a deep MIP of colortex0 — a plain arithmetic MEAN of the frame. A mean
 is the wrong statistic for exposure. It is dominated by outliers, and Minecraft
 frames are nothing BUT outliers: a sliver of bright sky at the top of a forest
 view, one torch in an otherwise black cave, the sun disc, a lava lake at the
 edge of frame. Any of them drags the metered average by a stop or more, so the
 exposure breathes as the player turns, and the thing that moved it is precisely
 the part of the image nobody is looking at.

 This pass meters the same signal with a LUMINANCE HISTOGRAM instead: bin
 log2(luminance) over stratified samples of the whole frame, throw away the
 darkest AL_EXPO_TRIM_DARK and brightest AL_EXPO_TRIM_BRIGHT of the sample
 population, and take the weighted mean of what is left. That is a trimmed mean
 in log space — a robust central-tendency estimator. Outliers can no longer move
 it: the sun disc lands in the top bin and is discarded, the black cave ceiling
 lands in the bottom bin and is discarded, and the exposure tracks the
 luminance of the MAJORITY of the frame, which is what the player is looking at.
 Log space matters too — perceived brightness is logarithmic, so the mean of
 log-luminance is a geometric mean, which is stable under the huge dynamic range
 an HDR scene spans, unlike a linear mean.

 WHAT THIS DOES *NOT* CHANGE
 ---------------------------
 Only the METERING. Everything downstream of `avgLum` is byte-for-byte the same
 contract as composite14: the same asymmetric clamp (AL_EXPOSURE_MIN/MAX, then
 pulled toward neutral by AL_EXPOSURE_STRENGTH — the field-approved bound that
 keeps auto-exposure from ever lifting a dark night more than ~1%), the same
 frame-rate-independent exponential integrator over AL_EXPOSURE_TAU, the same
 [0.2,5.0] range guards, and the same output slot: colortex5.a at texel (0,0),
 which final reads and multiplies in before AgX. Those constants deliberately
 stay in shaders/settings.glsl rather than being copied into the advanced
 settings include, so the two builds' adaptation behaviour can never fork.

 DOUBLE INTEGRATION — WHY IT CANNOT HAPPEN
 -----------------------------------------
 composite14's fragment metering still runs in this build (nothing in
 shaders.properties can remove one MRT write from a pass, and disabling the
 whole program would take the bloom combine with it). It is made INERT rather
 than removed, in both directions:

   * FORWARD: this compute stage runs after composite14 (it is attached to
     `final`, and a pass's compute always precedes its fragment) and overwrites
     colortex5.a(0,0). final.fsh reads that texel a moment later, so what
     reaches the screen is always this pass's value; the fragment write is dead.
   * BACKWARD: this integrator does NOT read (0,0). It keeps its own previous
     adapted exposure in colortex5.a(1,0) — a texel composite1 and composite14
     both pass through byte-exact (both preserve .a everywhere except (0,0)) —
     so the fragment path's output can never feed back into this loop.

 The exposure that reaches the screen is therefore integrated exactly once per
 frame, by this pass, from its own previous value. And leaving the fragment path
 alive is a safety property, not sloppiness: if a driver or a future Iris ever
 declines to dispatch this compute pass, (0,0) still contains a valid, adapting
 exposure from the mip metering, so the pack degrades to the Mac behaviour
 rather than to a frozen or garbage exposure.

 WHY ONE WORKGROUP
 -----------------
 A histogram needs a reduction over the whole frame. GLSL offers no
 cross-workgroup synchronisation inside a dispatch, so a multi-group histogram
 needs an SSBO plus a second dispatch to resolve it. Inside a SINGLE workgroup
 the reduction is just shared memory, an atomicAdd and a barrier() — no
 persistent buffer to declare, clear, version and range-guard, and no ordering
 assumptions between passes. 16384 texel fetches on one SM is a rounding error
 next to the bloom pyramid this pass follows. See settings_advanced.glsl.

 Bindings: 1 sampler (colortex0) + 1 image (colorimg5). No SSBO, no custom
 images, no extra render target — so the only Iris capability this needs is
 COMPUTE_SHADERS, which shaders.properties.append declares as required.
============================================================================
*/

uniform sampler2D colortex0;        // HDR scene (post bloom-combine, PRE exposure)

// colortex5 as an image, for the read-modify-write of the two exposure texels.
// The format qualifier must match the buffer (colortex5 is RGBA16F; the format
// declarations live in each world's final.fsh and are not restated here — one
// source of truth). We read AND write it: rgb at those two texels is AO history
// and is re-emitted untouched, only .a is ours.
layout(rgba16f) uniform image2D colorimg5;

uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;            // seconds of the last frame (Iris/OptiFine)
uniform int   frameCounter;         // frame index, wraps; drives the jitter

// The frame's log-luminance histogram, in shared memory. uint because
// atomicAdd on shared memory is an integer operation.
shared uint alExpoBins[AL_EXPO_BINS];

// The clear step below zeroes one bin per invocation in a single parallel step,
// which is only correct while there are at least as many invocations as bins.
// Make that a COMPILE error rather than a subtle one: with more bins than
// invocations the top bins would keep last frame's counts and the metering
// would drift upward frame after frame — a bug that looks like "exposure is
// weird sometimes", not like a broken loop.
#if AL_EXPO_BINS > (AL_EXPO_GROUP_X * AL_EXPO_GROUP_Y)
#error "AL_EXPO_BINS must be <= AL_EXPO_GROUP_X * AL_EXPO_GROUP_Y (one clear per invocation)"
#endif

// Total span of the binned window, in stops.
#define AL_EXPO_LOG_SPAN (AL_EXPO_LOG_MAX - AL_EXPO_LOG_MIN)

// The log2-luminance a bin represents (its centre by construction: bin i sits
// at MIN + i/(BINS-1) * SPAN, so bin 0 is exactly MIN and the last is MAX).
float alExpoBinLog(int bin) {
    return AL_EXPO_LOG_MIN + (float(bin) / float(AL_EXPO_BINS - 1)) * AL_EXPO_LOG_SPAN;
}

/*
 Bin index for one sampled colour.

 NaN LAW: the validity test is a pair of POSITIVE comparisons, so a NaN (which
 compares false against everything) fails them and falls into the safe default —
 here bin 0, the darkest bin, which the dark-tail trim discards. A NaN sample can
 therefore never move the metering, and can never reach log2()/int() where its
 behaviour would be undefined. Zero/black texels legitimately land in bin 0 too;
 they are real scene content (unlit faces, the void) and are meant to be counted
 and then trimmed, not skipped — skipping them would let a single torch in a
 pitch-black cave BE the whole population.
*/
int alExpoBinOf(vec3 rgb) {
    float lum   = alLuminance(max(rgb, vec3(0.0)));
    bool  valid = (lum > 0.0) && (lum < 65000.0);
    float lg    = log2(valid ? lum : 1.0);
    float t     = (lg - AL_EXPO_LOG_MIN) * (1.0 / AL_EXPO_LOG_SPAN);
    t = valid ? clamp(t, 0.0, 1.0) : 0.0;
    return int(t * float(AL_EXPO_BINS - 1) + 0.5);
}

void alExposureHistogramMain() {
    uint idx = gl_LocalInvocationIndex;              // 0 .. GROUP_X*GROUP_Y-1

    // ---- 1. clear the shared histogram --------------------------------------
    // AL_EXPO_BINS <= invocation count (compile-time checked above), so this is
    // one parallel step, not a loop.
    if (idx < uint(AL_EXPO_BINS)) alExpoBins[idx] = 0u;
    memoryBarrierShared();
    barrier();

    // ---- 2. bin stratified samples of the frame ------------------------------
    ivec2 res  = ivec2(max(viewWidth, 1.0), max(viewHeight, 1.0));
    ivec2 grid = ivec2(AL_EXPO_GROUP_X * AL_EXPO_TILE_X,
                       AL_EXPO_GROUP_Y * AL_EXPO_TILE_Y);

    // Per-frame jitter of the whole sample lattice, from the R2 low-discrepancy
    // sequence (the 2D generalisation of the golden ratio — successive frames
    // land maximally far apart instead of clustering as a naive fract(n*k) pair
    // would). This turns a fixed grid into a moving one, so the estimator sees
    // every part of the frame over a handful of frames and the integrator's ~TAU
    // averaging removes the residual noise. frameCounter is reduced mod 1024
    // first: it climbs into the hundreds of thousands, where float32 fract()
    // loses the low bits and the jitter would quietly freeze.
    float fc = float(frameCounter - (frameCounter / 1024) * 1024);
    vec2  jitter = fract(vec2(0.7548776662, 0.5698402909) * fc);

    ivec2 lane = ivec2(gl_LocalInvocationID.xy);
    for (int ty = 0; ty < AL_EXPO_TILE_Y; ++ty) {
        for (int tx = 0; tx < AL_EXPO_TILE_X; ++tx) {
            // Interleaved, not blocked: lane (x,y) owns cells x, x+GROUP_X,
            // x+2*GROUP_X, ... so its 64 samples are spread over the WHOLE
            // frame instead of one contiguous screen tile. Blocked would be
            // worse on both counts — a lane parked on a dark wall would send all
            // 64 of its atomics at the same bin (serialised contention), and any
            // partial-frame early-out would bias the estimate to a screen
            // region rather than degrade uniformly.
            ivec2 cell = lane + ivec2(tx * AL_EXPO_GROUP_X, ty * AL_EXPO_GROUP_Y);
            vec2  uv   = (vec2(cell) + jitter) / vec2(grid);
            ivec2 px   = clamp(ivec2(uv * vec2(res)), ivec2(0), res - 1);
            atomicAdd(alExpoBins[alExpoBinOf(texelFetch(colortex0, px, 0).rgb)], 1u);
        }
    }
    memoryBarrierShared();
    barrier();

    // ---- 3. resolve: trimmed mean of the histogram, then adapt --------------
    // One invocation walks AL_EXPO_BINS bins serially. A parallel prefix sum
    // would be the textbook answer for thousands of bins; for 128 it would cost
    // more in barriers than it saves, and the serial walk is far easier to read
    // and to prove correct. Every other invocation exits here — the barriers are
    // all behind us, so this divergence is legal.
    if (idx != 0u) return;

    uint total = 0u;
    for (int i = 0; i < AL_EXPO_BINS; ++i) total += alExpoBins[i];

    // Percentile cuts, expressed as positions in the cumulative population.
    float ftotal  = float(total);
    float lowCut  = ftotal * AL_EXPO_TRIM_DARK;
    float highCut = ftotal * (1.0 - AL_EXPO_TRIM_BRIGHT);

    // Weighted mean of the surviving middle band. The weight of a bin is the
    // OVERLAP of its cumulative interval with [lowCut, highCut] — i.e. bins are
    // split fractionally at the cut points rather than being included or
    // excluded whole. That is what keeps the result temporally smooth: a bin
    // drifting across a cut boundary changes the estimate continuously instead
    // of stepping, so the exposure never ticks visibly as the scene changes.
    float cum = 0.0, wsum = 0.0, lsum = 0.0;
    for (int i = 0; i < AL_EXPO_BINS; ++i) {
        float count = float(alExpoBins[i]);
        float lo    = cum;
        cum += count;
        float w = max(min(cum, highCut) - max(lo, lowCut), 0.0);
        wsum += w;
        lsum += w * alExpoBinLog(i);
    }

    // Geometric mean of the middle band. If the band is empty (only possible
    // with a degenerate trim configuration, or a zero population) fall back to
    // the key, which makes the metered correction exactly neutral.
    float avgLum = (wsum > 0.0) ? exp2(lsum / wsum) : AL_EXPOSURE_KEY;
    avgLum = (avgLum > 0.0 && avgLum < 65000.0) ? avgLum : AL_EXPOSURE_KEY;

    // ---- 4. THE UNCHANGED ADAPTATION CONTRACT -------------------------------
    // Identical to composite14.fsh from here down; only `avgLum` arrived by a
    // different route. Do not "improve" one copy without the other.
    //
    // Asymmetric clamp: the metered multiplier is bounded to
    // [AL_EXPOSURE_MIN, AL_EXPOSURE_MAX] and then pulled toward neutral by
    // AL_EXPOSURE_STRENGTH, so the final multiplier lives in ~[0.90, 1.08].
    // Auto-exposure can never push the image more than ~10% off the calibrated
    // base level, which is what keeps the field-approved dark nights dark — a
    // robust estimator meters a night scene HIGHER than a mip mean does (the
    // mean is dragged up by the moon/torches), so this bound is doing real work
    // here, not carried along out of habit.
    float metered = clamp(AL_EXPOSURE_KEY / max(avgLum, 1.0e-4),
                          AL_EXPOSURE_MIN, AL_EXPOSURE_MAX);
    float target  = mix(1.0, metered, AL_EXPOSURE_STRENGTH);

    // Previous adapted exposure — THIS pass's own, from the state texel, never
    // from the output texel (see the double-integration note in the header).
    // Range-validated [0.2,5.0]: NaN and the undefined first frame of a
    // clear=false buffer both fail the positive comparisons and reset to 1.0.
    vec4  state   = imageLoad(colorimg5, AL_EXPO_SLOT_STATE);
    float prevExp = (state.a >= 0.2 && state.a <= 5.0) ? state.a : 1.0;

    // Exponential integrator with time constant AL_EXPOSURE_TAU: converges over
    // ~TAU seconds regardless of frame rate. frameTime is floored/capped to a
    // sane range so a stalled or bogus frameTime can neither freeze adaptation
    // (rate 0) nor overshoot it.
    float ft   = (frameTime > 0.0 && frameTime < 1.0) ? frameTime : 0.016;
    float rate = clamp(1.0 - exp(-ft / max(AL_EXPOSURE_TAU, 1.0e-3)), 0.0, 1.0);
    float expo = mix(prevExp, target, rate);
    expo = (expo >= 0.2 && expo <= 5.0) ? expo : 1.0;

    // ---- 5. publish ---------------------------------------------------------
    // Two texels, .a only, rgb re-emitted exactly as loaded so the AO history at
    // those pixels survives byte-perfect (the same discipline composite14 and
    // composite1 follow for this buffer).
    imageStore(colorimg5, AL_EXPO_SLOT_STATE, vec4(state.rgb, expo));

    vec4 slot = imageLoad(colorimg5, AL_EXPO_SLOT_OUT);
    imageStore(colorimg5, AL_EXPO_SLOT_OUT, vec4(slot.rgb, expo));
}

#endif // AL_LIB_ADVANCED_EXPOSURE_HISTOGRAM
