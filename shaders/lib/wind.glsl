#ifndef AL_LIB_WIND
#define AL_LIB_WIND

/*
 lib/wind.glsl — foliage wind animation (Phase 4.3, ISSUE 5).

 SAMPLER-FREE, uniform-free pure GLSL 3.30 / Mac-GL4.1 math (like lib/water.glsl):
 every input is passed in as an argument, so this file is safe to include in ANY
 vertex program (gbuffers_terrain, shadow) without colliding with a caller's
 uniform/attribute set. No noisetex — the field is analytic (cheap sines) so it
 is trivially cheap in the vertex stage.

 MODEL (brief §5): grass/plants sway MORE than leaves; leaves get a subtle
 flutter; motion VARIES SPATIALLY (never the whole world in sync); rolling GUSTS
 modulate amplitude; per-plant PHASE decorrelates neighbours; block BASES stay
 anchored (a height/top weight so only the free top moves); amplitudes are kept
 modest so TAA does not shimmer.

 Two exports:
   float alWindGust(vec2 worldXZ, float t)
       — a rolling [0,1] gust envelope: two low-frequency travelling waves at
         different directions/rates, so waves of stronger/weaker wind visibly
         sweep across the world and neighbouring plants are never in sync.
   vec3  alFoliageSway(worldPos, t, amount, topW, leaf)
       — the world-space displacement (blocks) to add to a foliage vertex.
*/

#include "/lib/common.glsl"

// Rolling gust field in [0,1] over world XZ + time. Two travelling low-frequency
// waves (different directions + rates) sum to visible gusts sweeping the world.
float alWindGust(vec2 wxz, float t) {
    float g = sin(dot(wxz, vec2(0.045, 0.031)) - t * 0.85);
    g += 0.6 * sin(dot(wxz, vec2(-0.019, 0.026)) - t * 0.55);
    return alSaturate(0.5 + 0.5 * (g / 1.6));
}

/*
 Foliage sway displacement in WORLD space (blocks).
   worldPos : vertex world position (feet + cameraPosition)
   t        : time in seconds (frameTimeCounter * AL_WIND_SPEED)
   amount   : base sway strength (grass > leaves; <= 0 disables)
   topW     : 0 at an anchored base .. 1 at the free top (anchors block bases)
   leaf     : 1.0 for leaves (adds flutter, translates less), 0.0 for grass/plants
*/
vec3 alFoliageSway(vec3 worldPos, float t, float amount, float topW, float leaf) {
    float drive = amount * topW;
    if (drive <= 0.0) return vec3(0.0);

    vec2  wxz   = worldPos.xz;
    float phase = dot(wxz, vec2(0.7, 0.53));            // per-plant spatial phase
    float gust  = alWindGust(wxz, t);
    float strength = drive * (0.30 + 1.0 * gust);       // gust envelope

    // Horizontal sway biased along a slowly-rotating wind axis, driven by a
    // SUPERPOSITION of sines at different rates/phases (not one uniform sine) plus
    // a cross component, so blades lap rather than march in lock-step.
    float wdir = t * 0.03;
    vec2  axis = vec2(cos(wdir), sin(wdir));
    float s = 0.60 * sin(t * 1.7 + phase)
            + 0.40 * sin(t * 2.6 + phase * 1.7 + 1.3);
    vec2  horiz = axis * s + vec2(0.0, 0.35 * sin(t * 2.1 + phase * 0.8));
    vec3  disp  = vec3(horiz.x, 0.0, horiz.y) * (strength * 0.14);

    // Small vertical bob (grass only) so tips lift a touch with the gust.
    disp.y += sin(t * 2.3 + phase) * strength * 0.035 * (1.0 - leaf);

    // Leaf flutter: fine, fast, spatially-varying shimmer at SMALL amplitude (kept
    // low so TAA does not sparkle). Full worldPos so adjacent leaf quads differ.
    if (leaf > 0.5) {
        float f = sin(t * 4.5 + dot(worldPos, vec3(2.1, 1.7, 2.3)))
                + sin(t * 5.9 + dot(worldPos.zxy, vec3(1.9, 2.4, 1.5)));
        disp    += vec3(f * 0.012) * drive;
        disp.xz *= 0.6;    // leaves translate less horizontally than grass
    }
    return disp;
}

#endif // AL_LIB_WIND
