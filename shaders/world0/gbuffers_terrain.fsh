#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_terrain (fragment) — writes the opaque G-buffer.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
flat in float emissive;   // 1.0 for light-emitting blocks (block.properties 10040)

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;    // colortex1
layout(location = 1) out vec4 outNormalLm;  // colortex2
layout(location = 2) out vec4 outMaterial;  // colortex3

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;   // cutout foliage etc.

    // Light sources tag matID EMISSIVE so deferred1 self-illuminates them from
    // this same albedo (their own texture colour) -> coloured glow + bloom halo.
    int matID = (emissive > 0.5) ? AL_MATID_EMISSIVE : AL_MATID_TERRAIN;

    outAlbedo   = vec4(albedo.rgb, 1.0);                       // a = AO spare
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);      // rg normal, ba lightmap
    outMaterial = vec4(alEncodeMatID(matID),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
