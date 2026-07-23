#version 330 compatibility
#include "/settings.glsl"

/*
 shadow (fragment) — depth ONLY. We sample gtexture solely to honour cutout
 alpha (so leaves/grass cast correctly shaped shadows), then either discard or
 let the fragment through so its depth is recorded. We deliberately declare NO
 colour output: writing one would force Iris to allocate shadowcolor0 (Phase 2
 territory). The shadow map stores depth.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec4 glcolor;

/* No RENDERTARGETS and no colour output: shadow pass writes depth only. */

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;   // cutout -> casts no shadow here
    // No colour written; the depth buffer is the shadow map.
}
