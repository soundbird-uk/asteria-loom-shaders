#version 460 compatibility

/*
 final (COMPUTE stage) — histogram auto-exposure METERING. ADVANCED build only.

 WHY THIS SLOT. Iris runs a composite-style pass's compute stage FIRST, before
 that pass's vertex/fragment ("In composite-style passes, compute shaders will
 always execute first"), and `final` lists compute as an optional stage. So this
 file runs after every composite — including composite14, the last one — and
 immediately before final.fsh, which is the one and only consumer of the adapted
 exposure. That is exactly the slot the metering wants, and it needs no new pass.

 A compute-ONLY `composite15.csh` was the obvious alternative and is deliberately
 NOT what this is: Iris documents composite passes as REQUIRING a vertex and a
 fragment stage, so a composite slot holding nothing but a `.csh` is not
 guaranteed to be dispatched at all — and the failure would be silent (the pack
 loads, the exposure just never comes from the histogram). Padding the slot with
 a dummy fragment is worse still: a fragment program's RENDERTARGETS list makes
 Iris FLIP those buffers whether or not the shader writes anything, so a dummy
 pass on colortex5 would swap in the stale alt copy and take the AO history and
 the exposure slot with it. Attaching to `final` avoids the whole question.

 WHY IT IS IN THE OVERLAY AND NOT IN shaders/: Iris compiles EVERY `.csh` a pack
 ships, unconditionally, and macOS (OpenGL 4.1) cannot compile compute shaders at
 all — one `.csh` under shaders/ makes the whole pack fail to load on the Mac.
 So this file exists only in the ADVANCED overlay, and the Advanced zip declares
 `iris.features.required = COMPUTE_SHADERS` (shaders.properties.append) so an
 incapable machine is turned away with a capability message instead of a compile
 failure. The Mac path keeps composite14's mip-average metering, untouched.

 This is a NEW file, not a replacement: `shaders/world*/final.vsh` and
 `final.fsh` are untouched and still the only things that draw.

 WHAT IT REPLACES, WHAT IT PRESERVES, AND WHY IT CANNOT DOUBLE-INTEGRATE: all
 documented at length in lib/advanced/exposure_histogram.glsl, which holds the
 implementation. Short version — it replaces the METERING (a mean of the frame,
 which one bright sky or a single torch dominates) with a trimmed mean of a
 log-luminance HISTOGRAM (which they cannot), and it keeps the adaptation
 contract exactly: same asymmetric AL_EXPOSURE_MIN/MAX/STRENGTH clamp so dark
 nights are never lifted, same AL_EXPOSURE_TAU integrator, same [0.2,5.0]
 guards, same output slot colortex5.a texel (0,0) that final.fsh reads. Its own
 previous-exposure state lives in colortex5.a texel (1,0), so composite14's
 still-running fragment metering can neither feed this loop nor be seen on
 screen.

 The body lives in a shared include because world0/world1/world-1 must meter
 IDENTICALLY; three copies of this file would drift silently and the Nether
 would quietly expose differently from the Overworld.

 Dispatch: exactly ONE 16x16 workgroup (256 invocations, 16384 stratified
 samples). One workgroup is what makes the whole-frame reduction expressible in
 shared memory + barrier(), with no SSBO and no second pass — see
 lib/advanced/settings_advanced.glsl.

 Bindings: 1 sampler (colortex0) + 1 image (colorimg5). No render targets, so no
 RENDERTARGETS directive: a compute program cannot write colour attachments
 directly and reaches colortex5 through imageStore instead.
*/

// Tunables first: the dispatch shape below is declared from them, and Iris reads
// `workGroups` out of this file's text, so both stay visible right here rather
// than hiding inside the implementation include.
#include "/lib/advanced/settings_advanced.glsl"

layout(local_size_x = AL_EXPO_GROUP_X, local_size_y = AL_EXPO_GROUP_Y) in;

// ONE workgroup, absolute. NOT workGroupsRender, which is relative to the render
// resolution and is also what Iris DEFAULTS to (vec2(1.0,1.0)) if no work-group
// count is declared — that default would dispatch this whole-frame reduction
// once per screen-sized tile, i.e. thousands of workgroups all racing to write
// the same two texels. The sample count here is fixed by the histogram's
// statistics, not by the framebuffer size.
const ivec3 workGroups = ivec3(1, 1, 1);

#include "/lib/advanced/exposure_histogram.glsl"

void main() {
    alExposureHistogramMain();
}
