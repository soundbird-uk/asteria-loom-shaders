#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/bloom.glsl"

/*
 composite9 (fragment) — BLOOM pyramid, DOWNSAMPLE level 6 (from level 5).

 Real dual-filter pyramid step (full chain in lib/bloom.glsl): builds tile L6
 of the colortex9 atlas from the PREVIOUS, coarser-by-one tile L5 with a 13-tap
 Jimenez fan (alBloomDownsampleTile), every tap clamped inside the source tile so
 no bilinear read bleeds across a tile edge. This is a strict progressive
 downsample — L6 depends only on L5, never on colortex0 or hardware mips.

 Every other atlas texel is passed through byte-exact (texelFetch), because Iris
 double-buffers colortex9 across this pass chain and any texel a pass skips would
 show stale content in the flipped buffer (see lib/bloom.glsl).

 Gated `program.composite9.enabled = BLOOM`. Sampler count: 1 (colortex9).
*/

uniform sampler2D colortex9;      // bloom tile atlas (source tile + pass-through)
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

/* RENDERTARGETS: 9 */
layout(location = 0) out vec4 outBloom;   // -> colortex9 (bloom tile atlas)

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);

    vec2 localUV;
    int tile = alBloomFromAtlas(texcoord, localUV);
    if (tile != 6) {
        outBloom = texelFetch(colortex9, px, 0);   // pass through (flip coherence)
        return;
    }

    // One source-tile (L5) texel in source-tile-local UV. Tile L5 resolution
    // is screen/2^5, so its local texel = 2^5/screenRes.
    vec2 atlasTexel = 1.0 / vec2(viewWidth, viewHeight);
    vec2 dLocal = exp2(float(5)) * atlasTexel;

    vec3 b = alBloomDownsampleTile(colortex9, 5, localUV, dLocal, atlasTexel);
    outBloom = vec4(alBloomGuard(b), 1.0);
}
