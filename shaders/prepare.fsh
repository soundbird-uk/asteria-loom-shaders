#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/atmosphere_common.glsl"

/*
 prepare (fragment) — bake the sky-view LUT ONCE per frame into the top-left
 AL_SKY_TILE_W x AL_SKY_TILE_H (256x128) tile of colortex6. Every reader
 (skybasic sky, clouds ambient, fog in-scatter, sky reflections) then samples
 this tile via alSkySample() instead of re-marching the atmosphere.

 Fragments OUTSIDE the tile discard, so the rest of colortex6 is left untouched
 (it is clear=false and unused). The tile is regenerated in full every frame,
 so staleness is a non-issue — only first-frame garbage, which the read side
 range-validates against.

 We include ONLY the sampler-free core: this pass WRITES colortex6, it must not
 sample it.

 Sampler count: 0 (pure analytic; uniforms only)
*/

uniform vec3 sunPosition;               // view space, toward the sun
uniform mat4 gbufferModelViewInverse;

in vec2 texcoord;

/* RENDERTARGETS: 6 */
layout(location = 0) out vec4 outColor;

void main() {
    // Address the tile by absolute pixel. gl_FragCoord.xy is the pixel centre
    // (x+0.5), so dividing by the tile size yields UVs sampled at texel centres
    // — an inherent half-texel inset that matches the read side.
    if (gl_FragCoord.x >= AL_SKY_TILE_W || gl_FragCoord.y >= AL_SKY_TILE_H) {
        discard;
    }

    vec2 tileUV = gl_FragCoord.xy / vec2(AL_SKY_TILE_W, AL_SKY_TILE_H);
    vec3 dir = alSkyDecodeDir(tileUV);

    vec3 sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);

    // Full single-scatter march, then bake SKY_BRIGHTNESS so all readers get a
    // consistently scaled sky.
    vec3 radiance = alSkyRadiance(dir, sunDir) * SKY_BRIGHTNESS;

    outColor = vec4(radiance, 1.0);
}
