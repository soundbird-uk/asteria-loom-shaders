#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_basic (fragment) — untextured primitives into the G-buffer: the block
 SELECTION OUTLINE, hitboxes, leash/fishing lines, world border.
 Albedo is the vertex colour; a fixed up-normal keeps deferred shading sane.

 ISSUE 16 ("block selection outline missing"): the vanilla outline vertex colour
 is near-BLACK (~0,0,0), so after deferred pass-through + AgX tonemap it read as
 invisible dark lines — the box appeared to be gone. We detect the OUTLINE render
 stage and emit a bright, crisp near-white line instead, tagged AL_MATID_BASIC so
 (a) deferred1 passes it through UNSHADED, (b) composite2 skips FOG on it, and
 (c) composite3 gives it the low TAA blend (no ghosting) — so the outline stays a
 legible interaction affordance at close range regardless of fog/lighting/TAA.
 It is still depth-tested by Minecraft against the block, as expected.

 Sampler count: 0
*/

uniform int renderStage;

in vec2 lmcoord;
in vec4 glcolor;

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLm;
layout(location = 2) out vec4 outMaterial;

void main() {
    vec3 albedo = glcolor.rgb;

    // Selection box: force a bright, clearly-visible outline colour.
    if (renderStage == MC_RENDER_STAGE_OUTLINE) {
        albedo = vec3(0.96);
    }

    outAlbedo   = vec4(albedo, 1.0);
    outNormalLm = vec4(alEncodeNormal(vec3(0.0, 1.0, 0.0)), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_BASIC),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
