#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_entities (vertex) — mobs, items, armour stands, item frames, ...
 Standard opaque G-buffer vertex path (no mc_Entity needed here).

 NO GLOBAL VERTEX DISPLACEMENT (5.4, ISSUE "item frames vanish a moment after
 they are placed"). This program deliberately applies NOTHING to the vertex
 position except the projection and the TAA jitter:
   * the foliage wind (lib/wind.glsl) is driven by mc_Entity and is included
     ONLY by gbuffers_terrain / shadow — never here;
   * the TAA jitter is a pure sub-pixel offset in clip X/Y that leaves Z
     untouched, and every other program (terrain included) receives the exact
     SAME offset for the frame, so it cannot change a depth comparison.
 Any future displacement added here MUST skip the flat, flush entities tagged
 10060 in entity.properties (item frames, glow item frames, paintings): they sit
 flat against a block face, so even a fraction of a millimetre of displacement
 into the wall pushes them behind the opaque depth the terrain pass already
 wrote, and they vanish. `isFlushDecal` below is that permanent exemption flag.

 DEPTH PRIORITY FOR FLUSH DECALS. Those same entities are (near-)COPLANAR with
 the block face they hang on. Coplanar geometry drawn AFTER the terrain loses a
 GL_LESS depth test on every texel where the two depths quantise to the same
 value, which is precisely "the frame is there when placed, then vanishes".
 The fix is a depth-only bias with NO magic screen-space offset: the view-space
 position is scaled about the CAMERA by (1 - AL_DECAL_DEPTH_BIAS), i.e. the
 vertex slides along its own view ray toward the eye. A uniform scale about the
 origin of view space projects to the IDENTICAL screen position (x/z and y/z are
 unchanged), so nothing moves, shifts or shimmers on screen — only the depth
 value changes, and only in the direction that makes the decal win its tie
 against the wall behind it. Being RELATIVE to eye distance, the bias tracks the
 depth buffer's own hyperbolic precision instead of assuming a fixed epsilon:
 see AL_DECAL_DEPTH_BIAS in settings.glsl for the derivation.
*/

uniform mat4 gbufferModelViewInverse;

// Iris: the current entity's entity.properties ID. 65535 when the entity is not
// listed there, and 0 when the pack ships no entity.properties at all — so only
// an EXPLICIT match against our own tag may be treated as meaningful.
uniform int entityId;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;

void main() {
    // Flat entities mounted flush against a block face (entity.properties
    // 10060: item_frame, glow_item_frame, painting).
    bool isFlushDecal = (entityId == 10060);

    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

    // Displacement exemption + depth priority (see header). No displacement is
    // applied to ANY entity here; the decal branch only biases depth.
    if (isFlushDecal) {
        viewPos.xyz *= (1.0 - AL_DECAL_DEPTH_BIAS);
    }

    gl_Position = gl_ProjectionMatrix * viewPos;   // == ftransform() undisplaced
    gl_Position = alJitter(gl_Position);   // TAA sub-pixel jitter — LAST gl_Position write
    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
}
