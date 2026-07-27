#version 330 compatibility
#include "/settings.glsl"

/*
 shadow (vertex) — depth-only render from the sun/moon's point of view.

 Phase 2 applies the distortion WARP here so the rendered shadow map is stored
 pre-distorted, concentrating texels near the camera (see lib/shadow.glsl for
 the exact formula + derivation). The SAME alShadowDistort() is used by every
 lookup in lib/shadow.glsl, so the map and the samples always agree.

 5.5.0 adds TWO things, both compiled away entirely when VOXEL_LIGHT is off:

  1. THE SQUEEZE. When VOXEL_LIGHT reserves a strip of the shadow buffer for the
     voxel atlas, the rendered shadow map is scaled into the square sub-region
     [0, side)^2 (lib/voxel.glsl explains why the atlas cannot share texels with
     the map). It is a single uniform scale on the already-warped NDC, and
     alShadowMapUV() in lib/shadow.glsl applies the identical scale to every
     lookup, so map and samples still agree exactly. With VOXEL_LIGHT off
     alShadowMapScale() is the literal 1.0 and the line folds away.

  2. VOXELISATION FEED. shadow.gsh needs, per triangle, the grid-space position
     of the BLOCK the triangle belongs to and that block's light level. Both are
     computed here, because the vertex stage is where at_midBlock and mc_Entity
     live, and passed on as varyings.

 We include lib/shadow.glsl only for the warp function; `AL_SHADOW_VSH` is
 defined first so the shadow-reading sampler block (shadowtex*, noisetex, ...)
 is NOT pulled into the shadow pass, which writes depth and reads none of them.
 lib/voxel.glsl (pulled in by lib/shadow.glsl) is sampler-free by design, so it
 is safe here for the same reason.

 texcoord/glcolor are forwarded purely so the fragment stage can cutout-alpha.
*/

#define AL_SHADOW_VSH
#include "/lib/shadow.glsl"
#ifdef AL_WAVING_FOLIAGE
#include "/lib/wind.glsl"
#endif

/* ---- at_midBlock, and why its type is conditional -------------------------
 Same rule as gbuffers_terrain.vsh. Iris' `at_midBlock` is a vec3 (the offset
 from this vertex to the block's centre, in 1/64-block units) unless the pack
 opts into BLOCK_EMISSION_ATTRIBUTE, which widens the SAME attribute to a vec4
 whose .w carries the block's light level 0..15. The two forms are mutually
 exclusive — declaring both is a redeclaration error — so the type is chosen
 once here and everything reads `.xyz` / `.y`, which is valid for either.

 Without the attribute we cannot know a source's real strength, so an emissive
 block falls back to level 14 (torch / lantern / glowstone territory, i.e. the
 common case) rather than being dropped. That only affects how strongly one
 emitter outweighs another in the diffusion, never whether light appears at all.
--------------------------------------------------------------------------- */
#if defined VOXEL_LIGHT && defined IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE
    #define AL_MIDBLOCK_EMISSION
#endif
#if defined AL_WAVING_FOLIAGE || defined VOXEL_LIGHT
  #ifdef AL_MIDBLOCK_EMISSION
in vec4 at_midBlock;             // .xyz block-centre offset, .w light level 0..15
  #else
in vec3 at_midBlock;             // Iris: block-centre offset (1/64 block units)
  #endif
in vec4 mc_Entity;               // (blockId, ...) — IDs from block.properties
uniform mat4  shadowModelViewInverse;  // shadow-view -> world (feet)
uniform vec3  cameraPosition;
#endif
#ifdef AL_WAVING_FOLIAGE
uniform float frameTimeCounter;
#endif

out vec2 texcoord;
out vec4 glcolor;
#ifdef VOXEL_LIGHT
// Grid-space position of the BLOCK this vertex belongs to (the vertex pushed to
// the block centre by at_midBlock), and that block's light level 0..15 — or -1
// meaning "do not voxelise this primitive". Every vertex of a block face
// resolves to the same block centre, so shadow.gsh may read whichever it likes.
out vec3  vxBlockGrid;
out float vxLevel;
#endif

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;   // shadow-view space

#ifdef VOXEL_LIGHT
    // --- Voxelisation feed -------------------------------------------------
    // Taken from the UNDISPLACED position: a swaying grass blade must not drag a
    // voxel around with it, and the block it belongs to has not moved. playerPos
    // is camera-relative, so alVoxelGridPos() never floor()s an absolute world
    // coordinate — see the precision note in lib/voxel.glsl.
    vec3 vxPlayerPos = (shadowModelViewInverse * viewPos).xyz;
    vxBlockGrid = alVoxelGridPos(vxPlayerPos, cameraPosition)
                + at_midBlock.xyz * (1.0 / 64.0);

    // FOLIAGE IS NOT A BLOCKER. Grass and leaves cast cutout shadows, but light
    // passes through them in vanilla's flood fill, so voxelising them would seal
    // a forest canopy into an opaque dome and starve everything beneath it. IDs
    // from block.properties (10010 grass/plants, 10020 leaves).
    bool vxSkip = (mc_Entity.x == 10010.0) || (mc_Entity.x == 10020.0);
    // Light sources (block.properties 10040) — the SAME tag gbuffers_terrain
    // uses for matID EMISSIVE, so the two paths can never disagree about what
    // counts as a light.
    bool vxEmit = (mc_Entity.x == 10040.0);
  #ifdef AL_MIDBLOCK_EMISSION
    float vxRawLevel = vxEmit ? clamp(at_midBlock.w, 0.0, 15.0) : 0.0;
  #else
    float vxRawLevel = vxEmit ? 14.0 : 0.0;   // see the at_midBlock note above
  #endif
    vxLevel = vxSkip ? -1.0 : vxRawLevel;
#endif

#ifdef AL_WAVING_FOLIAGE
    // Wave foliage in the shadow map with the SAME world-space displacement the
    // gbuffers pass uses, so grass/leaf shadows track the moving geometry (no
    // base flicker from a static shadow under a swaying blade).
    float isGrass = (mc_Entity.x == 10010.0) ? 1.0 : 0.0;
    float isLeaf  = (mc_Entity.x == 10020.0) ? 1.0 : 0.0;
    float amount  = isGrass * AL_WIND_GRASS + isLeaf * AL_WIND_LEAF;
    if (amount > 0.0) {
        vec3 worldPos = (shadowModelViewInverse * viewPos).xyz + cameraPosition;
        float topW = (isLeaf > 0.5)
                   ? 1.0
                   : alSaturate(-at_midBlock.y * (1.0 / 32.0));
        vec3 disp = alFoliageSway(worldPos, frameTimeCounter * AL_WIND_SPEED,
                                  amount, topW, isLeaf);
        viewPos.xyz += transpose(mat3(shadowModelViewInverse)) * disp;
    }
#endif

    vec4 pos = gl_ProjectionMatrix * viewPos;   // shadow clip space
    // Distort in NDC (perspective-divide-safe; shadow ortho has w == 1).
    pos.xyz /= pos.w;
    pos.xyz  = alShadowDistort(pos.xyz);
#ifdef VOXEL_LIGHT
    // THE SQUEEZE. NDC [-1,1] -> the sub-square the shadow map now owns, anchored
    // at the buffer's origin corner so it is a plain scale about (-1,-1):
    //     uv_physical = uv_logical * S    <=>    ndc' = (ndc + 1) * S - 1
    // which is precisely what alShadowMapUV() re-applies on every lookup. Depth
    // (z) is untouched, so the map's depth range and every bias in
    // lib/shadow.glsl are unaffected by the split.
    pos.xy = (pos.xy + 1.0) * alShadowMapScale() - 1.0;
#endif
    pos.xyz *= pos.w;
    gl_Position = pos;

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    glcolor  = gl_Color;
}
