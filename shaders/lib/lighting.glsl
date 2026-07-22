#ifndef AL_LIB_LIGHTING
#define AL_LIB_LIGHTING

/*
 lib/lighting.glsl — the Phase-1 lighting model.

 This is the ONE place lighting math lives. It is shared verbatim by the
 deferred pass (opaque G-buffer shading) and by the forward translucent
 passes (water, hand water) so a lit water surface matches the terrain around
 it. Keep it self-contained and free of pass-specific sampler reads: callers
 hand in everything (decoded albedo, world normal, lightmap, shadow term,
 light direction, day factor).

 THE LOOK (see identity constants in settings.glsl):
   - warm amber key light (sun), cooler dim moon at night
   - cool blue-purple hemisphere sky-fill so shadows read cool (the pack's
     core warm/cool contrast)
   - warm block-light
   - cool-blue night floor so open terrain stays readable after dark
   - a faint bounce lift so coloured faces are never pure black
 All maths is LINEAR; the caller decodes albedo sRGB->linear and outputs
 linear HDR to colortex0.
*/

#include "/lib/common.glsl"
#include "/lib/color.glsl"

// Day/night blend from the sun's world-space height. 1 = sun up, 0 = night.
// A soft ramp around the horizon gives a gentle dawn/dusk transition.
float alDayFactor(vec3 worldSunDir) {
    return alSmooth(smoothstep(-0.06, 0.16, worldSunDir.y));
}

// Direct light colour: warm amber sun by day, cool dim moon by night.
// Never neutral white — the amber bias is intentional at all times.
vec3 alDirectLightColor(float dayFactor) {
    vec3 moon = AL_MOON_TINT * 0.16;   // moonlight is much dimmer than day
    return mix(moon, AL_SUN_TINT, dayFactor) * SUN_INTENSITY;
}

/*
 Core shade. Returns linear HDR radiance.

   albedoLin : albedo already decoded to linear
   worldN    : world-space surface normal (normalized)
   lm        : lightmap (x = block 0..1, y = sky 0..1)
   shadowVis : direct-light visibility 0..1 (from lib/shadow.glsl)
   worldLDir : world-space direction toward the dominant light (sun or moon)
   dayFactor : 0 night .. 1 day (from alDayFactor)
*/
vec3 alLightPhase1(vec3 albedoLin, vec3 worldN, vec2 lm,
                   float shadowVis, vec3 worldLDir, float dayFactor) {

    // --- Direct sun / moon ------------------------------------------------
    float NdotL   = max(dot(worldN, worldLDir), 0.0);
    vec3  direct  = alDirectLightColor(dayFactor) * NdotL * shadowVis;

    // --- Hemisphere sky ambient (the cool fill) ---------------------------
    // Blend a cool up-facing sky tint with a warmer down-facing ground tint,
    // then wrap it so even faces turned away from the sky pick up some fill.
    float up      = worldN.y * 0.5 + 0.5;                 // 0 down .. 1 up
    vec3  hemiCol = mix(AL_AMBIENT_GROUND, AL_AMBIENT_SKY, up);
    float wrap    = 0.6 + 0.4 * up;                       // soft wrap term
    float skyLm   = lm.y * lm.y;                          // sky lightmap, eased
    // Ambient is strongest by day, dimmer (but present) at night.
    float ambDay  = mix(0.35, 1.0, dayFactor);
    vec3  ambient = hemiCol * (skyLm * wrap * ambDay) * AMBIENT_INTENSITY;

    // --- Night floor ------------------------------------------------------
    // A cool-blue minimum, gated by sky exposure so caves stay dark but open
    // terrain never goes pitch black under the night sky.
    vec3 nightFloor = AL_NIGHT_FLOOR * NIGHT_BRIGHTNESS
                    * (skyLm * (1.0 - dayFactor));

    // --- Warm block light -------------------------------------------------
    // Eased curve so torches fall off pleasantly rather than linearly.
    float bl    = lm.x;
    float blAmt = bl * bl * (bl * 0.6 + 0.4);
    vec3  block = AL_TORCH_TINT * (blAmt * BLOCKLIGHT_INTENSITY);

    // --- Fake indirect bounce floor --------------------------------------
    vec3 bounce = AL_BOUNCE * BOUNCE_INTENSITY;

    // Sum light, then modulate by surface albedo.
    vec3 lightSum = direct + ambient + nightFloor + block + bounce;
    return albedoLin * lightSum;
}

#endif // AL_LIB_LIGHTING
