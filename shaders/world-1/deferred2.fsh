#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"

/*
 deferred2 (fragment) — COLOURED BLOCK LIGHT gather (5.4.0).

 WHAT IT PRODUCES
 ----------------
 For every pixel: "what COLOUR is the block light reaching here?" — nothing
 more. The answer is a screen-space disc gather of (emissive albedo x emission
 level x distance weight) over the visible emitters around the pixel, written to
 colortex13 and temporally accumulated through colortex14.

 WHAT IT DELIBERATELY DOES NOT PRODUCE
 -------------------------------------
 Any notion of how BRIGHT the block light is. That stays with the vanilla `lm.x`
 lightmap, whose falloff comes from the game's own flood fill and is therefore
 already occlusion-correct. lib/lighting.glsl consumes this buffer as a HUE
 only — see the long note there and in settings.glsl. This is why a screen-space
 approximation is sound here at all: the classic screen-space failure ("light
 bleeds through the wall because the emitter is visible but the wall isn't
 traced") cannot happen, because a pixel behind a wall has lm.x == 0 and the
 whole block-light term is zero no matter what colour we hand it.

 WHY IT RUNS HERE, AFTER deferred1
 ---------------------------------
 Iris' fixed pass order is deferred -> deferred1 -> deferred2 -> translucents.
 The lighting pass is deferred1, so it necessarily reads LAST frame's colortex13
 (which is why colortex13 is declared `clear = false` in final.fsh alongside the
 history). That one-frame latency is invisible in practice: the buffer is a
 low-frequency HUE field that is already blended at AL_CBL_T_BLEND (0.90) — i.e.
 deliberately ~10 frames of lag — so one more frame changes nothing perceptible.
 The alternative (moving the gather into the `deferred` slot) would mean evicting
 GTAO, which is a far worse trade. If the latency ever does matter, the fix is a
 dedicated `prepare1`-style pass, not reordering the deferred chain.

 HALF RESOLUTION
 ---------------
 colortex13/14 are declared 0.5 x 0.5 in shaders.properties. The hue field is
 smooth by construction, so half res costs nothing visually while quartering the
 gather cost, and the bilinear upsample when deferred1 reads it at full res acts
 as a free 2x2 reconstruction filter over the disc's tap noise.

 Sampler count: 5 (colortex1, colortex3, colortex14, depthtex0, noisetex).
 Well inside the 16-sampler Mac limit.
*/

uniform sampler2D colortex1;    // albedo (sRGB) — the emitter's own colour
uniform sampler2D colortex3;    // r = matID, g = emitter light level (0..1)
uniform sampler2D colortex14;   // coloured-light history: rgb = light, a = eye depth
uniform sampler2D depthtex0;
uniform sampler2D noisetex;     // 256x256 blue-ish noise — per-pixel disc rotation

uniform mat4  gbufferProjection;  // view -> clip (world radius -> screen radius)
uniform int   frameCounter;

in vec2 texcoord;

/* RENDERTARGETS: 13,14 */
layout(location = 0) out vec3 outLight;    // -> colortex13 (R11F_G11F_B10F, consumed)
layout(location = 1) out vec4 outHistory;  // -> colortex14 (RGBA16F, rgb + eye depth)

void main() {
    float depth = texture(depthtex0, texcoord).r;

    // Iris writes GARBAGE into any RENDERTARGETS entry an invocation leaves
    // unwritten, so every early-out below writes BOTH targets. A history alpha
    // (eye depth) of 0 makes next frame's depth test reject the texel outright,
    // which is the clean "no valid history here" reset.
    if (depth >= 1.0) {
        // Sky: no surface, nothing to tint. Writing black is correct rather than
        // merely safe — lib/lighting.glsl reads black as "nothing found" and
        // falls back to the warm constant ramp.
        outLight   = vec3(0.0);
        outHistory = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }

    vec3  viewPos = alScreenToView(texcoord, depth);
    float eyeZ    = alLinearEyeDepth(viewPos);

    // --- Screen-space search radius ---------------------------------------
    // Project AL_CBL_WORLD_RADIUS metres at this depth into UV, exactly as the
    // GTAO pass does. gbufferProjection[0][0]/[1][1] carry the fov/aspect scale.
    // Clamped so a pixel right against the camera cannot march a quarter of the
    // screen per tap (an unbounded radius here is a cache-thrashing hazard, not
    // just a quality one).
    vec2 radiusUV = 0.5 * vec2(gbufferProjection[0][0], gbufferProjection[1][1])
                        * (AL_CBL_WORLD_RADIUS / max(eyeZ, 0.05));
    radiusUV = clamp(radiusUV, vec2(0.0), vec2(AL_CBL_MAX_RADIUS_UV));

    // --- Per-pixel disc rotation ------------------------------------------
    // noisetex tiles every 256 px, but the disc ANGLE is the only thing it
    // drives and the result is a smooth chroma field, so the tiling never reads
    // as a grid here (unlike the contact-shadow case, which had to abandon it).
    // The per-frame advance uses the golden ratio so successive frames sample
    // genuinely new angles; colortex14 averages them. See the grain policy in
    // settings.glsl for why this one animates unconditionally.
    float nz  = texture(noisetex, gl_FragCoord.xy / 256.0).r;
    float rot = fract(nz + float(frameCounter) * 0.61803398875) * AL_TAU;

    // --- Disc gather -------------------------------------------------------
    vec3 gather = vec3(0.0);
    for (int i = 0; i < AL_CBL_TAPS; ++i) {
        // Area-uniform spiral: r = sqrt(t) spreads taps evenly over the DISC
        // (a linear r would over-sample the centre and miss emitters at the rim).
        float t = (float(i) + 0.5) / float(AL_CBL_TAPS);
        float r = sqrt(t);
        float a = rot + t * AL_CBL_TURNS * AL_TAU;
        vec2  uv = texcoord + vec2(cos(a), sin(a)) * (r * radiusUV);

        // Off-screen taps are SKIPPED, never clamped: a clamped read folds the
        // screen edge inward and would smear an edge torch's colour across the
        // whole border (the same failure the cloud history's strict reprojection
        // margin exists to prevent).
        if (uv.x <= 0.0 || uv.x >= 1.0 || uv.y <= 0.0 || uv.y >= 1.0) continue;

        vec2 mat = texture(colortex3, uv).rg;
        if (alDecodeMatID(mat.r) != AL_MATID_EMISSIVE) continue;
        float level = alDecodeEmission(mat.g);
        if (!(level > 0.0)) continue;           // NaN-safe: fails -> skipped

        float sd = texture(depthtex0, uv).r;
        if (sd >= 1.0) continue;                // sky behind the emitter mask

        // World-space (well, view-space — same metric) separation. Screen-space
        // proximity is NOT proximity: a torch 40 blocks down a corridor can sit
        // one pixel away. Reject by real distance so it cannot colour this pixel.
        vec3  sView = alScreenToView(uv, sd);
        float dist  = length(sView - viewPos);
        if (dist > AL_CBL_WORLD_RADIUS) continue;

        // Inverse-square-flavoured falloff, softened by the +1 so an adjacent
        // emitter does not blow up and a few blocks away still counts. level^2
        // makes a dim source (sculk vein, magma) lose to a bright one (glowstone)
        // when both are in reach, which is the right tie-break for a HUE.
        float w = (level * level) / (1.0 + dist * dist * AL_CBL_FALLOFF);

        gather += alSrgbToLinear(texture(colortex1, uv).rgb) * w;
    }
    gather *= AL_CBL_GAIN / float(AL_CBL_TAPS);

    // Belt & braces before anything can enter the history: a range test (NOT a
    // clamp) so a non-finite value falls through to black instead of being
    // silently turned into a large finite one.
    bool curOK = (gather.r >= 0.0) && (gather.r < AL_CBL_MAX)
              && (gather.g >= 0.0) && (gather.g < AL_CBL_MAX)
              && (gather.b >= 0.0) && (gather.b < AL_CBL_MAX);
    if (!curOK) gather = vec3(0.0);

    // --- Temporal accumulation (colortex14) --------------------------------
    // Iris flip rule: a composite-style program reads the 'main' buffer and
    // writes the 'alt' one, so reading colortex14 here while also listing it in
    // RENDERTARGETS is legal and returns the PREVIOUS frame's content (nothing
    // else writes it).
    //
    // NaN law: colortex14 is clear=false, so its first-frame contents are
    // undefined driver garbage. Every acceptance test below is a positive
    // comparison — which NaN fails — so garbage falls through to "current frame
    // only" and the buffer self-heals within one frame.
    vec3 result = gather;

    vec2  prevUV;
    float prevEyeZ;
    if (alMotionVector(viewPos, texcoord, prevUV, prevEyeZ)) {
        vec4 hist = texture(colortex14, prevUV);
        bool histOK = (hist.r >= 0.0) && (hist.r < AL_CBL_MAX)
                   && (hist.g >= 0.0) && (hist.g < AL_CBL_MAX)
                   && (hist.b >= 0.0) && (hist.b < AL_CBL_MAX)
                   && alHistoryDepthOK(hist.a, prevEyeZ, AL_CBL_T_DEPTH_REJECT);
        if (histOK) {
            // Straight exponential blend, no neighbourhood clamp. A clamp exists
            // to stop a stale value being DRAGGED behind a moving occluder; here
            // the worst case is a hue lagging by a few frames as a torch is
            // placed or broken, which is both invisible and self-correcting,
            // whereas a clamp would fight the very averaging that removes the
            // disc's tap noise.
            result = mix(gather, hist.rgb, AL_CBL_T_BLEND);
        }
    }

    // Final sanitize: nothing non-finite may EVER reach colortex13 (which
    // lighting.glsl reads) or colortex14 (which re-infects itself next frame).
    bool outOK = (result.r >= 0.0) && (result.r < AL_CBL_MAX)
              && (result.g >= 0.0) && (result.g < AL_CBL_MAX)
              && (result.b >= 0.0) && (result.b < AL_CBL_MAX);
    if (!outOK) result = gather;

    outLight   = result;
    outHistory = vec4(result, (eyeZ > 0.0 && eyeZ < 65000.0) ? eyeZ : 0.0);
}
