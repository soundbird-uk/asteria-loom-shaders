#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/bloom.glsl"

/*
 composite4 (fragment) — BLOOM downsample tile chain (brief §6, phase4 §5).

 Builds the whole 6-level bloom pyramid (lib/bloom.glsl atlas layout) in ONE
 pass into colortex9. Threshold-free / energy-conserving: there is NO bright-
 pass cutoff — the scene's natural HDR range (torches, glowstone, the sun disc,
 all > 1.0) drives the glow, so emissive blocks spill and everyday daylight
 barely blooms. Because a pass cannot read the target it writes, every tile is
 built DIRECTLY from colortex0 (the post-TAA scene) rather than from the
 previous, coarser tile: hardware mipmaps (colortex0MipmapEnabled below) supply
 the pre-blur at LOD ~ level, and a 13-tap Jimenez dual-filter fan (scaled to
 that level's texel size) adds the wide, firefly-free blur. Documented
 quality/simplicity trade in lib/bloom.glsl.

 This pass is gated `program.composite4.enabled = BLOOM`, so POTATO (and anyone
 who turns bloom off) skips it entirely and colortex9 stays cleared (0).

 MIPMAP CONST: `colortex0MipmapEnabled` is a per-PROGRAM Iris directive that
 Iris parses from THIS shader's source (its ConstDirectiveParser reads the
 literal). It is a real `const bool` with a valid GLSL literal initialiser, so
 unlike the colortexNFormat identifiers it is LEGAL live code (no non-GLSL
 token) and compiles cleanly on the Mac path — declared live here, per program.

 Sampler count: 1 (colortex0). Budget <=16.
*/

const bool colortex0MipmapEnabled = true;   // hardware mips feed the pre-blur

uniform sampler2D colortex0;      // post-TAA HDR scene
uniform float viewWidth;
uniform float viewHeight;

in vec2 texcoord;

/* RENDERTARGETS: 9 */
layout(location = 0) out vec4 outBloom;   // -> colortex9 (bloom tile atlas)

void main() {
    // Which atlas tile does this output texel belong to?
    vec2 localUV;
    int L = alBloomFromAtlas(texcoord, localUV);
    if (L == 0) {
        // Between/around tiles — leave 0 (buffer is cleared each frame anyway).
        outBloom = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    // Sample step for the 13-tap fan = ONE destination-level texel expressed in
    // full-res source UV. Dest-level resolution = screen / 2^L, so its texel in
    // source UV is 2^L / screenRes.
    vec2 srcTexel = 1.0 / vec2(viewWidth, viewHeight);
    vec2 d = exp2(float(L)) * srcTexel;
    float lod = float(L);   // pre-blurred mip for this level

    vec3 b = alBloomDownsample(colortex0, localUV, d, lod);

    // NaN / HDR guard (comparisons reject NaN); bound so one hot texel can't
    // poison the atlas that composite5 sums.
    bool ok = (b.r >= 0.0) && (b.g >= 0.0) && (b.b >= 0.0);
    b = ok ? min(b, vec3(60000.0)) : vec3(0.0);

    outBloom = vec4(b, 1.0);
}
