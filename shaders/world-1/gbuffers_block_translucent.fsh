#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"

/*
 gbuffers_block_translucent (fragment) — FORWARD-LIT translucent block-entity
 layers (sign TEXT glyphs, banner PATTERN layers, translucent decals), blended
 into colortex0 with the shared lighting model so they match the opaque block
 entities shaded in the deferred pass.

 This is the fix for "banners appear white / sign text doesn't show": those layers
 are TRANSLUCENT block-entity draws. Without this program they fell back to the
 opaque gbuffers_block and were alpha-tested away (leaving a banner's white base
 cloth and no glyphs). Here they blend properly.

 Alpha handling: keep every non-(near-)zero-alpha texel (a tiny 0.004 cutoff only
 drops fully transparent pixels), so anti-aliased glyph edges and soft pattern
 borders survive instead of being cut by a high alphaTestRef.

 Sampler count: gtexture + shadow samplers via lib/shadow.glsl (<=4).
*/

uniform sampler2D gtexture;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
in vec3 playerPos;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // texture * glcolor carries the banner DYE colour / sign text colour, so a
    // banner pattern tints correctly (the fix for "banners are white": the pattern
    // mask is greyscale and MUST be multiplied by the per-layer dye in glcolor).
    vec4 tex = texture(gtexture, texcoord) * glcolor;
    if (tex.a < 0.004) discard;   // keep soft edges; drop only fully transparent

    vec3 albedoLin = alSrgbToLinear(tex.rgb);

    vec3 Ng = normalize(wnormal);
    vec3 wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3 wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    float NdotL = max(dot(Ng, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, Ng, NdotL);

    vec3 color = alLightPhase1(albedoLin, Ng, lmcoord, shadowVis, wLightDir, wSunDir,
                               playerPos + cameraPosition, dayFactor);

    outColor = vec4(color, tex.a);
}
