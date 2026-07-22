#version 330 compatibility
#include "/settings.glsl"

/*
 composite (fragment) — structural passthrough of colortex0.

 Intentionally a no-op copy for Phase 1. It is kept (not deleted) so the pass
 chain shape is STABLE: Phases 2-4 hang SSAO composite, fog, SSR, bloom
 downsample, etc. off this seam without reshuffling buffer flips. Cheap.
 Sampler count: 1 (colortex0)
*/

uniform sampler2D colortex0;

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(colortex0, texcoord);
}
