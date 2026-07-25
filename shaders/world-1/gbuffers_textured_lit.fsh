#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_textured_lit (fragment) — generic lit-textured into the G-buffer.
 Terrain's fallback, so it tags matID terrain. Block entities and entity parts
 land here whenever the dedicated programs are skipped in the Iris fallback
 chain, so it uses the SAME split alpha test as gbuffers_entities: the cutout
 mask is the TEXTURE alpha (Iris' alphaTestRef), and gl_Color's alpha — a
 per-draw modulator, not a mask — may only drop a fragment when it leaves
 literally no coverage. (5.4: a heavy-handed combined test here was one of the
 two paths that could delete an opaque signboard while its text survived.)
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
    vec4 tex    = texture(gtexture, texcoord);
    if (tex.a < alphaTestRef) discard;        // cutout mask: TEXTURE alpha only

    vec4 albedo = tex * glcolor;
    if (albedo.a <= 0.0) discard;             // no coverage at all

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_TERRAIN),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
