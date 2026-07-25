#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/bloom.glsl"

/*
 composite4 (fragment) — BLOOM pyramid, DOWNSAMPLE level 1 (brief §6, phase4 §5).

 First step of the REAL dual-filter pyramid (full chain documented in
 lib/bloom.glsl). Fans the post-TAA HDR scene (colortex0) into tile L1 of the
 colortex9 atlas with a 13-tap Jimenez downsample at LOD 0 — NO hardware mips,
 NO bright-pass threshold. The scene's natural HDR range (torches, glowstone,
 sun disc, all > 1.0) drives the glow; emissive blocks spill and daylight barely
 blooms. Later passes (composite5..composite9) build L2..L6 each from the
 PREVIOUS level, then composite10..composite14 tent-upsample back up.

 Every OTHER atlas texel is passed through byte-exact (texelFetch copy): Iris
 double-buffers colortex9 across this multi-pass chain and a pass that skips a
 texel would leave stale 2-passes-ago content in the flipped buffer, so each pass
 writes EVERY texel (see lib/bloom.glsl).

 Gated `program.composite4.enabled = BLOOM`, so POTATO (and anyone who turns
 bloom off) skips it and the whole pyramid chain is never built.

 Sampler count: 2 (colortex0, colortex9). Budget <=16.
*/

uniform sampler2D colortex0;      // post-TAA HDR scene
uniform sampler2D colortex9;      // bloom tile atlas (pass-through of other tiles)
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

/* RENDERTARGETS: 9 */
layout(location = 0) out vec4 outBloom;   // -> colortex9 (bloom tile atlas)

void main() {
    ivec2 px = ivec2(gl_FragCoord.xy);

    vec2 localUV;
    int tile = alBloomFromAtlas(texcoord, localUV);
    if (tile != 1) {
        outBloom = texelFetch(colortex9, px, 0);   // pass through (flip coherence)
        return;
    }

    // L1 = half-res scene. The 13-tap fan steps by ONE full-res source texel;
    // localUV maps directly to screen UV for L1 (the tile spans the whole frame).
    vec2 srcTexel = 1.0 / vec2(viewWidth, viewHeight);
    vec3 b = alBloomDownsample(colortex0, localUV, srcTexel, 0.0);

    outBloom = vec4(alBloomGuard(b), 1.0);
}
