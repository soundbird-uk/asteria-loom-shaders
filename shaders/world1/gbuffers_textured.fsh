#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_textured (fragment) — generic textured (non-lit) geometry into the
 G-buffer (leads/leashes, misc textured quads, item-frame maps/items when they
 fall back here). These render BEFORE the deferred pass, so writing the standard
 G-buffer (colortex1/2/3) is correct: deferred1's BASIC branch passes them through
 (sRGB->linear, unlit) into colortex0.

 (5.0.12: reverted the earlier colortex0 forward-write hack. Translucent block-
 entity layers — sign text, banner patterns — are now handled by the dedicated
 gbuffers_block_translucent program instead, which is the correct Iris routing.)

 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;     // colortex1
layout(location = 1) out vec4 outNormalLm;   // colortex2
layout(location = 2) out vec4 outMaterial;   // colortex3

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_BASIC),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
