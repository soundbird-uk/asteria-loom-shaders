#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/space.glsl"

/*
 composite (fragment) — scene-colour passthrough + AO-history copy.

 Two jobs:
   1. Pass colortex0 through unchanged (the structural seam Phases 3-4 hang fog
      / SSR / bloom off — kept stable).
   2. Copy this frame's AO (colortex4) into the persistent history buffer
      colortex5, tagging it with the current linear eye depth so next frame's
      GTAO pass can reject reprojected samples that landed on a different
      surface. colortex5 has `clear.colortex5 = false`, so it survives to the
      next frame; the AO pass (deferred) already consumed LAST frame's copy
      before we overwrite it here, so there is no same-frame read/write hazard.

 With AO off the AO pass is not dispatched and colortex4 is a cleared (0,0)
 buffer; copying it here is harmless (nothing reads colortex5 in that case).

 DEPTH SOURCE: history depth is read from depthtex1 (NO translucents), NOT
 depthtex0. The AO pass (deferred) runs pre-translucents and reconstructs from
 opaque-only depth; composite runs POST-translucents, so depthtex0 here is
 translucent-inclusive. Stamping history with a translucent surface's depth
 would make next frame's reproject test mismatch the opaque surface behind
 water/glass/particles every frame (5% depth-reject always fires) — AO never
 accumulates and shimmers on submerged terrain. depthtex1 matches what the AO
 pass actually sampled.

 Sampler count: 3 (colortex0, colortex4, depthtex1)
*/

uniform sampler2D colortex0;   // scene HDR
uniform sampler2D colortex4;   // this frame's AO (r), confidence (g)
uniform sampler2D depthtex1;   // opaque-only depth (matches the AO pass)

in vec2 texcoord;

/* RENDERTARGETS: 0,5 */
layout(location = 0) out vec4 outColor;     // -> colortex0 (scene passthrough)
layout(location = 1) out vec4 outHistory;   // -> colortex5 (AO history)

void main() {
    outColor = texture(colortex0, texcoord);

    // AO history: r = AO, g = confidence, b = linear eye depth of this sample.
    // Clamp everything copied here (range tests, not clamp() — NaN fails every
    // comparison and falls through to the safe default) so the persistent
    // colortex5 can never carry a non-finite value forward, even if a stray NaN
    // slipped into colortex4.
    vec2  ao    = texture(colortex4, texcoord).rg;
    float depth = texture(depthtex1, texcoord).r;
    float aoR   = (ao.r >= 0.0 && ao.r <= 1.0) ? ao.r : 1.0;
    float aoG   = (ao.g >= 0.0 && ao.g <= 1.0) ? ao.g : 0.0;
    float linZ  = (depth >= 1.0) ? 0.0
                                 : alLinearEyeDepth(alScreenToView(texcoord, depth));
    linZ = (linZ >= 0.0 && linZ < 65000.0) ? linZ : 0.0;
    outHistory = vec4(aoR, aoG, linZ, 1.0);
}
