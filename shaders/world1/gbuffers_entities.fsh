#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_entities (fragment) — writes the opaque G-buffer for entities.
 entityColor is Iris' hurt-flash / spawner-egg / potion tint; mix it into
 albedo per the Iris convention.

 ALPHA TEST (5.4 field bug: "signboard invisible, sign text floating in mid-air"):
 the cutout mask of a texture-atlas draw lives in the TEXTURE's alpha channel.
 gl_Color's alpha is a per-draw MODULATOR (entity fade-out, block-entity /
 render-layer tint, the dye alpha on a banner layer), and it is NOT a cutout
 mask. Testing `texture.a * glcolor.a < alphaTestRef` therefore deletes fully
 OPAQUE geometry the moment a draw arrives with a low vertex alpha — exactly the
 signboard case: the wooden backing is one such draw and vanished wholesale,
 while the text glyphs (a different, translucent layer handled by
 gbuffers_block_translucent) kept rendering and were left hanging in mid-air.

 So the two jobs are separated, with no magic thresholds:
   1. CUTOUT — test the TEXTURE alpha against Iris' own alphaTestRef. This is the
      vanilla cutout semantic and is what carves holes out of an atlas sprite.
   2. FULLY TRANSPARENT — drop the fragment only when the modulated result has
      NO coverage at all (a == 0), which is the one case where writing an opaque
      G-buffer texel would be wrong.
 Anything with real coverage now reaches the G-buffer, so opaque/cutout entity
 and block-entity parts can no longer be discarded by a test meant for
 translucent layers.

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
    vec4 tex    = texture(gtexture, texcoord);
    if (tex.a < alphaTestRef) discard;        // cutout mask: TEXTURE alpha only

    vec4 albedo = tex * glcolor;
    if (albedo.a <= 0.0) discard;             // no coverage at all

    albedo.rgb = mix(albedo.rgb, entityColor.rgb, entityColor.a);

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_ENTITY),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
