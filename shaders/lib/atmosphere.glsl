#ifndef AL_LIB_ATMOSPHERE
#define AL_LIB_ATMOSPHERE

/*
 lib/atmosphere.glsl — the sky-view LUT READ side of the atmosphere model.

 This file adds the ONE sampler the LUT read needs (colortex6) on top of the
 sampler-free core in lib/atmosphere_common.glsl. Include this ONLY in passes
 that can afford the sky sampler and actually read the baked sky:
   gbuffers_skybasic, composite (clouds), composite1 (fog).
 Do NOT include it from lib/lighting.glsl or any forward geometry pass — those
 use the analytic alDirectColor()/alAmbientColor() from the common core and
 must gain no samplers (hard Phase-3 contract requirement). prepare.fsh WRITES
 colortex6 and includes only the common core, so it never samples the tile.

 The tile is the top-left AL_SKY_TILE_W x AL_SKY_TILE_H region of colortex6
 (see the mapping doc in atmosphere_common.glsl). We derive the buffer size
 with textureSize() rather than a viewWidth/viewHeight uniform so this include
 declares no uniforms that a caller could collide with.
*/

#include "/lib/atmosphere_common.glsl"

uniform sampler2D colortex6;   // sky-view LUT (top-left tile)

// NOTE on the sun direction: the world-space sun direction helper
// alApproxSunDirWorld() is owned by lib/clouds_common.glsl (it is sampler-free
// and shared by the clouds/lighting chain). This file does NOT redeclare it or
// the sunPosition uniform — passes that need the sun direction and include this
// file compute it their own way (gbuffers_skybasic from its own sunPosition;
// composite/composite1 via clouds_common / space helpers).

// Cheap LUT read: direction -> baked sky radiance. colortex6 is clear=false, so
// the very first frame(s) contain undefined garbage. The read is therefore
// RANGE-VALIDATED with comparisons (NaN fails every one) and self-heals to the
// analytic alSkyFallback — never black, per contract.
//
// Tile addressing clamps the sampled pixel to the tile interior with a
// half-texel inset so a bilinear fetch can never bleed into the unused rest of
// the buffer (or wrap the azimuth seam into a neighbouring row).
vec3 alSkySample(vec3 dir) {
    vec2 bufSize = vec2(textureSize(colortex6, 0));
    bufSize = max(bufSize, vec2(1.0));

    vec2 px = alSkyMapUV(dir) * vec2(AL_SKY_TILE_W, AL_SKY_TILE_H);
    px = clamp(px, vec2(0.5), vec2(AL_SKY_TILE_W - 0.5, AL_SKY_TILE_H - 0.5));
    vec2 uv = px / bufSize;

    vec3 c = texture(colortex6, uv).rgb;

    // Range validation (NaN/Inf/negative all fail -> fallback).
    bool ok = all(greaterThanEqual(c, vec3(0.0))) && all(lessThan(c, vec3(1e4)));
    return ok ? c : alSkyFallback(dir);
}

#endif // AL_LIB_ATMOSPHERE
