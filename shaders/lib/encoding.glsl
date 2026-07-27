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
   colortex3 RGBA8  : r = matID/255, g = flag bits/255 OR emitter light level
                      (see the EMITTER LIGHT LEVEL note below), ba spare
                      (terrain overloads .b/.a as reflectivity/metalness)
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
// Phase 4: NON-WATER translucents (stained glass, ice, slime, honey, nether
// portal) all route through gbuffers_water in Iris (the terrain fallback only
// applies when the program is ABSENT). gbuffers_water discriminates real water
// via mc_Entity and tags everything else AL_MATID_TRANSLUCENT so the composite
// water pass leaves it alone (no SSR / absorption / caustics).
#define AL_MATID_TRANSLUCENT 8
// 0.4.4: light-emitting blocks (torches, redstone torch, glowstone, lava, sea
// lantern, ...). Tagged via block.properties (IDs 10040+) so deferred1 adds
// SELF-ILLUMINATION using the block's OWN texture colour — a redstone torch glows
// red, a torch orange, glowstone yellow — and the bloom pass spreads that colour
// as a coloured halo onto nearby surfaces. (A screen-space approximation of
// coloured light; true voxel-propagated colour needs the compute/GL4.3 advanced
// tier, which the macOS GL4.1 path cannot run.)
#define AL_MATID_EMISSIVE 9

// Flag bits (colortex3.g). Reserved for later phases (subsurface, wetness).
#define AL_FLAG_NONE 0

float alEncodeMatID(int id)   { return float(id) / 255.0; }
int   alDecodeMatID(float v)  { return int(v * 255.0 + 0.5); }

float alEncodeFlags(int bits)  { return float(bits) / 255.0; }
int   alDecodeFlags(float v)   { return int(v * 255.0 + 0.5); }

/* ---- EMITTER LIGHT LEVEL (colortex3.g) ----------------------------------
   COLOURED BLOCK LIGHT (5.4.0) needs to know, per pixel, "is this surface a
   light SOURCE, and how strong is it" so the deferred2 gather can weight each
   emitter by its real emission rather than treating a sculk vein like a
   glowstone block. There is no free buffer left in the opaque G-buffer, but
   colortex3.g is: it has only ever been written as alEncodeFlags(AL_FLAG_NONE)
   (== 0.0) and is read by NOTHING in the pack (verified across every program).
   So the channel is reused, WITHOUT breaking the flag convention: AL_FLAG_NONE
   is 0 and every non-emitter still writes exactly 0, so "flags == none" and
   "emission == 0" are the same bit pattern. If real flag bits are ever needed
   they must move to a different channel — this note is the record of that.

   The stored value is the block's light level normalised to [0,1] (level/15),
   which survives the RGBA8 quantisation with ~4 levels of headroom per step.
   Because RGBA8 is UNORM the hardware clamps it, so this channel can never
   carry a NaN into the gather (the pack's NaN law is satisfied structurally).
   Only AL_MATID_EMISSIVE pixels ever write a non-zero value. */
float alEncodeEmission(float level01) { return alSaturate(level01); }
float alDecodeEmission(float v)       { return alSaturate(v); }

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
