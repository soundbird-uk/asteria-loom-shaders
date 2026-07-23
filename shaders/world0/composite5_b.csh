#version 460 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"

/*
 composite5_b (COMPUTE) — advanced-tier auto-exposure, stage 2 of 2: ACCUMULATE.
 Phase 6, world0. Runs after composite5_a (which cleared the bins) and before
 composite5.fsh. Advanced/compute-capable path only.

 Each invocation samples one STRIDED screen pixel of the HDR scene (colortex0),
 computes its luminance, maps it to a log-luminance bin and atomically bumps that
 bin. workGroupsRender = 0.25 dispatches a quarter-resolution grid; multiplying
 the invocation id by 4 spreads those samples across the full frame at ~1/16
 density — plenty for a stable 128-bin histogram while keeping atomic contention
 and bandwidth sane (a full per-pixel dispatch would serialise millions of
 atomics onto 128 bins).

 VERIFICATION: syntax-validated by the CI compile gate (glslang, advanced target)
 only — no GPU in CI, maintainer on macOS — so on-device behaviour is unverified.
*/

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(0.25, 0.25);   // quarter-res grid (1/16 samples)

#ifdef AL_ADVANCED_TIER
// Same histogram SSBO as _a (shared binding).
layout(std430, binding = 0) buffer AlExposureHistogram {
    uint alHistoBins[AL_HISTO_BINS];
};

uniform sampler2D colortex0;   // HDR scene (post fog / TAA)
uniform float viewWidth;
uniform float viewHeight;

// Linear luminance -> bin index (log2 mapped over [LOG_MIN, LOG_MAX]).
int alLumToBin(float lum) {
    float logL = log2(max(lum, 1.0e-6));
    float f    = (logL - AL_HISTO_LOG_MIN) / (AL_HISTO_LOG_MAX - AL_HISTO_LOG_MIN);
    int   b    = int(floor(clamp(f, 0.0, 0.999999) * float(AL_HISTO_BINS)));
    return clamp(b, 0, AL_HISTO_BINS - 1);
}
#endif

void main() {
#ifdef AL_ADVANCED_TIER
    // Strided full-frame coverage: quarter-res dispatch, x4 in each axis.
    ivec2 px = ivec2(gl_GlobalInvocationID.xy) * 4;
    if (px.x >= int(viewWidth) || px.y >= int(viewHeight)) return;

    vec3  c   = texelFetch(colortex0, px, 0).rgb;
    float lum = alLuminance(max(c, vec3(0.0)));
    if (!(lum >= 0.0) || lum > 65000.0) return;   // reject NaN / garbage

    atomicAdd(alHistoBins[alLumToBin(lum)], 1u);
#endif
}
