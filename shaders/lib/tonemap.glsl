#ifndef AL_LIB_TONEMAP
#define AL_LIB_TONEMAP

/*
 lib/tonemap.glsl — AgX tonemap (Phase 4 replacement for the placeholder ACES
 fit in lib/color.glsl). Pure GLSL 3.30 math: a 3x3 input "inset" matrix, a
 log2 encoding, a 6th-order sigmoid polynomial fit of the AgX contrast curve,
 an artistic "look" (saturation / warm tilt / midtone slope+power) and the
 inverse-matrix EOTF back to display-linear. No LUT textures.

 AgX gives the brief's soft-filmic identity: highlights desaturate toward white
 (no neon clipping on the HDR sun / torches), blacks lift gently, and the
 midtone rolloff is softer than ACES. The polynomial is Troy Sobotka's minimal
 AgX approximation (public-domain), widely used in Godot/Blender-derived
 shaders — reimplemented here, not copied from any shaderpack.

 CALIBRATION (contract §0 / §6): the whole point of Phase 4's grade is to keep
 the field-approved noon/night LEVELS while upgrading the contrast character.
 tools/-side numeric simulation compared this AgX path against the outgoing
 placeholder (Narkowicz ACES) for grey L = 0.02..2.0 and tuned the three look
 knobs + the calibration exposure so a mid-grey noon (L=0.18) and the darker
 night (L=0.05) land within ~10% of the placeholder's display luminance:

     L(lin)  placeholder  AgX    ratio
     0.05    0.2425       0.2612  1.08   <- night anchor  (+7.7%)
     0.18    0.5486       0.5066  0.92   <- noon  anchor  (-7.6%)
     0.50    0.8025       0.7279  0.91          (softer midtone = the AgX look)
     1.20    0.9237       0.8990  0.97          (gentle highlight rolloff)
     2.00    0.9604       0.9794  1.02          (HDR never hard-clips)

 Defaults live in settings.glsl (AL_AGX_EXPOSURE / _SLOPE / _POWER / _SAT /
 _WARM); edit + hot-reload to retune.

 OUTPUT SPACE: alTonemapAgX() returns DISPLAY-LINEAR in [0,1]. The caller
 (final.fsh) applies the biome/weather grade in this space and then the
 linear->sRGB encode (alLinearToSrgb). The EOTF's pow(2.2) below linearises the
 sigmoid's display-encoded value; the caller's 1/2.2 re-encode closes the loop,
 so the grade runs in a perceptually sane linear space in between.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"

// AgX inset matrix (rec.709 -> AgX working space) and its inverse.
const mat3 AL_AGX_MAT = mat3(
    0.842479062253094,  0.0423282422610123, 0.0423756549057051,
    0.0784335999999992, 0.878468636469772,  0.0784336,
    0.0792237451477643, 0.0791661274605434, 0.879142973793104);

const mat3 AL_AGX_MAT_INV = mat3(
     1.19687900512017,   -0.0528968517574562, -0.0529716355144438,
    -0.0980208811401368,  1.15190312990417,   -0.0980434501171241,
    -0.0990297440797205, -0.0989611768448433,  1.15107367264116);

// 6th-order polynomial fit of the AgX sigmoid (input/output in [0,1]).
vec3 alAgxContrast(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;
    return 15.5 * x4 * x2
         - 40.14 * x4 * x
         + 31.96 * x4
         - 6.868 * x2 * x
         + 0.4298 * x2
         + 0.1191 * x
         - 0.00232;
}

// Full AgX. Input: linear HDR (already exposure-scaled by the caller). Output:
// display-linear [0,1].
vec3 alTonemapAgX(vec3 col) {
    const float minEv = -12.47393;
    const float maxEv =   4.026069;

    // Calibration exposure (keeps levels on target — see the table above).
    col *= AL_AGX_EXPOSURE;
    col = max(col, vec3(0.0));

    // Input transform + log2 encode, normalised to [0,1] over the EV window.
    col = AL_AGX_MAT * col;
    col = clamp(log2(max(col, vec3(1e-10))), minEv, maxEv);
    col = (col - minEv) / (maxEv - minEv);

    // Sigmoid.
    col = alAgxContrast(col);

    // ---- Look (artistic) ----
    // Warm tilt: nudge the red channel up and blue down a hair (the pack's
    // amber bias carried into the tonemap, subtle).
    vec3 tilt = vec3(1.0 + AL_AGX_WARM, 1.0, 1.0 - AL_AGX_WARM);
    float luma = alLuminance(col);
    vec3 lifted = pow(max(col * AL_AGX_SLOPE * tilt, vec3(0.0)), vec3(AL_AGX_POWER));
    // Saturation about luminance.
    col = luma + AL_AGX_SAT * (lifted - luma);

    // EOTF: back to display-linear.
    col = AL_AGX_MAT_INV * col;
    col = pow(max(col, vec3(0.0)), vec3(2.2));
    return alSaturate(col);
}

#endif // AL_LIB_TONEMAP
