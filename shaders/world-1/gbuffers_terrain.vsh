#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"
#ifdef AL_WAVING_FOLIAGE
#include "/lib/wind.glsl"
#endif

/*
 gbuffers_terrain (vertex) — opaque solid/cutout terrain.
 Writes the G-buffer only; no lighting here (deferred does that).
 mc_Entity discriminates block IDs mapped in block.properties: water aside,
 10010 = grass/plants and 10020 = leaves drive the foliage wind (lib/wind.glsl).
*/

uniform mat4 gbufferModelViewInverse;
#ifdef AL_WAVING_FOLIAGE
uniform vec3  cameraPosition;    // world-space camera (wind phase in world XZ)
uniform float frameTimeCounter;  // animation time
#endif

/* ---- at_midBlock, and why its type is conditional -------------------------
 Iris' `at_midBlock` is normally a vec3 (the offset from this vertex to the
 block's centre, in 1/64-block units) — that is what the foliage wind uses to
 anchor plant bases. When the pack opts into the BLOCK_EMISSION_ATTRIBUTE
 feature flag (`iris.features.optional` in shaders.properties) Iris widens the
 SAME attribute to a vec4 whose `.w` carries the block's emission, i.e. its
 light level 0..15. That is exactly the signal COLORED_BLOCKLIGHT wants: the
 emitter's own strength, straight from the game, with no guessing from texture
 brightness.

 The two forms are mutually exclusive — declaring both is a redeclaration error
 — so the type is chosen once here and every consumer reads `.xyz` / `.y`, which
 is valid for either. Iris defines IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE only
 when the running version actually supports it; older Iris (and OptiFine) fall
 through to the vec3 form and the fragment stage derives emission from albedo
 luminance instead (see gbuffers_terrain.fsh). `optional` (not `required`) means
 an Iris build that has never heard of the flag still loads the pack.
--------------------------------------------------------------------------- */
#if defined COLORED_BLOCKLIGHT && defined IRIS_FEATURE_BLOCK_EMISSION_ATTRIBUTE
    #define AL_MIDBLOCK_EMISSION
#endif
#if defined AL_WAVING_FOLIAGE || defined AL_MIDBLOCK_EMISSION
  #ifdef AL_MIDBLOCK_EMISSION
in vec4 at_midBlock;             // .xyz block-centre offset, .w light level 0..15
  #else
in vec3 at_midBlock;             // Iris: block-centre offset (1/64 block units)
  #endif
#endif

in vec4 mc_Entity;   // (blockId, renderType, ...) — foliage IDs from block.properties

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
flat out float emissive;   // 1.0 for light-emitting blocks (block.properties 10040)
flat out float emitLevel;  // emitter light level 0..1 (0 = derive in the fsh)
flat out float endFrame;   // 1.0 for end_portal_frame (10041) — eye-only glow
flat out float reflAmt;    // reflectivity 0..1 (block.properties 10050/10051)
flat out float metalness;  // 1.0 = metal (albedo-tinted reflection)

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

    // Emissive classification (self-illuminating light sources). Independent of
    // the foliage wind; the fragment stage tags matID EMISSIVE so deferred1 adds
    // the glow from the block's own texture colour.
    emissive = (mc_Entity.x == 10040.0) ? 1.0 : 0.0;
    endFrame = (mc_Entity.x == 10041.0) ? 1.0 : 0.0;   // eye-only glow (fsh masks)

    // Emitter STRENGTH for the coloured-block-light gather (colortex3.g). Only
    // meaningful on emissive blocks; everything else stores 0 so the gather can
    // reject it with a single compare. Left at 0 when the attribute is
    // unavailable — the fragment stage then derives it from albedo luminance,
    // which is the same mask deferred1 already uses for self-illumination.
    emitLevel = 0.0;
#ifdef AL_MIDBLOCK_EMISSION
    if (emissive > 0.5) emitLevel = clamp(at_midBlock.w * (1.0 / 15.0), 0.0, 1.0);
#endif

    // Reflective-material classification (block.properties 10050 glassy, 10051
    // metal). The fragment stage stores reflAmt in colortex3.b and metalness in .a
    // so the composite SSR pass can reflect these solid blocks material-dependently.
    reflAmt = 0.0; metalness = 0.0;
    if (mc_Entity.x == 10050.0)      { reflAmt = AL_REFLECT_ICE;   metalness = 0.0; }
    else if (mc_Entity.x == 10051.0) { reflAmt = AL_REFLECT_METAL; metalness = 1.0; }

#ifdef AL_WAVING_FOLIAGE
    // --- Foliage wind (ISSUE 5) ------------------------------------------------
    // Classify by the block ID mapped in block.properties, build the world-space
    // sway (lib/wind.glsl), and add it to the VIEW position before projection.
    float isGrass = (mc_Entity.x == 10010.0) ? 1.0 : 0.0;
    float isLeaf  = (mc_Entity.x == 10020.0) ? 1.0 : 0.0;
    float amount  = isGrass * AL_WIND_GRASS + isLeaf * AL_WIND_LEAF;
    if (amount > 0.0) {
        vec3 worldPos = (gbufferModelViewInverse * viewPos).xyz + cameraPosition;
        // Top weight from at_midBlock.y: a vertex ABOVE the block centre has a
        // negative offset -> topW ~1 (free top sways); a base vertex -> topW 0
        // (anchored). Leaves flutter uniformly, so they use full weight.
        float topW = (isLeaf > 0.5)
                   ? 1.0
                   : alSaturate(-at_midBlock.y * (1.0 / 32.0));
        vec3 disp = alFoliageSway(worldPos, frameTimeCounter * AL_WIND_SPEED,
                                  amount, topW, isLeaf);
        // World-direction -> view: modelview inverse is orthonormal, so the
        // world->view rotation is its transpose (no extra uniform needed).
        viewPos.xyz += transpose(mat3(gbufferModelViewInverse)) * disp;
    }
#endif

    gl_Position = gl_ProjectionMatrix * viewPos;   // == ftransform() when undisplaced
    gl_Position = alJitter(gl_Position);            // TAA sub-pixel jitter — LAST write

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;   // atlas uv
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;   // lightmap 0..1
    glcolor  = gl_Color;                                       // vertex colour (+vanilla AO)

    // Normal to world space: view normal via gl_NormalMatrix, then rotate to
    // world with the modelview inverse (rotation part only).
    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
}
