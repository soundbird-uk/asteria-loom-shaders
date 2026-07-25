#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/bloom.glsl"

/*
 composite10 (fragment) — BLOOM pyramid, UPSAMPLE level 5 (U5 = L5 + tent(U6)).

 Real dual-filter tent-cascade step (full chain in lib/bloom.glsl): 3x3-tent
 upsamples the coarser, already-accumulated tile U6 and ADDS it onto this
 level's own downsampled tile L5, overwriting tile L5 in place with U5. The
 tent taps are clamped inside tile L6 (no cross-tile bleed); this level's own
 value is read byte-exact from the pixel being written (texelFetch), which under
 the Iris flip returns the pre-flip L5 the downsample chain stored.

 Every other atlas texel is passed through byte-exact so the flipped buffer stays
 coherent (see lib/bloom.glsl). Walking composite10..composite13 down the levels
 accumulates U5..U2; composite14 folds the final U1 = L1 + tent(U2) into scene.

 Gated `program.composite10.enabled = BLOOM`. Sampler count: 1 (colortex9).
*/

uniform sampler2D colortex9;      // bloom tile atlas (own + coarser tile, pass-through)
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

/* RENDERTARGETS: 9 */
layout(location = 0) out vec4 outBloom;   // -> colortex9 (bloom tile atlas)

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);

    vec2 localUV;
    int tile = alBloomFromAtlas(texcoord, localUV);
    if (tile != 5) {
        outBloom = texelFetch(colortex9, px, 0);   // pass through (flip coherence)
        return;
    }

    vec2 atlasTexel = 1.0 / vec2(viewWidth, viewHeight);

    // This level's own downsampled value (pre-flip tile L5 at this exact texel).
    vec3 base = texelFetch(colortex9, px, 0).rgb;

    // Tent-upsample the coarser accumulated tile U6. One source (L6) texel is
    // 2^6/screenRes in its local UV; AL_BLOOM_TENT_RADIUS widens the tent.
    vec2 sLocal = AL_BLOOM_TENT_RADIUS * exp2(float(6)) * atlasTexel;
    vec3 up = alBloomTentTile(colortex9, 6, localUV, sLocal, atlasTexel);

    outBloom = vec4(alBloomGuard(base + up), 1.0);
}
