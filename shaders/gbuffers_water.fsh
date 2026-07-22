#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"

/*
 gbuffers_water (fragment) — forward-lit translucent water, blended over the
 already-lit opaque scene in colortex0. Uses the SAME lighting model as the
 deferred opaque pass so water matches its surroundings.
 Sampler count: gtexture + shadow samplers via lib/shadow.glsl (SHADOWS):
   Mac fallback = 3 (gtexture, shadowtex1, noisetex);
   hardware-flag = 4 (gtexture, shadowtex0, shadowtex1HW, noisetex). <=4 budget.
*/

uniform sampler2D gtexture;
uniform vec3 sunPosition;          // view space
uniform vec3 shadowLightPosition;  // view space, toward dominant light
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

    // Cool blue-green tint + a touch of transparency for the Phase-1 look.
    vec3 albedoLin = alSrgbToLinear(tex.rgb) * vec3(0.55, 0.80, 0.90);
    float alpha = tex.a * 0.72;

    vec3 N = normalize(wnormal);
    vec3 wLightDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition);
    vec3 wSunDir   = normalize(mat3(gbufferModelViewInverse) * sunPosition);
    float dayFactor = alDayFactor(wSunDir);

    float NdotL = max(dot(N, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, N, NdotL);

    vec3 color = alLightPhase1(albedoLin, N, lmcoord, shadowVis, wLightDir, wSunDir,
                               playerPos + cameraPosition, dayFactor);

    outColor = vec4(color, alpha);
}
