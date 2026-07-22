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
                   float shadowVis, vec3 worldLDir, float dayFactor,
                   float ao) {

    // --- Direct sun / moon ------------------------------------------------
    float NdotL   = max(dot(worldN, worldLDir), 0.0);
    vec3  direct  = alDirectLightColor(dayFactor) * NdotL * shadowVis;

    // --- Hemisphere sky ambient (the cool fill) ---------------------------
    // Blend a cool up-facing sky tint with a warmer down-facing ground tint,
    // then wrap it so even faces turned away from the sky pick up some fill.
    float up      = worldN.y * 0.5 + 0.5;                 // 0 down .. 1 up
    vec3  hemiCol = mix(AL_AMBIENT_GROUND, AL_AMBIENT_SKY, up);

    // Field fix #2: the cool blue-purple tint is saturated, which reads as a
    // strong purple cast wherever the sky lightmap is low (caves, terrain seen
    // through/under water). Desaturate toward a luminance-preserving grey as the
    // RAW sky lightmap falls below ~AL_AMBIENT_DESAT_HI, keeping the full cool
    // tint only in genuinely sky-exposed shade. Luminance-preserving so the
    // overall brightness (and night-floor readability) is untouched.
    float skySat  = smoothstep(AL_AMBIENT_DESAT_LO, AL_AMBIENT_DESAT_HI, lm.y);
    hemiCol       = mix(vec3(alLuminance(hemiCol)), hemiCol, skySat);

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
    // Field fix #1: a night campfire must visibly warm a ~6-block radius while
    // staying below sun intensity. The old curve (bl*bl*(...)) crushed the mid
    // range, so torchlight died within ~3 blocks. Replace it with a perceptual
    // falloff (pow ~AL_BLOCKLIGHT_FALLOFF) blended with a gentler quadratic tail
    // so distant grass still catches a warm ember glow, then lift the whole term
    // with AL_BLOCKLIGHT_BASE. Peak (bl==1, adjacent to a level-15 source) is
    // tuned to sit just under the warm-sun luminance.
    float bl     = lm.x;
    float blCore = pow(bl, AL_BLOCKLIGHT_FALLOFF);        // perceptual core shape
    float blTail = bl * bl;                               // gentler, longer reach
    float blAmt  = mix(blCore, blTail, AL_BLOCKLIGHT_TAIL);

    // Warm blocklight tint. The Mac path has no per-source colour (that is the
    // Phase-6 flood-fill tier), so approximate a flame's colour temperature by
    // ramping the tint with blocklight level: candle-amber near the source,
    // fading to a deep ember-orange out at the dim edge of its reach.
#ifdef BLOCKLIGHT_TINT
    vec3 blTint = mix(AL_TORCH_EMBER, AL_TORCH_CANDLE, bl);
#else
    vec3 blTint = AL_TORCH_TINT;
#endif
    vec3  block = blTint * (blAmt * AL_BLOCKLIGHT_BASE * BLOCKLIGHT_INTENSITY);

    // --- Fake indirect bounce floor --------------------------------------
    vec3 bounce = AL_BOUNCE * BOUNCE_INTENSITY;

    // Ambient occlusion multiplies the INDIRECT terms only (sky ambient, night
    // floor, warm blocklight, bounce). The direct sun/moon key is untouched —
    // GTAO is a hemispherical-visibility estimate for ambient light, and
    // occluding the sharp direct light would double up with the shadow map.
    vec3 indirect = (ambient + nightFloor + block + bounce) * ao;

    // Sum light, then modulate by surface albedo.
    vec3 lightSum = direct + indirect;
    return albedoLin * lightSum;
}

// Backwards-compatible overload (no AO) for the forward translucent passes
// (water, hand_water, particles, entities_translucent, weather). They have no
// screen-space AO buffer to sample, so they light with full ambient (ao = 1).
vec3 alLightPhase1(vec3 albedoLin, vec3 worldN, vec2 lm,
                   float shadowVis, vec3 worldLDir, float dayFactor) {
    return alLightPhase1(albedoLin, worldN, lm, shadowVis, worldLDir, dayFactor, 1.0);
}

#endif // AL_LIB_LIGHTING
