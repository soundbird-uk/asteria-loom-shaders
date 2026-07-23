#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"

/*
 gbuffers_weather (fragment) — rain/snow, blended faintly into colortex0.
 Lit only by the sky lightmap (cheap, stable) and deliberately kept subtle.
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
    vec4 tex = texture(gtexture, texcoord) * glcolor;
    if (tex.a < alphaTestRef) discard;

    vec3 col = alSrgbToLinear(tex.rgb);
    // Sky-lightmap lit so precipitation dims underground / at night.
    col *= (0.25 + 0.75 * lmcoord.y);

    // Keep it faint.
    outColor = vec4(col, tex.a * 0.5);
}
