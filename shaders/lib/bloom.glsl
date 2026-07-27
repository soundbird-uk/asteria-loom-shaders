#ifndef AL_LIB_BLOOM
#define AL_LIB_BLOOM

/*
 lib/bloom.glsl — bloom mip-chain tile atlas layout + dual-filter kernels.

 Threshold-free, energy-conserving mip bloom (brief §6), implemented as a REAL
 dual-filter pyramid (Jimenez 2014 "Next Generation Post Processing in Call of
 Duty: Advanced Warfare" / Kawase-style dual filtering): a progressive DOWNSAMPLE
 (each level built from the PREVIOUS, coarser-by-one level — never from colortex0
 or hardware mips) followed by a tent-filter cascade UPSAMPLE (each coarse level
 3x3-tent-upsampled and added back onto the next finer level, walking up).

 The pyramid is packed into ONE buffer (colortex9, RGBA16F) as a horizontal "mip
 strip" of 6 tiles. This mirrors the sky-view-LUT tile idiom
 (lib/atmosphere*.glsl): a documented sub-rectangle, sampled with a clamped inset
 so no bilinear tap ever bleeds across a tile edge.

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
 x-columns are disjoint). Each level is a screen-aspect tile whose pixel
 resolution is screen/2^L; tile L only ever samples tile L-1 (downsample) or tile
 L+1 (upsample), always with the clamped inset so no tap crosses a tile edge.

 REAL PYRAMID, EXPRESSED AS SEQUENTIAL Iris PASSES (contract §5). Iris cannot let
 a program read the target it writes, and its double-buffer flip means any pass
 that writes colortex9 must write EVERY texel of it (a texel it skips shows stale
 2-passes-ago content in the flipped buffer). So the pyramid is a chain of small
 composite passes, each of which computes ONE tile and passes ALL other texels
 through byte-exact (texelFetch copy), keeping the flip coherent:

     composite4 : DOWNSAMPLE scene(colortex0) -> tile L1   (13-tap fan, LOD 0)
     composite5 : DOWNSAMPLE tile L1 -> tile L2            (from the PREV level)
     composite6 : DOWNSAMPLE tile L2 -> tile L3
     composite7 : DOWNSAMPLE tile L3 -> tile L4
     composite8 : DOWNSAMPLE tile L4 -> tile L5
     composite9 : DOWNSAMPLE tile L5 -> tile L6            (widest, 1/64 res)
     composite10: UPSAMPLE   U5 = L5 + tent(U6=L6)         (3x3 tent, in place)
     composite11: UPSAMPLE   U4 = L4 + tent(U5)
     composite12: UPSAMPLE   U3 = L3 + tent(U4)
     composite13: UPSAMPLE   U2 = L2 + tent(U3)
     composite14: COMBINE    U1 = L1 + tent(U2), add into scene (+ auto-exposure)

 Each downsample reads only the previous level; each upsample overwrites its own
 tile in place (reading its still-original L_k plus the already-upsampled coarser
 U_{k+1}). U1 is never stored — the combine pass folds the final tent+add straight
 into the scene. So U1 = L1 + tent(L2 + tent(L3 + ... )) is the full dual-filter
 pyramid: each tent is energy-preserving, so U1's energy ~ sum of the level
 energies (~AL_BLOOM_LEVELS x one level); the combine normalises by the level
 count to keep the added bloom energy-bounded and NaN-guarded.
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

/*
 Map a level-local UV (0..1 over the screen) into the atlas, clamped to a
 half-texel-inset sub-rectangle so bilinear taps never sample a neighbour tile
 (the sky-LUT-tile no-bleed pattern). `atlasTexel` = 1/buffer-resolution.

 This is the RECT-TAKING form. The tile rect is loop-invariant across the taps
 of a kernel — every tap of a 13-tap downsample or a 9-tap tent addresses the
 SAME source tile — but alBloomTileRect() costs two exp2() calls, so recomputing
 it per tap burned 26 exp2 per pixel in the downsample and 18 in the tent (and
 the tent runs for EVERY screen pixel in composite14). The kernels below hoist
 the rect out of the tap fan and pass it in here; the arithmetic is otherwise
 byte-for-byte the pre-hoist expression, so the sampled coordinates — and hence
 the filtered output — are unchanged.
*/
vec2 alBloomToAtlasRect(vec4 r, vec2 localUV, vec2 atlasTexel) {
    vec2 inset = atlasTexel * 0.5;
    vec2 lo = r.xy + inset;
    vec2 hi = r.zw - inset;
    return clamp(mix(r.xy, r.zw, alSaturate(localUV)), lo, hi);
}

// Level-taking convenience wrapper, for the handful of one-off taps that have no
// fan to hoist out of (composite14's single L1 fetch). Identical maths.
vec2 alBloomToAtlas(int L, vec2 localUV, vec2 atlasTexel) {
    return alBloomToAtlasRect(alBloomTileRect(L), localUV, atlasTexel);
}

/*
 Which tile does an atlas texel belong to? Returns the level (1..6) and writes
 the level-local UV; returns 0 when the texel is outside every tile.

 CLOSED FORM, not a search. Every one of the ~11 atlas passes calls this for
 every texel of colortex9, and the old version looped all AL_BLOOM_LEVELS levels
 doing 2 exp2() + 4 comparisons each — worst case (the dead atlas region, which
 is most of the buffer) paying the full 12 exp2 + 24 compares to learn "no tile".

 The layout makes the search unnecessary. Writing t = 1 - x (distance from the
 atlas's right edge), tile L's x-span [1-2^-(L-1), 1-2^-L) is exactly

     2^-L  <  t  <=  2^-(L-1)      <=>      L-1 <= -log2(t) < L

 so L = floor(-log2(t)) + 1 recovers the column DIRECTLY. That is sound because
 the x-columns are disjoint AND contiguous: they tile [0, 63/64) with no gap, so
 at most one level can ever pass the x-test and the formula names it. The y-test
 is then the only thing left to decide — and because only that one level could
 have matched, "L's y-test fails" is equivalent to "the old loop fell through all
 six levels", which is why a single y check replaces the other five iterations.

 Boundary/degenerate behaviour is preserved exactly:
   * x < 0                       -> outside; the old loop's `x >= r.x` failed too.
   * t <= 2^-6  (x >= 63/64)     -> the dead right margin, and the x = 1 case that
                                    would send log2 to -inf. Rejected up front.
   * NaN x or y -> the guards are written as POSITIVE comparisons, which NaN
                   fails, so we return 0 — exactly as every comparison in the old
                   loop failed on NaN.

 ONE FLOAT SUBTLETY, and the reason level 1 is not fed through the log at all:
 `1.0 - x` is EXACT only for x in [0.5, 2] (Sterbenz), which covers levels 2..6
 since their columns all start at x >= 1/2. Below 1/2 the subtraction can round,
 and at exactly x = 0.5 - 2^-25 (the last float under 1/2) it rounds 1-x UP to
 0.5, which the formula would read as level 2 for a level-1 texel. Level 1 is the
 whole left half by definition, so it is decided by a direct `x < 0.5` compare —
 cheaper than the log anyway, and exact by construction.

 The rect arithmetic below is also chosen to reproduce the loop bit-for-bit:
 tile width and height are both 2^-L, and (1-2^-L)-(1-2^-(L-1)) evaluates to
 exactly 2^-L in float for every L here, so dividing by invCur is the same
 division the loop did. max(2^-L, 1e-6) is a no-op for L <= 6, so it is dropped.
*/
int alBloomFromAtlas(vec2 atlasUV, out vec2 localUV) {
    localUV = vec2(0.0);

    // Positive test: a negative or NaN x leaves via this line, as it did before.
    if (!(atlasUV.x >= 0.0)) return 0;

    int L = 1;                                 // x < 0.5 => level 1, exactly
    if (atlasUV.x >= 0.5) {
        float t = 1.0 - atlasUV.x;             // exact for x >= 0.5, so t <= 0.5
        // t <= 2^-LEVELS is the dead right margin (and x == 1, where log2 -> -inf).
        if (!(t > exp2(-float(AL_BLOOM_LEVELS)))) return 0;
        // t in (2^-LEVELS, 0.5] pins -log2(t) into [1, LEVELS), so the clamp is
        // never active on real input; it is there so a driver log2() landing one
        // ULP the wrong side of a level boundary degrades to the neighbouring
        // (correct) tile instead of indexing a rect that does not exist.
        L = clamp(int(floor(-log2(t))) + 1, 2, AL_BLOOM_LEVELS);
    }

    float invCur = exp2(-float(L));            // 2^-L: tile width AND height
    if (!(atlasUV.y >= 0.0 && atlasUV.y < invCur)) return 0;

    float x0 = 1.0 - 2.0 * invCur;             // == 1 - 2^-(L-1), exactly
    localUV = vec2(atlasUV.x - x0, atlasUV.y) / invCur;
    return L;
}

/*
 13-tap dual-filter DOWNSAMPLE (Jimenez 2014, "Next Generation Post Processing
 in Call of Duty: Advanced Warfare"). Samples a 4x4 neighbourhood as one centre
 2x2 box plus four overlapping corner boxes; the centre box carries half the
 weight, killing the "fireflies" a naive box filter leaves. `d` is the sample
 step (one SOURCE texel, in source UV). `lod` is 0 in the real pyramid (the
 source is already the correct resolution — no hardware mips are used); the
 parameter is kept so composite4 can fan the full-res scene into tile L1.
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

/*
 Progressive DOWNSAMPLE of a tile ALREADY in the atlas (the real pyramid step:
 dest level = srcLevel + 1, built from srcLevel — never from colortex0/mips).
 Same 13-tap Jimenez fan as above, but every tap is mapped into the source tile
 with alBloomToAtlas() so the clamped inset stops any tap bleeding into a
 neighbour tile. `localUV` is 0..1 over the screen for the destination texel;
 `dLocal` is ONE source-tile texel expressed in source-tile-local UV.
*/
vec3 alBloomDownsampleTile(sampler2D atlas, int srcLevel, vec2 localUV,
                           vec2 dLocal, vec2 atlasTexel) {
    // All 13 taps address the SAME source tile, so its rect is loop-invariant:
    // compute it once (2 exp2) instead of once per tap (26 exp2). Same values.
    vec4 r = alBloomTileRect(srcLevel);

    vec3 a = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2(-2.0,-2.0), atlasTexel)).rgb;
    vec3 b = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 0.0,-2.0), atlasTexel)).rgb;
    vec3 c = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 2.0,-2.0), atlasTexel)).rgb;
    vec3 e = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2(-2.0, 0.0), atlasTexel)).rgb;
    vec3 f = texture(atlas, alBloomToAtlasRect(r, localUV,                          atlasTexel)).rgb;
    vec3 g = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 2.0, 0.0), atlasTexel)).rgb;
    vec3 h = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2(-2.0, 2.0), atlasTexel)).rgb;
    vec3 i = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 0.0, 2.0), atlasTexel)).rgb;
    vec3 j = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 2.0, 2.0), atlasTexel)).rgb;
    vec3 k = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2(-1.0,-1.0), atlasTexel)).rgb;
    vec3 l = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 1.0,-1.0), atlasTexel)).rgb;
    vec3 m = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2(-1.0, 1.0), atlasTexel)).rgb;
    vec3 n = texture(atlas, alBloomToAtlasRect(r, localUV + dLocal*vec2( 1.0, 1.0), atlasTexel)).rgb;

    vec3 sum  = (k + l + m + n) * 0.5;
    sum += (a + b + e + f) * 0.125;
    sum += (b + c + f + g) * 0.125;
    sum += (e + f + h + i) * 0.125;
    sum += (f + g + i + j) * 0.125;
    return sum * 0.25;
}

/*
 3x3 tent UPSAMPLE of a coarser tile already in the atlas (Jimenez dual-filter
 upsample, [1 2 1; 2 4 2; 1 2 1]/16). Reads the srcLevel tile (the coarser
 U_{L+1}) around `localUV`, each tap clamped into that tile. `sLocal` is the tap
 step in the source tile's local UV (one source texel * AL_BLOOM_TENT_RADIUS).
 The result is the smooth, wide contribution that the caller adds onto the next
 finer level to walk the pyramid back up.
*/
vec3 alBloomTentTile(sampler2D atlas, int srcLevel, vec2 localUV,
                     vec2 sLocal, vec2 atlasTexel) {
    // Rect hoisted out of the 9-tap fan: 2 exp2 per pixel instead of 18. This
    // one matters most — composite14 runs this tent for EVERY screen pixel.
    vec4 r = alBloomTileRect(srcLevel);

    vec3 sum = vec3(0.0);
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2(-1.0,-1.0), atlasTexel)).rgb * 1.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2( 0.0,-1.0), atlasTexel)).rgb * 2.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2( 1.0,-1.0), atlasTexel)).rgb * 1.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2(-1.0, 0.0), atlasTexel)).rgb * 2.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV,                          atlasTexel)).rgb * 4.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2( 1.0, 0.0), atlasTexel)).rgb * 2.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2(-1.0, 1.0), atlasTexel)).rgb * 1.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2( 0.0, 1.0), atlasTexel)).rgb * 2.0;
    sum += texture(atlas, alBloomToAtlasRect(r, localUV + sLocal*vec2( 1.0, 1.0), atlasTexel)).rgb * 1.0;
    return sum * (1.0 / 16.0);
}

// Guard a value about to be WRITTEN into the bloom atlas: reject NaN/negatives
// (comparisons fail on NaN) and bound HDR so one hot texel can't poison the tile
// the next pass samples. Used by every downsample/upsample pass.
vec3 alBloomGuard(vec3 v) {
    bool ok = (v.r >= 0.0) && (v.g >= 0.0) && (v.b >= 0.0);
    return ok ? min(v, vec3(60000.0)) : vec3(0.0);
}
// bound HDR so a single hot texel can't blow the sum). Comparisons reject NaN.
vec3 alBloomValidate(vec3 v) {
    bool ok = (v.r >= 0.0) && (v.g >= 0.0) && (v.b >= 0.0)
           && (v.r < 65000.0) && (v.g < 65000.0) && (v.b < 65000.0);
    return ok ? v : vec3(0.0);
}

#endif // AL_LIB_BLOOM
