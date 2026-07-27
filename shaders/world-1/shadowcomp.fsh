#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/voxel.glsl"

/*
 shadowcomp (fragment) — FLOOD-FILL STEP 1 of 2, with reprojection.

 Reads : shadowcolor0 — this frame's emitter/occupancy map (written by the splats
                        in shadow.gsh/shadow.fsh)
         shadowcolor1 — LAST frame's finished light field
 Writes: shadowcolor2 — the half-propagated field, consumed by shadowcomp1

 =========================================================================
 WHY PING-PONG ACROSS TWO BUFFERS INSTEAD OF ONE
 -------------------------------------------------------------------------
 The obvious arrangement — one persistent field that each pass reads and writes
 — relies on Iris flipping a shadowcolor buffer's main/alt pair between
 shadow-composite programs, exactly as it does for colortexN between composites.
 That is very probably what it does, but "probably" is not a basis for a
 read-after-write hazard: if it does not flip, a pass would be reading the texels
 it is concurrently writing, which is undefined and would look like noise on some
 drivers and be fine on others.

 So NO program here reads and writes the same buffer. shadowcomp goes 1 -> 2 and
 shadowcomp1 goes 2 -> 1, which is correct under every flip semantics:
   * Iris flips between passes  -> each pass sees the previous pass's output.
   * Iris does not flip at all  -> each pass sees the previous pass's output.
   * Iris flips only at the end -> shadowcomp1 reads a one-frame-old
                                   shadowcolor2, i.e. the field converges one
                                   step slower. Invisible, never wrong.
 The cost is one extra shadow-buffer-sized RGB float target; the benefit is that
 this cannot be subtly broken by a detail we cannot test on CI.

 =========================================================================
 REPROJECTION
 -------------------------------------------------------------------------
 The grid origin is snapped to floor(cameraPosition), so between two frames it
 moves by exactly floor(cameraPosition) - floor(previousCameraPosition) blocks —
 an INTEGER voxel shift. Re-indexing by that shift is lossless: the field
 translates with the player without a single resample, so it neither smears nor
 blurs as you walk. Voxels shifted in from outside the old grid read as black and
 refill from their neighbours over the next few frames.

 Only THIS pass reprojects. shadowcomp1 reads a field written this frame in this
 same grid, so its shift is zero.

 Sampler count: 2 (shadowcolor0, shadowcolor1).
*/

uniform sampler2D shadowcolor0;   // rgb = block albedo (sRGB), a = occupancy+level
uniform sampler2D shadowcolor1;   // rgb = last frame's finished light field

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

/* RENDERTARGETS: 2 */
layout(location = 0) out vec3 outField;

void main() {
    ivec2 t = ivec2(gl_FragCoord.xy);

    // The atlas is a 2048x512 strip of a much larger buffer. Everything outside
    // it is shadow-map territory that nothing in the voxel path ever reads, so
    // discarding is both cheapest and safest — it leaves those texels alone
    // instead of stamping zeroes over a region another feature might one day want.
    ivec3 v;
    if (!alVoxelFromTexel(t, v)) discard;

    vec4  occ   = texelFetch(shadowcolor0, t, 0);
    float level = alVoxelLevel(occ.a);

    // --- Source ------------------------------------------------------------
    // An emitter IS the boundary condition: it holds its own emission and does
    // not gather. (It is also solid, so light cannot pass through it — a torch
    // in a wall does not illuminate the far side.)
    if (level > 0.0) {
        outField = alVoxelEmission(occ.rgb, level);
        return;
    }

    // --- Blocker -----------------------------------------------------------
    // A solid, non-emitting voxel holds no light. That single fact IS the
    // occlusion model: a neighbour gathering from it gets zero, so light cannot
    // cross a wall. No separate mask to fall out of sync with the storage.
    if (alVoxelIsSolid(occ.a)) {
        outField = vec3(0.0);
        return;
    }

    // --- Air: one diffusion step over the reprojected previous field --------
    ivec3 reproj = ivec3(floor(cameraPosition) - floor(previousCameraPosition));
    outField = alVoxelPropagate(shadowcolor1, v, reproj);
}
