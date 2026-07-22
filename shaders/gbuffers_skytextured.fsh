#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"

/*
 gbuffers_skytextured (fragment) — sun/moon discs, blended over the gradient
 into colortex0. We give them a modest HDR boost (SUNMOON_BRIGHTNESS) so the
 disc reads through the tonemap and can bloom in later phases.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;

in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 c = texture(gtexture, texcoord) * glcolor;
    c.rgb = alSrgbToLinear(c.rgb) * SUNMOON_BRIGHTNESS;
    outColor = c;   // alpha preserved; Iris blends this over the sky gradient
}
