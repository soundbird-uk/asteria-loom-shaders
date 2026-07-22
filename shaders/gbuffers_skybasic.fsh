#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"

/*
 gbuffers_skybasic (fragment) — reproduce the vanilla sky gradient and write
 it straight into the HDR scene buffer (colortex0). Phase 3 replaces this
 with a physically based atmosphere.

 Iris quirk: this same program draws the sky gradient, the void plane AND the
 vanilla stars, distinguished by `renderStage`. We branch on it to SUPPRESS
 vanilla stars (procedural night sky is Phase 3) while keeping the gradient.

 Sampler count: 0  (uses uniforms only)
*/

uniform int renderStage;
uniform vec3 skyColor;   // vanilla upper-sky colour
uniform vec3 fogColor;   // vanilla horizon/fog colour

in vec3 worldDir;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // Kill vanilla stars/void so the (future) procedural sky owns the night.
    if (renderStage == MC_RENDER_STAGE_STARS ||
        renderStage == MC_RENDER_STAGE_VOID) {
        discard;
    }

    vec3 dir = normalize(worldDir);
    // Warmer, hazier near the horizon; cooler toward the zenith.
    float h = smoothstep(-0.10, 0.45, dir.y);
    vec3 sky = mix(fogColor, skyColor, h);

    // Work in linear HDR like the rest of the scene.
    sky = alSrgbToLinear(sky) * SKY_BRIGHTNESS;

    outColor = vec4(sky, 1.0);
}
