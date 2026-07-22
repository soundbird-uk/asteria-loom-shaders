#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/shadow.glsl"
#include "/lib/lighting.glsl"

/*
 deferred (fragment) — the main opaque shading pass.

 Reads the G-buffer, reconstructs world position from depth, evaluates the
 shared Phase-1 lighting model, and writes linear HDR back to colortex0.
 Sky pixels (depth == 1.0) pass the sky colour (already in colortex0 from the
 skybasic/skytextured passes) straight through untouched.

 NOTE: gbufferProjectionInverse / gbufferModelViewInverse are declared in
 lib/space.glsl (included above) — do NOT redeclare them here.

 Sampler count: 6 (colortex0, colortex1, colortex2, colortex3, depthtex0,
                   shadowtex1[SHADOWS])
*/

uniform sampler2D colortex0;   // sky / scene HDR
uniform sampler2D colortex1;   // albedo
uniform sampler2D colortex2;   // normal + lightmap
uniform sampler2D colortex3;   // matID + flags
uniform sampler2D depthtex0;

uniform vec3 sunPosition;          // view space
uniform vec3 shadowLightPosition;  // view space, toward dominant light

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    float depth = texture(depthtex0, texcoord).r;

    // Sky: pass through whatever the sky passes already wrote.
    if (depth >= 1.0) {
        outColor = texture(colortex0, texcoord);
        return;
    }

    // --- Decode G-buffer --------------------------------------------------
    vec3  albedoSrgb = texture(colortex1, texcoord).rgb;
    vec3  albedoLin  = alSrgbToLinear(albedoSrgb);

    vec4  nl = texture(colortex2, texcoord);
    vec3  N  = alDecodeNormal(nl.rg);
    vec2  lm = nl.ba;                       // block, sky

    // --- Reconstruct position + light directions --------------------------
    vec3 viewPos   = alScreenToView(texcoord, depth);
    vec3 playerPos = alViewToPlayer(viewPos);

    vec3 wLightDir = normalize(alViewDirToWorld(shadowLightPosition));
    vec3 wSunDir   = normalize(alViewDirToWorld(sunPosition));
    float dayFactor = alDayFactor(wSunDir);

    // --- Shadow + shade ---------------------------------------------------
    float NdotL = max(dot(N, wLightDir), 0.0);
    float shadowVis = alShadowVisibility(playerPos, N, NdotL);

    vec3 color = alLightPhase1(albedoLin, N, lm, shadowVis, wLightDir, dayFactor);

    outColor = vec4(color, 1.0);
}
