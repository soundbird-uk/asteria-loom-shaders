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
    float NdotL   = max(dot(worldN, worldLDir), 0.0);
    float cloudSh = alCloudShadow(worldPos);
    vec3  direct  = alDirectColor(worldSunDir) * (NdotL * shadowVis * cloudSh);

    // --- Hemisphere sky ambient (the cool fill) ---------------------------
    // The upper-hemisphere sky colour now comes from the atmosphere model
    // (day-scaled, dusk-warming); the lower hemisphere keeps the warm ground
    // bounce identity. Wrap so faces turned from the sky still pick up fill.
    float up      = worldN.y * 0.5 + 0.5;                 // 0 down .. 1 up
    vec3  skyCol  = alAmbientColor(worldSunDir);          // atmosphere-driven
    vec3  hemiCol = mix(AL_AMBIENT_GROUND, skyCol, up);

    // Field fix #2: desaturate the cool tint toward luminance-preserving grey as
    // the RAW sky lightmap falls, so caves / deep water don't glow purple. Full
    // cool tint only where genuinely sky-exposed.
    float skySat  = smoothstep(AL_AMBIENT_DESAT_LO, AL_AMBIENT_DESAT_HI, lm.y);
    hemiCol       = mix(vec3(alLuminance(hemiCol)), hemiCol, skySat);

    float wrap    = 0.6 + 0.4 * up;                       // soft wrap term
    float skyLm   = lm.y * lm.y;                          // sky lightmap, eased
    // Day scaling lives inside alAmbientColor (0.18 at night .. 1.0 by day). That
    // 0.18 night floor left open terrain ~30% darker than the 0.1.1 build the
    // field confirmed as "correct night" (which held ~0.35x). Re-lift the NIGHT
    // ambient here — the shared model, and NOT the atmosphere core this fix must
    // not touch — by mix(AL_NIGHT_AMBIENT_LIFT, 1.0, dayFactor): night rises to
    // the 0.1.1 level (open snow within ~5%) while NOON is provably unchanged
    // (dayFactor == 1 -> factor 1.0).
    float nightLift = mix(AL_NIGHT_AMBIENT_LIFT, 1.0, dayFactor);
    vec3  ambient = hemiCol * (skyLm * wrap) * AMBIENT_INTENSITY * nightLift;

    // --- Night floor ------------------------------------------------------
    // A cool-blue minimum, gated by sky exposure so caves stay dark but open
    // terrain never goes pitch black under the night sky.
    vec3 nightFloor = AL_NIGHT_FLOOR * NIGHT_BRIGHTNESS
                    * (skyLm * (1.0 - dayFactor));

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
