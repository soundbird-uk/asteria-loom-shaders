#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_hand (fragment) — held item into the opaque G-buffer.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLm;
layout(location = 2) out vec4 outMaterial;

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_HAND),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
