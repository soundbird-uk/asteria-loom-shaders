#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_textured (fragment) — generic textured (non-lit) into the G-buffer.

 OVERLAY render types fall back here: item-frame items/maps, sign text glyphs and
 banner patterns. Those are drawn in the TRANSLUCENT / overlay phase, AFTER
 deferred1 has already lit the opaque G-buffer — so writing ONLY the G-buffer
 (colortex1/2/3) leaves them never composited into the scene and they VANISH
 (field report: "item frames, sign text, banners don't show up"). Fix: ALSO
 forward-write the colour to colortex0 so they appear regardless of phase. The
 G-buffer writes remain for any pre-deferred use — deferred1's BASIC branch
 re-derives an identical pass-through there, so nothing changes in that case.
 `blend.gbuffers_textured.1/2/3 = off` (shaders.properties) keeps the aux writes
 authoritative when the overlay is alpha-blended (colortex0 keeps blending).

 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;

/* RENDERTARGETS: 0,1,2,3 */
layout(location = 0) out vec4 outColorFwd;   // colortex0 — forward (survives post-deferred)
layout(location = 1) out vec4 outAlbedo;     // colortex1
layout(location = 2) out vec4 outNormalLm;   // colortex2
layout(location = 3) out vec4 outMaterial;   // colortex3

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;

    outColorFwd = vec4(alSrgbToLinear(albedo.rgb), albedo.a);   // unlit, matches deferred1 BASIC
    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_BASIC),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
