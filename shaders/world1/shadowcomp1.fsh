#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/voxel.glsl"

/*
 shadowcomp1 (fragment) — FLOOD-FILL STEP 2 of 2.

 Reads : shadowcolor0 — this frame's emitter/occupancy map
         shadowcolor2 — the half-propagated field from shadowcomp
 Writes: shadowcolor1 — THE field. Persistent (`shadowcolor1Clear = false`),
                        read by next frame's shadowcomp and by deferred1.

 Identical maths to shadowcomp with ONE difference: no reprojection. The field it
 reads was written this frame, in this frame's grid, so the voxel shift is zero.
 See shadowcomp.fsh for the ping-pong rationale, the occlusion model and the
 reprojection derivation — this file deliberately does not repeat them.

 WHY ONLY TWO STEPS PER FRAME. Each step moves light one voxel, and the field
 PERSISTS, so the two steps compound across frames: a source fills its 15-block
 vanilla reach in about 8 frames (~0.13 s at 60 fps) and thereafter simply tracks
 the world. Adding a third pass would buy a barely-perceptible convergence
 improvement in exchange for another full shadow-buffer-sized target and another
 million-texel gather every frame. It is not a good trade, and the field is a HUE
 — being an eighth of a second late to a torch being placed is invisible.

 Sampler count: 2 (shadowcolor0, shadowcolor2).
*/

uniform sampler2D shadowcolor0;   // rgb = block albedo (sRGB), a = occupancy+level
uniform sampler2D shadowcolor2;   // rgb = the half-propagated field

/* RENDERTARGETS: 1 */
layout(location = 0) out vec3 outField;

void main() {
    ivec2 t = ivec2(gl_FragCoord.xy);

    ivec3 v;
    if (!alVoxelFromTexel(t, v)) discard;   // outside the atlas: not ours

    vec4  occ   = texelFetch(shadowcolor0, t, 0);
    float level = alVoxelLevel(occ.a);

    if (level > 0.0) {                      // source: holds its own emission
        outField = alVoxelEmission(occ.rgb, level);
        return;
    }
    if (alVoxelIsSolid(occ.a)) {            // blocker: holds nothing
        outField = vec3(0.0);
        return;
    }
    outField = alVoxelPropagate(shadowcolor2, v, ivec3(0));
}
