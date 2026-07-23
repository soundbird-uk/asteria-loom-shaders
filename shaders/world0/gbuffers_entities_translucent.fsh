#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"

/*
 gbuffers_entities_translucent (fragment) — FORWARD-LIT translucent entities,
 blended into colortex0 with the shared lighting model so they match the
 opaque entities shaded in the deferred pass. entityColor (hurt flash etc.)
 is mixed in per the Iris convention.
 Sampler count: gtexture + shadow samplers via lib/shadow.glsl (SHADOWS):
   Mac fallback = 3 (gtexture, shadowtex1, noisetex);
   hardware-flag = 4 (gtexture, shadowtex0, shadowtex1HW, noisetex). <=4 budget.
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec4 entityColor;
uniform vec3 sunPosition;
uniform vec3 shadowLightPosition;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;       // world-space camera (for cloud shadow)

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
in vec3 playerPos;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex = texture(gtexture, texcoord) * glcolor;
    if (tex.a < alphaTestRef) discard;

    tex.rgb = mix(tex.rgb, entityColor.rgb, entityColor.a);
    vec3 albedoLin = alSrgbToLinear(tex.rgb);

    vec3 N = normalize(wnormal);
    vec3 wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3 wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    float NdotL = max(dot(N, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, N, NdotL);

    vec3 color = alLightPhase1(albedoLin, N, lmcoord, shadowVis, wLightDir, wSunDir,
                               playerPos + cameraPosition, dayFactor);

    outColor = vec4(color, tex.a);
}
