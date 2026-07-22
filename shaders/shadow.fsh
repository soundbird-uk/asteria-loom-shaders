#version 330 compatibility
#include "/settings.glsl"

/*
 shadow (fragment) — depth only. We sample gtexture solely to honour cutout
 alpha (so leaves/grass cast correctly shaped shadows). No colour is written;
 the shadow map stores depth.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec4 glcolor;

/* No RENDERTARGETS: shadow pass writes depth only. */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;   // cutout -> no shadow here
    outColor = albedo;                       // colour is ignored; depth is what matters
}
