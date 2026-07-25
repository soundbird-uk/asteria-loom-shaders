#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/bloom.glsl"

/*
 composite6 (fragment) — BLOOM pyramid, DOWNSAMPLE level 3 (from level 2).

 Real dual-filter pyramid step (full chain in lib/bloom.glsl): builds tile L3
 of the colortex9 atlas from the PREVIOUS, coarser-by-one tile L2 with a 13-tap
 Jimenez fan (alBloomDownsampleTile), every tap clamped inside the source tile so
 no bilinear read bleeds across a tile edge. This is a strict progressive
 downsample — L3 depends only on L2, never on colortex0 or hardware mips.

 Every other atlas texel is passed through byte-exact (texelFetch), because Iris
 double-buffers colortex9 across this pass chain and any texel a pass skips would
 show stale content in the flipped buffer (see lib/bloom.glsl).

 Gated `program.composite6.enabled = BLOOM`. Sampler count: 1 (colortex9).
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
    if (tile != 3) {
        outBloom = texelFetch(colortex9, px, 0);   // pass through (flip coherence)
        return;
    }

    // One source-tile (L2) texel in source-tile-local UV. Tile L2 resolution
    // is screen/2^2, so its local texel = 2^2/screenRes.
    vec2 atlasTexel = 1.0 / vec2(viewWidth, viewHeight);
    vec2 dLocal = exp2(float(2)) * atlasTexel;

    vec3 b = alBloomDownsampleTile(colortex9, 2, localUV, dLocal, atlasTexel);
    outBloom = vec4(alBloomGuard(b), 1.0);
}
