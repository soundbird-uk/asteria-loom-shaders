#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/lighting.glsl"
#include "/lib/shadow.glsl"

/*
 gbuffers_particles (fragment) — FORWARD-LIT particles blended into colortex0.

 Particles are ordered `after` (post-deferred) so they cannot write the
 G-buffer and be shaded by the deferred pass; instead they shade themselves
 with the shared lighting model here, exactly like translucent water/entities.
 Cutout particles (block-break, crit) still need the alpha test.
 Sampler count: gtexture + shadow samplers via lib/shadow.glsl (SHADOWS):
   Mac fallback = 3 (gtexture, shadowtex1, noisetex);
   hardware-flag = 4 (gtexture, shadowtex0, shadowtex1HW, noisetex). <=4 budget.
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
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
