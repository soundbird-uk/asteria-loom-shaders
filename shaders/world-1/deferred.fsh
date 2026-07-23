#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"

/*
 deferred (fragment) — GTAO (horizon-based ambient occlusion) + temporal
 accumulation. Writes the AO term + a confidence channel to colortex4; the
 lighting pass (deferred1) multiplies it onto the ambient / bounce / blocklight
 terms only. This whole pass is dispatched ONLY when AO is on
 (`program.deferred.enabled = AO` in shaders.properties), but it still must
 COMPILE under every profile, so nothing here is gated behind `#ifdef AO`.

 TECHNIQUE (brief §6, phase2 §4):
   - Reconstruct view-space position from depthtex0 and the view-space normal
     from colortex2 (world octahedral normal -> view via gbufferModelView).
   - For AO_QUALITY 1/2/3 march (2x3)/(2x4)/(3x4) slices x steps. Each slice is
     a half-plane through the view vector; horizon cosines are searched in
     screen space both ways along the slice direction, per-pixel rotated by
     noisetex and advanced per frame by an R2 low-discrepancy offset.
   - Cosine-weighted visibility via the GTAO arc integral (Jimenez 2016),
     weighted by the length of the normal projected into the slice plane.
   - FULL RESOLUTION (Iris per-pass viewport scaling is unverified — phase2 §2).

 TEMPORAL ACCUMULATION (same pass):
   - Reproject this pixel into the previous frame (lib/space.glsl previous-frame
     helpers: camera-delta + gbufferPrevious* matrices) and sample colortex5.
   - Reject history when the reprojected UV is off-screen or the previous linear
     depth disagrees with the stored history depth by > AL_AO_DEPTH_REJECT.
   - Blend toward history by the stored confidence (up to AL_AO_MAX_BLEND), and
     ramp confidence so a freshly-disoccluded pixel converges over a few frames.

 Sampler count:
   colortex2 + colortex5 + depthtex0 + noisetex = 4  (<= 5 budget, phase2 §7)
*/

uniform sampler2D colortex2;   // octahedral normal .rg, lightmap .ba
uniform sampler2D colortex5;   // AO history: r=AO, g=confidence, b=linear depth
uniform sampler2D depthtex0;
uniform sampler2D noisetex;    // 256x256 blue-ish noise, per-pixel rotation

// View<->clip and world<->view (the inverse pair comes from lib/space.glsl).
uniform mat4 gbufferProjection;   // view -> clip (screen search radius)
uniform mat4 gbufferModelView;    // world -> view (normal transform)

uniform int   frameCounter;
uniform float viewHeight;         // framebuffer height in pixels (NOT a sampler)

in vec2 texcoord;

/* RENDERTARGETS: 4 */
layout(location = 0) out vec2 outAO;   // r = AO (1 = unoccluded), g = confidence

// --- Quality -> slice/step counts ------------------------------------------
#if AO_QUALITY == 1
    #define AL_AO_SLICES 2
    #define AL_AO_STEPS  3
#elif AO_QUALITY == 3
    #define AL_AO_SLICES 3
    #define AL_AO_STEPS  4
#else   // AO_QUALITY == 2 (default)
    #define AL_AO_SLICES 2
    #define AL_AO_STEPS  4
#endif

void main() {
    float depth = texture(depthtex0, texcoord).r;

    // Sky: fully unoccluded, no history contribution.
    if (depth >= 1.0) {
        outAO = vec2(1.0, 0.0);
        return;
    }

    // --- Reconstruct view geometry ----------------------------------------
    vec3 viewPos = alScreenToView(texcoord, depth);
    vec3 V       = normalize(-viewPos);              // toward the camera
    vec3 worldN  = alDecodeNormal(texture(colortex2, texcoord).rg);
    vec3 N       = normalize(mat3(gbufferModelView) * worldN);

    float linZ = alLinearEyeDepth(viewPos);

    // Screen-space search radius: an AL_AO_RADIUS-metre world extent projected
    // to UV at this depth, clamped so near geometry doesn't march the whole
    // screen. gbufferProjection[0][0]/[1][1] carry the fov/aspect scale.
    vec2 radiusUV = 0.5 * vec2(gbufferProjection[0][0], gbufferProjection[1][1])
                        * (AL_AO_RADIUS / max(linZ, 0.05));
    // Floor at ~1.5 px (in UV) so the search never collapses sub-pixel; ceil so
    // near geometry doesn't march the whole screen. Uses the real framebuffer
    // height (viewHeight) rather than a hard-coded resolution.
    float minRadiusUV = 1.5 / max(viewHeight, 1.0);
    radiusUV = clamp(radiusUV, vec2(minRadiusUV), vec2(AL_AO_MAX_RADIUS_UV));

    // --- Per-pixel rotation + per-frame R2 advance ------------------------
    vec2  nz = texture(noisetex, gl_FragCoord.xy / 256.0).xy;
    // R2 sequence: two irrational advances (1/plastic, 1/plastic^2).
    float sliceJitter = fract(nz.x + float(frameCounter) * 0.75487766624669276);
    float stepJitter  = fract(nz.y + float(frameCounter) * 0.56984029099805327);

    // --- GTAO slice loop --------------------------------------------------
    // Jimenez normalizes the accumulated visibility by the sum of the
    // projected-normal lengths (NOT the slice count): projLen <= 1, so dividing
    // by the count over-darkens view-grazing surfaces. Track the sum instead.
    float visibility = 0.0;
    float projLenSum = 0.0;

    for (int s = 0; s < AL_AO_SLICES; s++) {
        float phi = (float(s) + sliceJitter) * (AL_PI / float(AL_AO_SLICES));
        vec2  dir = vec2(cos(phi), sin(phi));

        // Slice-plane basis in view space. sliceTangent = +dir projected
        // perpendicular to V; axis = plane normal; project N into the plane.
        vec3 dir3         = vec3(dir, 0.0);
        vec3 sliceTangent = dir3 - V * dot(dir3, V);
        float tanLen      = length(sliceTangent);
        if (tanLen < 1e-4) continue;
        sliceTangent /= tanLen;

        vec3  axis   = cross(sliceTangent, V);
        vec3  projN  = N - axis * dot(N, axis);
        float projLen = length(projN);
        if (projLen < 1e-4) continue;

        // Signed angle of the projected normal from V toward +sliceTangent.
        float n = atan(dot(projN, sliceTangent), dot(projN, V));

        // Horizon cosines both ways (init -1 => 180deg => no occluder).
        float cosH1 = -1.0;   // +dir side
        float cosH2 = -1.0;   // -dir side

        for (int j = 0; j < AL_AO_STEPS; j++) {
            float t = (float(j) + stepJitter + 1.0) / float(AL_AO_STEPS); // (0,1]
            vec2 off = dir * radiusUV * t;

            // +dir sample
            vec2 uvP = texcoord + off;
            if (uvP.x > 0.0 && uvP.x < 1.0 && uvP.y > 0.0 && uvP.y < 1.0) {
                float dP = texture(depthtex0, uvP).r;
                if (dP < 1.0) {
                    vec3  spP = alScreenToView(uvP, dP);
                    vec3  dv  = spP - viewPos;
                    float len = length(dv);
                    if (len > 1e-4) {
                        float ch = dot(dv, V) / len;
                        float w  = alSaturate(1.0 - (len * len)
                                            / (AL_AO_RADIUS * AL_AO_RADIUS));
                        cosH1 = max(cosH1, mix(-1.0, ch, w));
                    }
                }
            }
            // -dir sample
            vec2 uvN = texcoord - off;
            if (uvN.x > 0.0 && uvN.x < 1.0 && uvN.y > 0.0 && uvN.y < 1.0) {
                float dN = texture(depthtex0, uvN).r;
                if (dN < 1.0) {
                    vec3  spN = alScreenToView(uvN, dN);
                    vec3  dv  = spN - viewPos;
                    float len = length(dv);
                    if (len > 1e-4) {
                        float ch = dot(dv, V) / len;
                        float w  = alSaturate(1.0 - (len * len)
                                            / (AL_AO_RADIUS * AL_AO_RADIUS));
                        cosH2 = max(cosH2, mix(-1.0, ch, w));
                    }
                }
            }
        }

        // Signed horizon angles about V, then clamped to the normal hemisphere.
        float H1 =  acos(clamp(cosH1, -1.0, 1.0));   // +side (positive)
        float H2 = -acos(clamp(cosH2, -1.0, 1.0));   // -side (negative)
        H1 = n + min(H1 - n,  AL_HALFPI);
        H2 = n + max(H2 - n, -AL_HALFPI);

        // GTAO arc integral (cosine-weighted visibility over the slice).
        float sinN = sin(n);
        float cosN = cos(n);
        float slice = 0.25 * ( (-cos(2.0 * H1 - n) + cosN + 2.0 * H1 * sinN)
                             + (-cos(2.0 * H2 - n) + cosN + 2.0 * H2 * sinN) );
        visibility += projLen * slice;
        projLenSum += projLen;
    }

    // Normalize by Σ(projLen). Guard against zero (all slices skipped: normal
    // parallel to every slice plane, or degenerate) -> treat as unoccluded.
    float rawAO = (projLenSum > 1e-4) ? alSaturate(visibility / projLenSum) : 1.0;
    // Belt & braces: strip any non-finite result before it can enter history.
    // A range test (NOT clamp) is used because NaN fails every comparison, so
    // garbage falls through to the safe default even under fast-math builds.
    rawAO = (rawAO >= 0.0 && rawAO <= 1.0) ? rawAO : 1.0;

    // --- Temporal accumulation --------------------------------------------
    vec3  playerPos = alViewToPlayer(viewPos);
    vec3  prevView  = alPlayerToPrevView(playerPos);
    vec3  prevScr   = alPrevViewToScreen(prevView);

    float ao   = rawAO;
    float conf = AL_AO_CONF_STEP;   // fresh sample (no accepted history yet)

    // NaN-proof, self-healing history. colortex5 has clear=false, so its
    // FIRST-frame contents are UNDEFINED (Apple GL does not reliably zero-init —
    // garbage/NaN). If a NaN reached the blend it would be written back into
    // colortex4 and (via composite) back into colortex5, self-reinfecting the
    // history forever and blacking out the world on macOS. Every gate below is a
    // comparison that NaN CANNOT pass, so any poison falls through to the reset
    // branch (ao = rawAO); accepted values are additionally clamped.
    if (prevScr.x > 0.0 && prevScr.x < 1.0 &&
        prevScr.y > 0.0 && prevScr.y < 1.0) {
        vec4  hist    = texture(colortex5, prevScr.xy);   // r=AO, g=conf, b=linZ
        float expectZ = alLinearEyeDepth(prevView);

        // Range validation — rejects NaN AND out-of-range garbage alike.
        bool histValid = (hist.r >= 0.0) && (hist.r <= 1.0) &&
                         (hist.g >= 0.0) && (hist.g <= 1.0) &&
                         (hist.b >  0.0) && (hist.b <  65000.0) &&
                         (expectZ > 0.0) && (expectZ < 65000.0);
        if (histValid) {
            float relErr = abs(expectZ - hist.b) / max(hist.b, 0.001);
            if (relErr < AL_AO_DEPTH_REJECT) {
                float prevConf = clamp(hist.g, 0.0, AL_AO_CONF_MAX);
                float histAO   = clamp(hist.r, 0.0, 1.0);
                float blend    = min(AL_AO_MAX_BLEND, prevConf);
                ao   = mix(rawAO, histAO, blend);
                conf = min(prevConf + AL_AO_CONF_STEP, AL_AO_CONF_MAX);
            }
        }
    }

    // Final sanitize so NO non-finite value can EVER be emitted into colortex4
    // (and thence colortex5). Range tests, not clamp — see rawAO note above.
    ao   = (ao   >= 0.0 && ao   <= 1.0)            ? ao   : 1.0;
    conf = (conf >= 0.0 && conf <= AL_AO_CONF_MAX) ? conf : AL_AO_CONF_STEP;
    outAO = vec2(ao, conf);
}
