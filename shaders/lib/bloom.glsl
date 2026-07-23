#ifndef AL_LIB_BLOOM
#define AL_LIB_BLOOM

/*
 lib/bloom.glsl — bloom mip-chain tile atlas layout + dual-filter kernels.

 Threshold-free, energy-conserving mip bloom (brief §6). The bloom pyramid is
 packed into ONE buffer (colortex9, RGBA16F, cleared each frame) as a horizontal
 "mip strip" of 6 tiles, so a single composite4 pass can write the whole chain
 and a single composite5 pass can read it back. This mirrors the sky-view-LUT
 tile idiom (lib/atmosphere*.glsl): a documented sub-rectangle, sampled with a
 clamped inset so no bilinear tap ever bleeds across a tile edge.

 --------------------------------------------------------------------------
 ATLAS LAYOUT (colortex9, coordinates in [0,1] UV over the full buffer)
 --------------------------------------------------------------------------
 6 levels. Level L (L = 1..6) is a copy of the scene blurred + downscaled to
 1/2^L of the screen (L1 = half res ... L6 = 1/64 res). Each tile is a
 screen-aspect rectangle of side 2^-L, laid out left-to-right along the top:

     x0(L) = 1 - 2^-(L-1)     width(L) = 2^-L      y in [0, 2^-L]

   ┌───────────────┬───────┬───┬─┬┐
   │               │  L2   │L3 │.││   L1 : x[0,   1/2 ], y[0, 1/2 ]
   │      L1        │       ├───┴─┴┘   L2 : x[1/2, 3/4 ], y[0, 1/4 ]
   │  (1/2 res)     ├───────┘          L3 : x[3/4, 7/8 ], y[0, 1/8 ]
   │               │                   L4 : x[7/8, 15/16], y[0,1/16]
   │               │                   L5 : x[15/16,31/32],y[0,1/32]
   └───────────────┘                   L6 : x[31/32,63/64],y[0,1/64]

 Total width used = 63/64 < 1, height <= 1/2 — the tiles never overlap (their
 x-columns are disjoint), and the buffer is cleared each frame so unused texels
 stay 0 (they contribute nothing if ever sampled). All wider levels sit to the
 right of L1, so the whole chain reads in one pass with no dependency cycle.

 QUALITY/SIMPLICITY TRADE (documented per contract §5): composite4 does NOT do
 a strict progressive downsample (mip N from mip N-1); a single pass cannot read
 the target it writes. Instead every tile is built directly from colortex0 with
 hardware mipmaps supplying the pre-blur (textureLod at LOD ~ L) and a 13-tap
 dual-filter fan adding the wide, grain-free blur. composite5 then sums the
 tiles with per-level weights (a single-pass gather, not a strict tent-cascade
 upsample — the deviation is intentional and documented in composite5.fsh). For
 the pack's soft/dreamy identity this reads identically to a full dual-filter
 pyramid at a fraction of the passes.
 --------------------------------------------------------------------------
*/

#include "/lib/common.glsl"

#define AL_BLOOM_LEVELS 6

// Tile rectangle in atlas UV: vec4(x0, y0, x1, y1) for level L (1..6).
vec4 alBloomTileRect(int L) {
    float invPrev = exp2(-float(L - 1));   // 2^-(L-1)
    float invCur  = exp2(-float(L));       // 2^-L
    float x0 = 1.0 - invPrev;
    float x1 = 1.0 - invCur;
    return vec4(x0, 0.0, x1, invCur);      // y0=0, y1=2^-L
}

// Map a level-local UV (0..1 over the screen) into the atlas, clamped to a
// half-texel-inset sub-rectangle so bilinear taps never sample a neighbour tile
// (the sky-LUT-tile no-bleed pattern). `atlasTexel` = 1/buffer-resolution.
vec2 alBloomToAtlas(int L, vec2 localUV, vec2 atlasTexel) {
    vec4 r = alBloomTileRect(L);
    vec2 inset = atlasTexel * 1.5;
    vec2 lo = r.xy + inset;
    vec2 hi = r.zw - inset;
    return clamp(mix(r.xy, r.zw, alSaturate(localUV)), lo, hi);
}

// Which tile does an atlas texel belong to? Returns the level (1..6) and writes
// the level-local UV; returns 0 when the texel is outside every tile.
int alBloomFromAtlas(vec2 atlasUV, out vec2 localUV) {
    localUV = vec2(0.0);
    for (int L = 1; L <= AL_BLOOM_LEVELS; L++) {
        vec4 r = alBloomTileRect(L);
        if (atlasUV.x >= r.x && atlasUV.x < r.z &&
            atlasUV.y >= r.y && atlasUV.y < r.w) {
            localUV = (atlasUV - r.xy) / max(r.zw - r.xy, vec2(1e-6));
            return L;
        }
    }
    return 0;
}

/*
 13-tap dual-filter DOWNSAMPLE (Jimenez 2014, "Next Generation Post Processing
 in Call of Duty: Advanced Warfare"). Samples a 4x4 neighbourhood as one centre
 2x2 box plus four overlapping corner boxes; the centre box carries half the
 weight, killing the "fireflies" a naive box filter leaves. `d` is the sample
 step (one destination-level texel, in source UV). `lod` picks the hardware mip
 that supplies the pre-blur for this level.
*/
vec3 alBloomDownsample(sampler2D tex, vec2 uv, vec2 d, float lod) {
    vec3 a = textureLod(tex, uv + d * vec2(-2.0, -2.0), lod).rgb;
    vec3 b = textureLod(tex, uv + d * vec2( 0.0, -2.0), lod).rgb;
    vec3 c = textureLod(tex, uv + d * vec2( 2.0, -2.0), lod).rgb;
    vec3 e = textureLod(tex, uv + d * vec2(-2.0,  0.0), lod).rgb;
    vec3 f = textureLod(tex, uv,                        lod).rgb;
    vec3 g = textureLod(tex, uv + d * vec2( 2.0,  0.0), lod).rgb;
    vec3 h = textureLod(tex, uv + d * vec2(-2.0,  2.0), lod).rgb;
    vec3 i = textureLod(tex, uv + d * vec2( 0.0,  2.0), lod).rgb;
    vec3 j = textureLod(tex, uv + d * vec2( 2.0,  2.0), lod).rgb;
    vec3 k = textureLod(tex, uv + d * vec2(-1.0, -1.0), lod).rgb;
    vec3 l = textureLod(tex, uv + d * vec2( 1.0, -1.0), lod).rgb;
    vec3 m = textureLod(tex, uv + d * vec2(-1.0,  1.0), lod).rgb;
    vec3 n = textureLod(tex, uv + d * vec2( 1.0,  1.0), lod).rgb;

    // Centre 2x2 (k,l,m,n) weighted 0.5; the four outer 2x2 boxes 0.125 each.
    vec3 sum  = (k + l + m + n) * 0.5;    // inner box   (0.5 total)
    sum += (a + b + e + f) * 0.125;       // TL box
    sum += (b + c + f + g) * 0.125;       // TR box
    sum += (e + f + h + i) * 0.125;       // BL box
    sum += (f + g + i + j) * 0.125;       // BR box
    // Each grouped term above already includes its 0.25 box-average via the
    // 0.5 / 0.125 factors summing to 1.0 across the 4x4 support.
    return sum * 0.25;
}

// NOTE: composite5 combines the chain with a single BILINEAR gather per tile
// (each tile is already dual-filter blurred by composite4, so a plain
// alBloomToAtlas() sample reads smoothly — a per-tile 9-tap tent added no
// visible smoothing for its cost). The tent-upsample helper that lived here was
// dead code and has been removed; alBloomToAtlas() + alBloomLevelWeight() are
// the whole read path. If a strict tent cascade is ever wanted, reintroduce it
// as a documented multi-pass upsample, not a single-pass gather.

// Per-level combine weights (dreamy/soft: slightly favour the WIDE levels so the
// glow reads as a broad, painterly halo rather than a tight ring). Normalised to
// sum 1.0 so the summed bloom is an energy-preserving weighted average of the
// levels — no term can inject unbounded energy. Index by level 1..6.
float alBloomLevelWeight(int L) {
    // L1(tight) .. L6(widest). Monotone increasing toward wide.
    // raw: 0.10 0.13 0.16 0.18 0.20 0.23  (sum = 1.00)
    if (L <= 1) return 0.10;
    if (L == 2) return 0.13;
    if (L == 3) return 0.16;
    if (L == 4) return 0.18;
    if (L == 5) return 0.20;
    return 0.23;
}

// Range-validate a bloom-atlas read (colortex9 is cleared, but be NaN-robust and
// bound HDR so a single hot texel can't blow the sum). Comparisons reject NaN.
vec3 alBloomValidate(vec3 v) {
    bool ok = (v.r >= 0.0) && (v.g >= 0.0) && (v.b >= 0.0)
           && (v.r < 65000.0) && (v.g < 65000.0) && (v.b < 65000.0);
    return ok ? v : vec3(0.0);
}

#endif // AL_LIB_BLOOM
