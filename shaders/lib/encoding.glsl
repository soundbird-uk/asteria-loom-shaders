#ifndef AL_LIB_ENCODING
#define AL_LIB_ENCODING

/*
 lib/encoding.glsl — G-buffer packing helpers. Pure float math, GLSL 3.30
 safe: NO packUnorm2x16 / packHalf2x16 (those are GLSL 4.0+ and would break
 the macOS GL 4.1 path). Manual octahedral normal encode/decode and material
 ID / flag conventions live here so every program agrees on the layout.

 G-buffer recap (formats declared once, in final.fsh):
   colortex1 RGBA8  : albedo.rgb, a = vanilla AO / spare (1.0 default)
   colortex2 RGBA16 : normal.rg (octahedral), lightmap.ba (block, sky)
   colortex3 RGBA8  : r = matID/255, g = flag bits/255, ba spare
*/

#include "/lib/common.glsl"

/* ---- Material IDs -------------------------------------------------------
   Stored in colortex3.r as matID/255.0 and recovered as round(r*255).
   Phase 1 has no block.properties, so terrain uses the default 0; the other
   render paths tag themselves so later phases (water shading, entity FX) can
   branch cheaply. */
#define AL_MATID_TERRAIN  0
#define AL_MATID_WATER    1
#define AL_MATID_ENTITY   2
#define AL_MATID_HAND     3
#define AL_MATID_PARTICLE 4
#define AL_MATID_BLOCK    5   // block entities (chests, signs, ...)
#define AL_MATID_WEATHER  6
#define AL_MATID_BASIC    7   // untextured geometry (selection box, etc.)

// Flag bits (colortex3.g). Reserved for later phases (emissive, subsurface,
// wetness). Phase 1 writes AL_FLAG_NONE everywhere.
#define AL_FLAG_NONE 0

float alEncodeMatID(int id)   { return float(id) / 255.0; }
int   alDecodeMatID(float v)  { return int(v * 255.0 + 0.5); }

float alEncodeFlags(int bits)  { return float(bits) / 255.0; }
int   alDecodeFlags(float v)   { return int(v * 255.0 + 0.5); }

/* ---- Octahedral normal encode/decode ------------------------------------
   Maps a unit vector to vec2 in [0,1] (fits colortex2.rg at 16-bit UNORM).
   Standard Cigolle et al. octahedral mapping, done in plain float math. */
vec2 alSignNotZero(vec2 v) {
    return vec2(v.x >= 0.0 ? 1.0 : -1.0,
                v.y >= 0.0 ? 1.0 : -1.0);
}

vec2 alEncodeNormal(vec3 n) {
    n = normalize(n);
    n /= (abs(n.x) + abs(n.y) + abs(n.z));
    vec2 oct = (n.z >= 0.0) ? n.xy
                            : (1.0 - abs(n.yx)) * alSignNotZero(n.xy);
    return oct * 0.5 + 0.5;   // -> [0,1]
}

vec3 alDecodeNormal(vec2 f) {
    f = f * 2.0 - 1.0;        // -> [-1,1]
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = alSaturate(-n.z);
    n.x += (n.x >= 0.0) ? -t : t;
    n.y += (n.y >= 0.0) ? -t : t;
    return normalize(n);
}

#endif // AL_LIB_ENCODING
