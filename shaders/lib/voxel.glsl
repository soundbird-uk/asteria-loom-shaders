#ifndef AL_LIB_VOXEL
#define AL_LIB_VOXEL

/*
 lib/voxel.glsl — FLOOD-FILL COLOURED VOXEL BLOCK LIGHT (5.5.0): the address
 space, the shadow-buffer sub-region split, and every encode/decode the voxel
 path uses. Pure math + sampler-PARAMETER helpers; this file declares NO
 uniforms and NO samplers of its own, so it can be included by the shadow VERTEX
 stage (which must not gain samplers), by lib/shadow.glsl, by the shadowcomp
 propagation passes and by deferred1 without any of them leaking state into the
 others. Callers hand their sampler in as an argument (the same trick
 lib/contact.glsl uses for depthtex0).

 =========================================================================
 WHY A VOXEL FIELD AT ALL
 -------------------------------------------------------------------------
 The 5.4.0 `deferred2` gather answers "what colour is the block light here?"
 by looking at the emitters that are ON SCREEN. That is cheap and it is
 occlusion-safe (see the invariant below), but it is blind to the two cases
 that matter most in a cave: a torch just behind the camera, and a torch round
 the corner. This pass answers the same question from a real 3D field that is
 flood-filled through AIR and stopped by SOLID blocks, so light genuinely turns
 corners and genuinely arrives from off screen.

 THE INVARIANT — unchanged, and it is the whole safety argument:
   The voxel field supplies HUE (and, through the confidence ramp, a bounded
   boost) ONLY. The INTENSITY of block light still comes exclusively from the
   vanilla `lm.x` lightmap, because lm.x is produced by the game's own flood
   fill and is therefore already exactly occlusion-correct. A pixel on the far
   side of a wall has lm.x == 0, so its block-light term is zero no matter what
   colour this field hands it. Do NOT be tempted to add the field's magnitude as
   light: this field is a 1-metre-resolution diffusion approximation and using
   it as radiance would leak through 1-block walls the moment the diffusion
   rounds a corner it should not have.

 =========================================================================
 WHERE THE DATA LIVES — AND WHY THE SHADOW MAP IS SQUEEZED
 -------------------------------------------------------------------------
 Voxelisation is a SCATTER: shadow.gsh takes each shadow-casting triangle and
 emits, alongside the real shadow triangle, a one-texel splat at that block's
 flattened voxel address. There is exactly one framebuffer available to the
 shadow pass, and a splat is a rasterised primitive, so it writes the shared
 DEPTH attachment whether we want it to or not:

   * make the splat's depth FAR and it loses the depth test everywhere real
     geometry already drew — which is almost everywhere, so almost all voxel
     data is lost;
   * make it NEAR and it wins, storing a bogus near-plane occluder in the
     shadow map at that texel — an isolated hard black speck that every PCF
     disc passing over it darkens.

 "Splat survives" and "shadow depth untouched" are therefore contradictory in a
 shared framebuffer. The only resolution is SPATIAL: give the atlas texels of
 its own that no shadow lookup ever samples. So the shadow map is squeezed into
 the square sub-region [0, side)^2 of the shadow buffer and the voxel atlas
 takes the top strip:

     +-----------------------------+  y = shadowMapResolution
     |  VOXEL ATLAS  2048 x 512    |
     +--------------------+--------+  y = side = shadowMapResolution - 512
     |                    |        |
     |   SHADOW MAP       | unused |
     |   side x side      |        |
     +--------------------+--------+  y = 0
     x = 0              side    res

 The squeeze is a SINGLE uniform scale applied in exactly three places
 (lib/shadow.glsl: the two texture() call sites + the logical texel size, and
 shadow.vsh: the rendered NDC). Everything else in lib/shadow.glsl — the bounds
 test, the PCSS blocker search, every bias and radius — keeps working in
 "logical" [0,1] shadow-map UV and is byte-for-byte unchanged. And when
 VOXEL_LIGHT is OFF the scale is the literal constant 1.0 and the offset 0, so
 the shadow path compiles to exactly the code that shipped. That containment is
 deliberate: lib/shadow.glsl has broken two releases and this feature must not
 be able to break a third for anyone who never turns it on.

 GRACEFUL DEGRADATION vs shadowMapResolution. The atlas is a fixed 2048x512
 address space (it is an address space, not a quality dial), so it only fits a
 shadow buffer 2048 wide or more. At 2048 the shadow map keeps 1536^2 (75% per
 axis); at 3072, 2560^2 (83%). Below 2048 the right-hand tiles fall off the edge
 of the buffer and those splats are clipped away by the rasteriser: the field is
 partially populated, confidence drops, and lib/lighting.glsl falls back to the
 screen-space gather / the warm ramp. Nothing breaks — it just does less. That
 is why POTATO (1024) and LOW (1536) ship with VOXEL_LIGHT off rather than
 needing a hard guard the GLSL preprocessor could not express anyway
 (shadowMapResolution is a `const int`, not a macro, so `#if` cannot see it).

 =========================================================================
 ADDRESS SPACE
 -------------------------------------------------------------------------
 128 x 64 x 128 voxels = +/-64 blocks horizontally, +/-32 vertically, one voxel
 per block. Flattened as 64 Y-slices, each a contiguous 128x128 tile (X across,
 Z down), tiled 16 across x 4 down => exactly 2048 x 512 texels = 1,048,576,
 one per voxel, no waste and no collisions.

     tile index  = vy                (0..63)
     tile column = vy % 16 , row = vy / 16
     atlas texel = (col*128 + vx , row*128 + vz)

 Y IS THE TILE INDEX, which matters: because every voxel owns a distinct texel
 there is no "one block per voxel column" depth race to resolve. The splat depth
 is instead used as a PRIORITY (brighter emitter = nearer depth = wins), so when
 several faces of the same block splat to the same texel the brightest wins
 deterministically instead of whichever triangle happened to be last.

 The grid origin is snapped to floor(cameraPosition), so it moves in whole
 blocks and the field never smears; between frames the propagation pass
 reprojects by floor(cameraPosition) - floor(previousCameraPosition).

 All grid-space maths is done RELATIVE to the camera (playerPos + fract(camera))
 so nothing ever depends on the absolute world coordinate — at x = 3,000,000 a
 float has ~0.25-block precision and an absolute-coordinate floor() would
 quantise the whole grid into garbage.
*/

#include "/lib/common.glsl"
// sRGB->linear only. lib/color.glsl is pure math with no samplers and no
// uniforms, so pulling it in here keeps this file safe for the shadow vertex
// stage (which must not gain either).
#include "/lib/color.glsl"

// --- Grid extent -----------------------------------------------------------
#define AL_VOXEL_SIZE_X 128
#define AL_VOXEL_SIZE_Y 64
#define AL_VOXEL_SIZE_Z 128

// Atlas tiling: 64 tiles of 128x128 laid out 16 across, 4 down.
#define AL_VOXEL_TILE_COLS 16
#define AL_VOXEL_ATLAS_W  2048          // AL_VOXEL_TILE_COLS * AL_VOXEL_SIZE_X
#define AL_VOXEL_ATLAS_H   512          // (64 / 16)          * AL_VOXEL_SIZE_Z

// Half extents (the grid is centred on the camera's block).
const vec3  AL_VOXEL_HALF  = vec3(64.0, 32.0, 64.0);
const ivec3 AL_VOXEL_SIZE  = ivec3(AL_VOXEL_SIZE_X, AL_VOXEL_SIZE_Y, AL_VOXEL_SIZE_Z);

/* ---------------------------------------------------------------------------
   THE SHADOW-BUFFER SPLIT
   ---------------------------------------------------------------------------
   AL_SHADOW_MAP_SIDE   — side of the square the shadow map is rendered into.
   AL_SHADOW_MAP_SCALE  — that side as a fraction of the buffer. The ONE number
                          lib/shadow.glsl and shadow.vsh multiply by.
   AL_VOXEL_ATLAS_Y0    — first buffer row belonging to the voxel atlas.

   With VOXEL_LIGHT off these are exactly `shadowMapResolution` and `1.0`, i.e.
   the pre-5.5.0 behaviour, and every multiply folds away at compile time.
   --------------------------------------------------------------------------- */
#ifdef VOXEL_LIGHT
    #define AL_SHADOW_MAP_SIDE  (shadowMapResolution - AL_VOXEL_ATLAS_H)
    #define AL_VOXEL_ATLAS_Y0   (shadowMapResolution - AL_VOXEL_ATLAS_H)
#else
    #define AL_SHADOW_MAP_SIDE  shadowMapResolution
    #define AL_VOXEL_ATLAS_Y0   shadowMapResolution
#endif

// Fraction of the buffer the shadow map occupies, per axis.
float alShadowMapScale() {
    return float(AL_SHADOW_MAP_SIDE) / float(shadowMapResolution);
}

/*
 Logical shadow-map UV ([0,1] over the shadow map, which is what ALL of
 lib/shadow.glsl works in) -> physical UV in the shadow buffer.

 The clamp is not decoration. lib/shadow.glsl only bounds-checks the CENTRE of
 the PCF disc, so individual taps legitimately stray a little outside [0,1]. On
 the unsqueezed buffer the sampler's clamp-to-edge absorbed that; on the
 squeezed buffer an unclamped tap would wander into the atlas strip and read a
 splat's priority depth as if it were an occluder. Clamping in LOGICAL space
 before the scale reproduces the old clamp-to-edge behaviour exactly.
*/
vec2 alShadowMapUV(vec2 logicalUV) {
#ifdef VOXEL_LIGHT
    return clamp(logicalUV, vec2(0.0), vec2(1.0)) * alShadowMapScale();
#else
    return logicalUV;   // identity: byte-for-byte the pre-5.5.0 lookup
#endif
}

/* ---------------------------------------------------------------------------
   GRID SPACE
   --------------------------------------------------------------------------- */

/*
 Camera-relative (player/feet) position -> continuous grid coordinates, where
 [0,128) x [0,64) x [0,128) is inside the grid.

   world  = playerPos + cameraPosition
   origin = floor(cameraPosition) - HALF
   grid   = world - origin = playerPos + fract(cameraPosition) + HALF

 The fract() is what keeps this precision-safe at extreme world coordinates:
 no absolute world coordinate is ever floor()ed.
*/
vec3 alVoxelGridPos(vec3 playerPos, vec3 cameraPos) {
    return playerPos + fract(cameraPos) + AL_VOXEL_HALF;
}

// Is this integer voxel index inside the grid?
bool alVoxelInside(ivec3 v) {
    return all(greaterThanEqual(v, ivec3(0))) && all(lessThan(v, AL_VOXEL_SIZE));
}

// Voxel index -> texel in the shadow buffer (absolute pixel coordinates).
// Caller must have checked alVoxelInside().
ivec2 alVoxelTexel(ivec3 v) {
    int col = v.y % AL_VOXEL_TILE_COLS;
    int row = v.y / AL_VOXEL_TILE_COLS;
    return ivec2(col * AL_VOXEL_SIZE_X + v.x,
                 AL_VOXEL_ATLAS_Y0 + row * AL_VOXEL_SIZE_Z + v.z);
}

// Inverse: a shadow-buffer texel inside the atlas -> its voxel index.
// Returns false when the texel is not part of the atlas at all.
bool alVoxelFromTexel(ivec2 t, out ivec3 v) {
    ivec2 a = t - ivec2(0, AL_VOXEL_ATLAS_Y0);
    if (a.x < 0 || a.x >= AL_VOXEL_ATLAS_W || a.y < 0 || a.y >= AL_VOXEL_ATLAS_H) {
        v = ivec3(0);
        return false;
    }
    int col = a.x / AL_VOXEL_SIZE_X;
    int row = a.y / AL_VOXEL_SIZE_Z;
    v = ivec3(a.x - col * AL_VOXEL_SIZE_X,
              row * AL_VOXEL_TILE_COLS + col,
              a.y - row * AL_VOXEL_SIZE_Z);
    return true;
}

/* ---------------------------------------------------------------------------
   EMITTER / OCCUPANCY MAP  (shadowcolor0, RGBA8, cleared every frame)
   ---------------------------------------------------------------------------
   rgb = the block's own albedo (as sampled from gtexture, sRGB as stored)
   a   = (1 + lightLevel) / 32, i.e. a BAND of [0.031 .. 0.500]:
           0.03125 = SOLID, not a light source            (1 + 0) / 32
           .. 0.5  = SOLID and emitting at level 1..15    (1 + L) / 32
         anything OUTSIDE that band is EMPTY (air, or out of shadow range).

   WHY A BAND AND NOT JUST "> 0" — this is deliberate, not paranoia. This buffer
   must be re-cleared every frame or a broken torch would haunt the grid forever,
   but the pack cannot pin down what Iris clears a SHADOW colour buffer to:
   OptiFine's shadowcolor convention is opaque WHITE (1,1,1,1) because the buffer
   was invented for coloured/translucent shadows, while an ordinary colortex
   clears to transparent black. Read as "a > 0" a white clear would declare every
   voxel in the world SOLID and EMITTING AT LEVEL 15 — a spectacular failure. By
   living in the lower half of the range, BOTH plausible clear values (0.0 and
   1.0) fall outside the band and read as EMPTY, so the pass is correct under
   either convention without depending on a directive we cannot verify from CI.

   Encoding occupancy and emission in one channel is what lets the propagation
   pass decide "source / blocker / air" from a single fetch. RGBA8 is UNORM so
   the hardware clamps it: this channel can never carry a NaN into the field,
   which satisfies the pack's NaN law structurally rather than by test.
   --------------------------------------------------------------------------- */
float alVoxelEncodeOccupancy(float level15) {
    return (1.0 + clamp(level15, 0.0, 15.0)) * (1.0 / 32.0);
}
// True when the texel holds a block at all. Both ends of the test are positive
// comparisons, so a NaN (impossible on UNORM, but this is the standing law)
// answers "empty" rather than "an emitter of unknown strength".
bool  alVoxelIsSolid(float a)  { return (a > 0.02) && (a < 0.53); }
// Light level 0..15 (0 for a solid non-emitter). Rounded: 1/32 is not exactly
// representable in 8 bits, so the raw decode lands within +/-0.07 of an integer.
float alVoxelLevel(float a) {
    return clamp(floor(a * 32.0 - 0.5), 0.0, 15.0);
}

/* ---------------------------------------------------------------------------
   THE FIELD  (shadowcolor1 / shadowcolor2, R11F_G11F_B10F, PERSISTENT)
   ---------------------------------------------------------------------------
   rgb = the diffused coloured light in this voxel. No alpha: solidity is read
   fresh from shadowcolor0 every pass, so storing it here would only be a
   one-frame-stale duplicate.

   NaN LAW. Both field buffers are declared `clear = false` (final.fsh), so
   their first-frame contents are undefined driver garbage, and each pass feeds
   itself from the previous one — a single poisoned texel would otherwise spread
   through the whole grid like the light does. EVERY read goes through
   alVoxelValidate(), which is a POSITIVE range comparison (NaN fails it) with a
   black fallback. Black is the correct fallback here as well as the safe one:
   lib/lighting.glsl reads black as "nothing found" and returns the warm ramp.

   THE CEILING IS TIGHT ON PURPOSE. Elsewhere in the pack the range test uses a
   token 65000 because the quantity really can be arbitrarily large HDR radiance.
   Here it cannot: the brightest thing the field can hold is a level-15 emitter at
   AL_VOXEL_EMIT, and an air voxel is a weighted AVERAGE of its neighbours scaled
   by AL_VOXEL_SPREAD < 1, so it is strictly below that. Anything above 1.5x the
   emitter constant is therefore provably not something this pass wrote, i.e. it
   is first-frame garbage, and rejecting it outright stops that garbage seeding
   the diffusion. (In-range garbage still gets through and simply decays, at
   ~3.5% per step, which is the honest limit of what a validated read can do.)
   --------------------------------------------------------------------------- */
#define AL_VOXEL_MAX (AL_VOXEL_EMIT * 1.5)

vec3 alVoxelValidate(vec3 c) {
    bool ok = (c.r >= 0.0) && (c.r < AL_VOXEL_MAX)
           && (c.g >= 0.0) && (c.g < AL_VOXEL_MAX)
           && (c.b >= 0.0) && (c.b < AL_VOXEL_MAX);
    return ok ? c : vec3(0.0);
}

/*
 Read the field at a voxel index. `field` is shadowcolor1 or shadowcolor2.
 texelFetch (not texture) on purpose: the atlas is a packed address space, so a
 filtered read would blend across a TILE seam, i.e. across a 64-block jump in Y.
 Out of grid -> black, which is also what an unlit voxel reads as, so the grid
 boundary behaves like darkness rather than like a mirror.
*/
vec3 alVoxelFetchField(sampler2D field, ivec3 v) {
    if (!alVoxelInside(v)) return vec3(0.0);
    return alVoxelValidate(texelFetch(field, alVoxelTexel(v), 0).rgb);
}

/*
 What an emitter voxel INJECTS into the field.

   emitSrgb : the block's albedo exactly as shadowcolor0 stores it
   level15  : its light level, 1..15

 The albedo is normalised to UNIT PEAK before it is scaled by the level, which is
 the whole point of this function existing rather than being two lines inline.
 Physically, how much light a lantern puts out has nothing to do with how dark
 the metal housing in its texture is — the level is the output, the texture is
 only the colour. Without the normalisation a source whose splat happened to land
 on a dark texel (a lantern's frame, a campfire's log, the unlit half of a
 redstone torch) would inject almost nothing and simply vanish from the field.
 It also pins the field's magnitude: the brightest value any voxel can hold is
 exactly AL_VOXEL_EMIT, which is what makes both AL_VOXEL_MAX above and
 AL_VOXEL_GATHER_GAIN in settings.glsl calibratable rather than guessed.

 A source whose colour is genuinely black (no texture data at all) falls back to
 white: a light with no discernible hue should read as neutral, not as no light.
*/
vec3 alVoxelEmission(vec3 emitSrgb, float level15) {
    vec3  lin  = alSrgbToLinear(alSaturate(emitSrgb));
    float peak = max(lin.r, max(lin.g, lin.b));
    vec3  hue  = (peak > 0.02) ? lin / peak : vec3(1.0);
    return hue * (pow(clamp(level15, 0.0, 15.0) * (1.0 / 15.0), AL_VOXEL_EMIT_POW)
                  * AL_VOXEL_EMIT);
}

/*
 ONE FLOOD-FILL STEP for the air voxel `v`, gathering from `field`.

 `reproj` is the integer voxel shift between the grid `field` was written in and
 the grid we are writing now: floor(cameraPosition) - floor(previousCameraPosition).
 The grid origin is snapped to whole blocks precisely so that this is an exact
 integer re-index and the field never smears or resamples as the player walks.
 Pass ivec3(0) when reading a field written this frame in this same grid.

 THE OCCLUSION MODEL, and why it needs no explicit mask:
   * an EMITTER voxel is written as its own emission and never gathers,
   * a non-emitting SOLID voxel is written as black and never gathers,
   * an AIR voxel is the average of its neighbours, scaled by AL_VOXEL_SPREAD.
 A solid voxel therefore holds no light, so a neighbour reading it gets zero:
 the wall blocks the light because it has nothing to give, not because a special
 case says so. That is one less place for the mask and the storage to disagree.

 Weighting: face taps 1, edge-diagonals 1/sqrt(2), corner-diagonals 1/sqrt(3),
 normalised by the weights actually taken. Taps outside the grid contribute 0 but
 DO count toward the normalisation, so the grid boundary behaves like darkness
 (correct) rather than like a mirror (which is what excluding them would do).
 The 3x3x3 loop is written out in full and filtered by tier so the compiler
 unrolls it into exactly the 6 / 18 / 26 taps the quality level asks for.
*/
vec3 alVoxelPropagate(sampler2D field, ivec3 v, ivec3 reproj) {
    vec3  sum  = vec3(0.0);
    float wsum = 0.0;
    for (int dz = -1; dz <= 1; ++dz) {
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int manhattan = abs(dx) + abs(dy) + abs(dz);
                if (manhattan == 0) continue;                    // self
#if VOXEL_LIGHT_QUALITY == 1
                if (manhattan != 1) continue;                    // faces only
#elif VOXEL_LIGHT_QUALITY == 2
                if (manhattan > 2) continue;                     // + edges
#endif
                float w = (manhattan == 1) ? 1.0
                        : ((manhattan == 2) ? 0.70710678 : 0.57735027);
                sum  += alVoxelFetchField(field, v + ivec3(dx, dy, dz) + reproj) * w;
                wsum += w;
            }
        }
    }
    return sum * (AL_VOXEL_SPREAD / max(wsum, 1e-4));
}

/*
 CONSUMER-SIDE SAMPLE (deferred1).

 gridPos is continuous grid coordinates for the point being shaded, already
 pushed off the surface along its normal (a surface's OWN voxel is solid and by
 construction holds no light — reading it would return black everywhere).

 Filtering: BILINEAR within the Y-slice tile, NEAREST in Y. The X/Z interpolation
 is free (one `texture()` fetch) and turns what would be visibly blocky 1-metre
 hue steps into a smooth field; it is safe because a tile is 128x128 contiguous
 texels. The sample position is clamped to stay half a texel inside the tile so
 the hardware's 2x2 footprint can never straddle the tile border and blend in a
 different Y-slice. Y stays nearest for exactly that reason — neighbouring Y
 slices are not neighbouring texels.

 NB whether the interpolation actually happens depends on the filter Iris gives a
 shadowcolor buffer, which the pack does not pin down. Both outcomes are correct:
 with LINEAR the field reads smooth, with NEAREST it reads as 1-metre hue steps.
 It is a hue behind an occlusion-correct intensity either way, so this is a
 quality difference and never a correctness one. The propagation passes are
 immune regardless — they use texelFetch, which ignores filtering entirely.
*/
vec3 alVoxelSampleField(sampler2D field, vec3 gridPos) {
    ivec3 vi = ivec3(floor(gridPos));
    if (!alVoxelInside(vi)) return vec3(0.0);

    // Position within the Y-slice tile, in tile-local texel coordinates, kept
    // half a texel inside the tile edges (see above).
    vec2 inTile = clamp(vec2(gridPos.x, gridPos.z),
                        vec2(0.5), vec2(float(AL_VOXEL_SIZE_X) - 0.5,
                                        float(AL_VOXEL_SIZE_Z) - 0.5));

    int col = vi.y % AL_VOXEL_TILE_COLS;
    int row = vi.y / AL_VOXEL_TILE_COLS;
    vec2 px = vec2(float(col * AL_VOXEL_SIZE_X) + inTile.x,
                   float(AL_VOXEL_ATLAS_Y0 + row * AL_VOXEL_SIZE_Z) + inTile.y);

    vec2 uv = px / float(shadowMapResolution);
    return alVoxelValidate(texture(field, uv).rgb);
}

#endif // AL_LIB_VOXEL
