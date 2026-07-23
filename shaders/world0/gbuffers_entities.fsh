#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_entities (fragment) — writes the opaque G-buffer for entities.
 entityColor is Iris' hurt-flash / spawner-egg / potion tint; mix it into
 albedo per the Iris convention.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec4 entityColor;   // .rgb tint, .a mix amount

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

    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_ENTITY),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
