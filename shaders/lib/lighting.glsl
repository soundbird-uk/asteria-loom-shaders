#ifndef AL_LIB_LIGHTING
#define AL_LIB_LIGHTING

/*
 lib/lighting.glsl — the shared lighting model.

 This is the ONE place lighting math lives. It is shared verbatim by the
 deferred pass (opaque G-buffer shading) and by the forward translucent
 passes (water, hand water, particles, translucent entities) so a lit water
 surface matches the terrain around it. Keep it self-contained and free of
 pass-specific sampler reads: callers hand in everything (decoded albedo, world
 normal, lightmap, shadow term, light direction, sun direction, world position,
 day factor).

 PHASE 3 CHANGES:
   - Direct and ambient COLOURS now come from the atmosphere model
     (lib/atmosphere_common.glsl) — alDirectColor()/alAmbientColor(). The warm
     amber identity (AL_SUN_TINT) and the cool blue-purple ambient identity
     (AL_AMBIENT_SKY) are retained as multiplicative TINT MODIFIERS inside those
     functions, so the SKY/LIGHTING options still push warmth and the 0.2.x noon
     look is preserved (noon direct == AL_SUN_TINT, noon ambient == AL_AMBIENT_SKY).
   - The direct term is multiplied by the cloud-shadow factor
     alCloudShadow(worldPos) from lib/clouds_common.glsl (sampler-free; 1.0 when
     volumetric clouds are off — the include provides that fallback).

 CRITICAL SAMPLER RULE: this lib includes ONLY the sampler-free atmosphere core
 and the sampler-free cloud-shadow helper. It must NEVER include the LUT-reading
 lib/atmosphere.glsl — that would leak the colortex6 sampler into every forward
 pass and blow their budget. The atmosphere colours here are pure math from the
 sun direction; no LUT is read.

 All maths is LINEAR; the caller decodes albedo sRGB->linear and outputs
 linear HDR to colortex0.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/atmosphere_common.glsl"
#include "/lib/clouds_common.glsl"

// Day/night blend from the sun's world-space height. 1 = sun up, 0 = night.
// A soft ramp around the horizon gives a gentle dawn/dusk transition.
float alDayFactor(vec3 worldSunDir) {
    return alSmooth(smoothstep(-0.06, 0.16, worldSunDir.y));
}

/*
 Core shade. Returns linear HDR radiance.

   albedoLin   : albedo already decoded to linear
   worldN      : world-space surface normal (normalized)
   lm          : lightmap (x = block 0..1, y = sky 0..1)
   shadowVis   : direct-light visibility 0..1 (from lib/shadow.glsl)
   worldLDir   : world-space direction toward the dominant light (sun or moon)
   worldSunDir : world-space direction toward the SUN (drives atmosphere colour)
   worldPos    : world-space position (feet + cameraPosition) for cloud shadow
   dayFactor   : 0 night .. 1 day (from alDayFactor)
   ao          : ambient-occlusion term (1 = unoccluded)
*/
vec3 alLightPhase1(vec3 albedoLin, vec3 worldN, vec2 lm,
                   float shadowVis, vec3 worldLDir, vec3 worldSunDir,
                   vec3 worldPos, float dayFactor, float ao) {

    // --- Direct sun / moon ------------------------------------------------
    // Colour is atmosphere-driven (warm amber bias baked into alDirectColor).
    // Cloud shadow softens the direct key where a cumulus passes the sun.
    // dayFactor (from alDayFactor — the pack's single shared day/night ramp, the
    // same signal the night sky / fog agree on) dims the MOON key after dark via
    // AL_NIGHT_DIRECT_SCALE: part of the 0.3.2 darker-night retune. NOON is
    // untouched (dayFactor==1 -> scale 1.0).
    float NdotL     = max(dot(worldN, worldLDir), 0.0);
#if defined AL_DIM_NETHER
    // Nether: no sun/moon key — the world is lit by ember ambient + blocklight.
    vec3  direct = vec3(0.0);
#elif defined AL_DIM_END
    // End: a cool violet key from the (existing) End light direction, softly wrapped
    // so the sunless dimension still has gentle directionality. No cloud shadow.
    float endWrap = NdotL * 0.6 + 0.4;
    vec3  direct  = AL_END_KEY * (endWrap * shadowVis * AL_DIRECT_BOOST * 0.5);
#else
    float cloudSh   = alCloudShadow(worldPos);
    float directNight = mix(AL_NIGHT_DIRECT_SCALE, 1.0, dayFactor);
    // SKY-ACCESS GATE (5.0.6): enclosed surfaces (no sky lightmap) must receive NO
    // direct sun/moon. The shadow map only covers a limited range, so deep caves /
    // anything roofed beyond it were being lit by the sun leaking straight through.
    // Gating the direct key by the sky lightmap kills that: lm.y ~ 0 (underground)
    // -> no direct light; open sky -> full. Shadowed-but-open surfaces (sky access
    // > 0) are unaffected — they still get the key, dimmed by shadowVis.
    // 5.0.11: widened + raised the window (was 0.0..0.12) — the sky lightmap bleeds
    // a little way into cave mouths / under overhangs, so a low threshold still let
    // full sun leak onto clearly-covered surfaces. Requiring more sky access before
    // full direct light (and squaring for a sharper low-end cutoff) kills that leak
    // while open ground (lm.y ~ 1) is untouched.
    float skyAccess = smoothstep(0.05, 0.32, lm.y);
    skyAccess *= skyAccess;
    // 0.4.3 (ISSUE 7/8): strengthen the direct key so the sun-facing side clearly
    // reads BRIGHTER than the shadowed side. AL_DIRECT_BOOST lifts the key while
    // the ambient below is trimmed, so overall exposure moves little but the
    // lit/shadow CONTRAST rises — surfaces gain a real lit side and a dark side.
    vec3  direct  = alDirectColor(worldSunDir)
                  * (NdotL * shadowVis * cloudSh * directNight * AL_DIRECT_BOOST * skyAccess);
#endif

    // --- Hemisphere ambient (the fill) ------------------------------------
    float up      = worldN.y * 0.5 + 0.5;                 // 0 down .. 1 up
#if defined AL_DIM_NETHER
    // Nether: flat warm-ember ambient everywhere (no sky, so NO skyLm gate — the
    // gate would kill all light since Nether sky-lightmap is 0). A gentle top/down
    // wrap keeps some shape. Blocklight (below) still dominates near sources.
    vec3  ambient   = AL_NETHER_AMBIENT * (0.55 + 0.45 * up) * AMBIENT_INTENSITY;
    vec3  nightFloor = vec3(0.0);
#elif defined AL_DIM_END
    // End: purple ambient fill, hemispheric, not sky-gated (End sky-lightmap is 0
    // away from portals). Sits above black so terrain reads in the violet gloom.
    vec3  ambient   = AL_END_AMBIENT * (0.5 + 0.5 * up) * AMBIENT_INTENSITY;
    vec3  nightFloor = vec3(0.0);
#else
    // Overworld: atmosphere-driven hemisphere sky fill.
    vec3  skyCol  = alAmbientColor(worldSunDir);          // atmosphere-driven
    vec3  hemiCol = mix(AL_AMBIENT_GROUND, skyCol, up);
    // Field fix #2: desaturate the cool tint toward grey as the sky lightmap falls
    // so caves / deep water don't glow purple.
    float skySat  = smoothstep(AL_AMBIENT_DESAT_LO, AL_AMBIENT_DESAT_HI, lm.y);
    hemiCol       = mix(vec3(alLuminance(hemiCol)), hemiCol, skySat);
    // 0.4.3 (ISSUE 7): lower wrap FLOOR so backfacing/down faces get less fill ->
    // a clear top-lit gradient (lit side vs darker shadow side).
    float wrap    = 0.30 + 0.70 * up;
    float skyLm   = lm.y * lm.y;
    float nightLift = mix(AL_NIGHT_AMBIENT_LIFT * NIGHT_BRIGHTNESS, 1.0, dayFactor);
    vec3  ambient = hemiCol * (skyLm * wrap) * AMBIENT_INTENSITY * nightLift
                  * AL_AMBIENT_SCALE;
    // Cool-blue night minimum, sky-gated so caves stay dark.
    vec3 nightFloor = AL_NIGHT_FLOOR * NIGHT_BRIGHTNESS
                    * (skyLm * (1.0 - dayFactor));
#endif

    // --- Warm block light -------------------------------------------------
    float bl     = lm.x;
    float blCore = pow(bl, AL_BLOCKLIGHT_FALLOFF);        // perceptual core shape
    float blTail = bl * bl;                               // gentler, longer reach
    float blAmt  = mix(blCore, blTail, AL_BLOCKLIGHT_TAIL);

#ifdef BLOCKLIGHT_TINT
    vec3 blTint = mix(AL_TORCH_EMBER, AL_TORCH_CANDLE, bl);
#else
    vec3 blTint = AL_TORCH_TINT;
#endif
    vec3  block = blTint * (blAmt * AL_BLOCKLIGHT_BASE * BLOCKLIGHT_INTENSITY);

    // --- Fake indirect bounce floor --------------------------------------
    vec3 bounce = AL_BOUNCE * BOUNCE_INTENSITY;

    // AO multiplies the INDIRECT terms only (sky ambient, night floor, warm
    // blocklight, bounce). The direct sun/moon key is untouched.
    vec3 indirect = (ambient + nightFloor + block + bounce) * ao;

    // Sum light, then modulate by surface albedo.
    vec3 lightSum = direct + indirect;
    return albedoLin * lightSum;
}

// Backwards-compatible overload (no AO) for the forward translucent passes
// (water, hand_water, particles, entities_translucent). They have no
// screen-space AO buffer to sample, so they light with full ambient (ao = 1).
vec3 alLightPhase1(vec3 albedoLin, vec3 worldN, vec2 lm,
                   float shadowVis, vec3 worldLDir, vec3 worldSunDir,
                   vec3 worldPos, float dayFactor) {
    return alLightPhase1(albedoLin, worldN, lm, shadowVis, worldLDir,
                         worldSunDir, worldPos, dayFactor, 1.0);
}

#endif // AL_LIB_LIGHTING
