#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"

/*
 gbuffers_clouds (fragment) — vanilla clouds blended into colortex0.
 The pass is normally disabled when VANILLA_CLOUDS is off (see
 shaders.properties); the internal guard keeps the program valid and correct
 even if it is dispatched.
 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
#ifndef VANILLA_CLOUDS
    discard;
#else
    vec4 c = texture(gtexture, texcoord) * glcolor;
    if (c.a < alphaTestRef) discard;

    // Keep vanilla's baked shading (in glcolor); just move to linear HDR and
    // let the sky lightmap gently tint brightness.
    c.rgb = alSrgbToLinear(c.rgb) * (0.7 + 0.3 * lmcoord.y);
    outColor = c;
#endif
}
