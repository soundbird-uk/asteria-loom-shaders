#ifndef AL_LIB_COMMON
#define AL_LIB_COMMON

/*
 lib/common.glsl — small constants and helpers shared everywhere.
 Pure GLSL 3.30 math, no samplers, no state. Keep this dependency-free.
*/

#include "/settings.glsl"

#define AL_PI     3.14159265358979
#define AL_TAU    6.28318530717959
#define AL_HALFPI 1.57079632679490

// Clamp-to-[0,1] convenience (a.k.a. HLSL saturate).
float alSaturate(float x)  { return clamp(x, 0.0, 1.0); }
vec2  alSaturate(vec2  x)  { return clamp(x, 0.0, 1.0); }
vec3  alSaturate(vec3  x)  { return clamp(x, 0.0, 1.0); }

// Smooth 0..1 ramp with zero derivative at both ends (Hermite).
float alSmooth(float x) { x = alSaturate(x); return x * x * (3.0 - 2.0 * x); }

#endif // AL_LIB_COMMON
