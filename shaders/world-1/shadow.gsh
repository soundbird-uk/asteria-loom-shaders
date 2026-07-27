#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/voxel.glsl"

/*
 shadow (geometry) — DUAL EMIT: the real shadow triangle, plus a one-texel splat
 that voxelises the block into the light grid.

 =========================================================================
 WHY A GEOMETRY SHADER AT ALL
 -------------------------------------------------------------------------
 Voxelisation is a SCATTER — "write this block's colour at the address derived
 from its position" — and on macOS GL 4.1 there is no compute, no SSBO and no
 image load/store to scatter with. The one remaining scatter primitive is the
 rasteriser itself: put a primitive where you want the write to land. A geometry
 shader is the only stage that can emit a primitive at an address unrelated to
 the input geometry, and it is core GL 3.2, so it is available on the Mac path.

 The SHADOW pass is the right host because it is the only pass that draws
 geometry the camera cannot see. Everything within shadowDistance is submitted
 to it — behind the player, round the corner, inside the cave they are walking
 toward — which is exactly the set of emitters the screen-space gather in
 deferred2 structurally cannot find.

 =========================================================================
 WHAT IT EMITS
 -------------------------------------------------------------------------
   (a) The input triangle, verbatim. gl_Position already carries the distortion
       warp AND the sub-region squeeze from shadow.vsh; this stage does not
       touch shadow maths at all, it only forwards it. That is deliberate: the
       shadow map must be bit-identical to what the vertex stage decided.

   (b) A screen-aligned QUAD covering exactly the one atlas texel that this
       block's voxel owns. A quad rather than a `points` primitive because a
       geometry shader has ONE output primitive type and (a) needs triangles;
       four vertices of a triangle_strip laid on the texel's exact pixel
       boundaries rasterise to precisely one fragment (the only pixel CENTRE
       inside the quad), which is what a point splat would have done anyway.
       3 + 4 = 7 vertices, hence max_vertices = 7.

 DEPTH ON THE SPLAT IS A PRIORITY, NOT A POSITION. Every voxel owns a distinct
 texel (Y is the atlas tile index — see lib/voxel.glsl), so there is no "one
 block per voxel column" race to resolve with depth. Instead the splat's depth
 is set from the emitter's light level, brightest = nearest, so when the several
 faces of one block all splat to the same texel the depth test resolves them
 DETERMINISTICALLY in favour of the brightest reading rather than whichever
 triangle the driver happened to submit last.

 The splat writes the shared depth attachment, which is exactly why the shadow
 map is squeezed out of the atlas strip: nothing that lib/shadow.glsl ever
 samples lives in the rows the splats land in. See lib/voxel.glsl for the full
 argument, including why a "separate shadowcolor buffer, depth untouched"
 arrangement cannot work.

 =========================================================================
 WITH VOXEL_LIGHT OFF
 -------------------------------------------------------------------------
 This file still exists — Iris compiles every stage file a pack ships and there
 is no way to conditionally omit one — but it compiles down to a PURE
 PASS-THROUGH: forward the three input vertices unchanged and emit nothing else.
 The geometry stage itself cannot be removed from the pipeline, which is a real
 (small) cost on every shadow draw and is noted in settings.glsl; but no shadow
 VALUE changes, because the triangle it emits is the one the vertex stage built.

 This program declares no samplers (geometry stage; the fragment stage does the
 one gtexture read).
*/

layout(triangles) in;
layout(triangle_strip, max_vertices = 7) out;

in vec2  texcoord[];
in vec4  glcolor[];
#ifdef VOXEL_LIGHT
in vec3  vxBlockGrid[];
in float vxLevel[];
#endif

out vec2  gTexcoord;
out vec4  gGlcolor;
// < 0  => an ordinary shadow-map fragment (do the cutout alpha test).
// >= 0 => a voxel splat carrying that block's light level 0..15.
flat out float gSplatLevel;

void main() {
    // ---- (a) the real shadow triangle, untouched -------------------------
    gSplatLevel = -1.0;
    for (int i = 0; i < 3; ++i) {
        gl_Position = gl_in[i].gl_Position;
        gTexcoord   = texcoord[i];
        gGlcolor    = glcolor[i];
        EmitVertex();
    }
    EndPrimitive();

#ifdef VOXEL_LIGHT
    // ---- (b) the voxel splat ---------------------------------------------
    // vxLevel < 0 marks a primitive the vertex stage decided must not be
    // voxelised (foliage — see shadow.vsh). NaN-safe by construction: this is a
    // positive comparison, so a poisoned varying takes the "skip" branch.
    if (!(vxLevel[0] >= 0.0)) return;

    ivec3 v = ivec3(floor(vxBlockGrid[0]));
    if (!alVoxelInside(v)) return;          // outside the +/-64 / +/-32 grid

    ivec2 t = alVoxelTexel(v);
    float res = float(shadowMapResolution);
    // Pixel BOUNDARIES -> NDC. Using the boundaries (t and t+1) rather than the
    // centre is what makes the quad cover exactly one pixel centre: the only
    // sample point strictly inside [t, t+1)^2 is (t + 0.5).
    vec2 p0 = (vec2(t)             / res) * 2.0 - 1.0;
    vec2 p1 = (vec2(t + ivec2(1))  / res) * 2.0 - 1.0;

    // Priority depth (see the header). level 15 -> 0.05, level 0 -> 0.50, mapped
    // into NDC z. Comfortably inside [-1,1] so the splat is never depth-clipped,
    // and comfortably away from both ends so it cannot collide with the cleared
    // far plane under either GL_LESS or GL_LEQUAL.
    float d = 0.5 - 0.45 * (clamp(vxLevel[0], 0.0, 15.0) * (1.0 / 15.0));
    float z = d * 2.0 - 1.0;

    gSplatLevel = clamp(vxLevel[0], 0.0, 15.0);
    // The splat's fragment samples gtexture to recover the block's own colour.
    // Use the triangle CENTROID uv, not a vertex uv: a vertex sits on the corner
    // of the face's texture tile, which for anything with a border or an
    // irregular sprite is the least representative texel on it.
    gTexcoord = (texcoord[0] + texcoord[1] + texcoord[2]) * (1.0 / 3.0);
    gGlcolor  = glcolor[0];

    // Counter-clockwise as seen in NDC, so the quad survives back-face culling
    // whatever the shadow pass has set. A 4-vertex triangle_strip is two
    // triangles; GL flips the winding of the second for us, so both faces agree.
    gl_Position = vec4(p0.x, p0.y, z, 1.0); EmitVertex();
    gl_Position = vec4(p1.x, p0.y, z, 1.0); EmitVertex();
    gl_Position = vec4(p0.x, p1.y, z, 1.0); EmitVertex();
    gl_Position = vec4(p1.x, p1.y, z, 1.0); EmitVertex();
    EndPrimitive();
#endif
}
