#ifndef AL_LIB_COLOR
#define AL_LIB_COLOR

/*
 lib/color.glsl — colour-space transforms, luminance, tonemap placeholder.
 All pure float math (GLSL 3.30 safe). Lighting runs in LINEAR space; textures
 arrive as sRGB and must be decoded before shading, then re-encoded in final.
*/

#include "/lib/common.glsl"

// sRGB <-> linear. Fast 2.2-gamma approximation — precise enough for Phase 1,
// cheap, and branch-free. (A piecewise-exact sRGB curve can drop in later.)
vec3 alSrgbToLinear(vec3 c) { return pow(max(c, 0.0), vec3(2.2)); }
vec3 alLinearToSrgb(vec3 c) { return pow(max(c, 0.0), vec3(1.0 / 2.2)); }

// Rec.709 relative luminance of a linear-RGB colour.
float alLuminance(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

/*
 PLACEHOLDER TONEMAP — Phase 4 REPLACEMENT TARGET.
 This is the Narkowicz ACES filmic fit: cheap, gives a pleasant filmic
 shoulder so HDR values read reasonably. It is explicitly a stand-in; the
 real look is the AgX-style soft-filmic grade delivered in Phase 4. Do not
 tune the pack's final contrast against this curve.
 Input: linear HDR. Output: display-linear in [0,1] (still needs sRGB encode).
*/
vec3 alTonemapPlaceholder(vec3 x) {
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return alSaturate((x * (a * x + b)) / (x * (c * x + d) + e));
}

#endif // AL_LIB_COLOR
