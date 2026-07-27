#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/voxel.glsl"

/*
 shadow (fragment) — the shadow map's depth, PLUS the voxel emitter/occupancy
 map (5.5.0).

 Two kinds of fragment arrive here, told apart by gSplatLevel from shadow.gsh:

   gSplatLevel < 0   an ordinary shadow-map fragment. Sample gtexture solely to
                     honour cutout alpha (so leaves/grass cast correctly shaped
                     shadows), then either discard or let it through so its depth
                     is recorded. Exactly the pre-5.5.0 behaviour.

   gSplatLevel >= 0  a one-texel VOXEL SPLAT (see shadow.gsh). It writes the
                     block's own colour and its light level into shadowcolor0 at
                     the flattened voxel address, and takes NO alpha test: the
                     splat is a data write, not a shadow, and discarding it would
                     lose a torch just because the texel that happened to be
                     under the centroid uv was transparent.

 WHY THERE IS NOW A COLOUR OUTPUT AT ALL (it used to be deliberately absent).
 shadowcolor0 is written UNCONDITIONALLY, even with VOXEL_LIGHT off, when it
 writes nothing but zeroes. The alternative — wrapping the `out` and the
 RENDERTARGETS directive in `#ifdef VOXEL_LIGHT` — makes correctness depend on
 whether Iris evaluates preprocessor branches before it scans the source text
 for the RENDERTARGETS comment, which is not something this pack can verify from
 CI. An unconditional RGBA8 write on the shadow pass is a small, known,
 measurable cost; a directive/output mismatch is an unknown that would only
 surface on the user's machine. We take the known one.

 Sampler count: 1 (gtexture).
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2  gTexcoord;
in vec4  gGlcolor;
flat in float gSplatLevel;   // <0 = shadow fragment, >=0 = voxel splat level 0..15

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outVoxel;   // -> shadowcolor0 (emitter/occupancy)

void main() {
    vec4 tex = texture(gtexture, gTexcoord);

#ifdef VOXEL_LIGHT
    // Positive comparison so a poisoned varying takes the ordinary-shadow branch
    // rather than being splatted into the light grid.
    if (gSplatLevel >= 0.0) {
        // rgb: the block's own texture colour, stored AS SAMPLED (sRGB). The
        // propagation pass converts to linear once, on injection, rather than
        // every consumer having to remember to.
        // a  : occupancy + level in one channel, in a band that both plausible
        //      shadow-buffer clear values fall outside of — see lib/voxel.glsl.
        outVoxel = vec4(tex.rgb, alVoxelEncodeOccupancy(gSplatLevel));
        return;
    }
#endif

    vec4 albedo = tex * gGlcolor;
    if (albedo.a < alphaTestRef) discard;   // cutout -> casts no shadow here
    // Depth is the shadow map. The colour write is zero: this fragment is inside
    // the shadow-map sub-region, which the voxel path never reads.
    outVoxel = vec4(0.0);
}
