#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"

/*
 gbuffers_hand_water (fragment) — translucent held items, forward-lit and
 blended into colortex0 with the shared lighting model.
 Sampler count: 2 (gtexture, shadowtex1[SHADOWS])
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform mat4 gbufferModelViewInverse;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
in vec3 playerPos;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex = texture(gtexture, texcoord) * glcolor;

    vec3 albedoLin = alSrgbToLinear(tex.rgb);
    float alpha = tex.a;

    vec3 N = normalize(wnormal);
    vec3 wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3 wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    float NdotL = max(dot(N, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, N, NdotL);

    vec3 color = alLightPhase1(albedoLin, N, lmcoord, shadowVis, wLightDir, dayFactor);

    outColor = vec4(color, alpha);
}
