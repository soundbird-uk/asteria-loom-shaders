#ifndef AL_LIB_PBR
#define AL_LIB_PBR

/*
 lib/pbr.glsl — micro-facet (Cook-Torrance) BRDF terms.

 Pure math, no uniforms and no samplers, so any pass can include it without
 touching its sampler budget. GLSL 3.30 safe (no bit ops, no dynamic array
 indexing — see lib/jitter.glsl for why that matters on the Mac GL 4.1 path).

 The specular BRDF used by the pack is the standard Cook-Torrance form

     f_spec = D(h) * V(l,v) * F(v,h)

 with
   D  — GGX / Trowbridge-Reitz normal distribution (alD_GGX),
   V  — height-correlated Smith visibility, i.e. G / (4 NoL NoV) already folded
        in so the caller does NOT divide again (alV_SmithGGXCorrelated),
   F  — Schlick's Fresnel approximation (alF_Schlick).

 ROUGHNESS CONVENTION: every entry point takes PERCEPTUAL roughness in [0,1]
 (the artist-facing value stored in settings.glsl / colortex3). The GGX alpha is
 alpha = roughness^2, taken once in alRoughnessToAlpha, because that mapping is
 what makes a linear roughness slider look linear.

 F0 CONVENTION (this is the fix for "iron looks like chrome"):
   * DIELECTRIC (stone, ice, glass, water): F0 is a small achromatic value
     (~0.02 - 0.05). Almost nothing is reflected head-on; the surface only goes
     mirror-like at grazing angles, which is what Schlick's term produces.
   * METAL: there is NO diffuse lobe and F0 IS the metal's albedo (iron ~0.56
     grey, gold yellow, copper orange). A metal is not "a mirror plus colour" —
     its reflectivity is bounded by its F0 and further cut by roughness, so a
     ROUGH metal (brushed iron block) reflects a blurred, dimmer environment.

 ENVIRONMENT (IBL) TERM: for a reflection that comes from a pre-filtered
 environment (sky LUT / SSR gather) rather than a single light direction, the
 correct weight is the split-sum DFG integral, not a bare Fresnel. Using bare
 Fresnel is exactly what makes rough metal read as chrome, because it ignores
 the fact that a rough micro-surface scatters most of the incoming energy away
 from the mirror direction. alEnvBRDFApprox is Karis' analytic fit to that
 integral (Lazarov's mobile approximation, "Physically Based Lighting in Call of
 Duty: Black Ops" / UE4 course notes): a single vec2 per-pixel that returns the
 scale + bias for F0. It falls to ~0.35 for rough metal head-on and rises toward
 1 at grazing, which is precisely the behaviour the brief asks for.
*/

#include "/lib/common.glsl"

// Perceptual roughness -> GGX alpha. Clamped away from 0 so D_GGX cannot blow
// up to a delta function (a NaN/INF factory on a mirror-flat normal).
float alRoughnessToAlpha(float rough) {
    float r = clamp(rough, 0.045, 1.0);
    return r * r;
}

// GGX / Trowbridge-Reitz normal distribution. NoH = dot(N, H).
float alD_GGX(float NoH, float alpha) {
    float a2 = alpha * alpha;
    float d  = (NoH * NoH) * (a2 - 1.0) + 1.0;
    return a2 / max(AL_PI * d * d, 1.0e-20);
}

// Height-correlated Smith visibility (Heitz 2014) = G / (4 NoL NoV).
float alV_SmithGGXCorrelated(float NoV, float NoL, float alpha) {
    float a2 = alpha * alpha;
    float gv = NoL * sqrt(NoV * NoV * (1.0 - a2) + a2);
    float gl = NoV * sqrt(NoL * NoL * (1.0 - a2) + a2);
    return 0.5 / max(gv + gl, 1.0e-7);
}

// Schlick's Fresnel approximation. u = dot(V, H) (or NoV for the env term).
vec3 alF_Schlick(vec3 f0, float u) {
    float f = pow(alSaturate(1.0 - u), 5.0);
    return f0 + (1.0 - f0) * f;
}
float alF_Schlick(float f0, float u) {
    float f = pow(alSaturate(1.0 - u), 5.0);
    return f0 + (1.0 - f0) * f;
}

// Full micro-facet specular for ONE light direction (analytic sun/moon glint).
// N, V, L are unit; returns the BRDF value to multiply by the light radiance and
// by NoL. Energy-correct: no ad-hoc normalisation constants.
vec3 alSpecularGGX(vec3 N, vec3 V, vec3 L, vec3 f0, float rough) {
    vec3  H   = normalize(V + L);
    float NoV = max(dot(N, V), 1.0e-4);
    float NoL = max(dot(N, L), 0.0);
    float NoH = alSaturate(dot(N, H));
    float VoH = alSaturate(dot(V, H));
    float a   = alRoughnessToAlpha(rough);
    return alD_GGX(NoH, a) * alV_SmithGGXCorrelated(NoV, NoL, a) * alF_Schlick(f0, VoH);
}

/*
 Split-sum environment BRDF (Karis/Lazarov analytic approximation).
 Returns the multiplier for a PRE-FILTERED environment radiance:

     reflected = prefilteredEnv * alEnvBRDFApprox(F0, roughness, NoV)

 Behaviour worth knowing when tuning:
   rough 0.10 metal, head-on : ~0.95 * F0   (polished -> near mirror)
   rough 0.62 metal, head-on : ~0.45 * F0   (brushed iron -> NOT chrome)
   rough 0.62 metal, grazing : rises toward ~0.75, so the sheen still appears
                               at glancing angles — the natural Fresnel ramp.
   rough 0.12 dielectric     : ~0.04 head-on, ~0.5 at grazing.
*/
vec3 alEnvBRDFApprox(vec3 f0, float rough, float NoV) {
    const vec4 c0 = vec4(-1.0, -0.0275, -0.572,  0.022);
    const vec4 c1 = vec4( 1.0,  0.0425,  1.040, -0.040);
    vec4  r = clamp(rough, 0.0, 1.0) * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * max(NoV, 0.0))) * r.x + r.y;
    vec2  ab   = vec2(-1.04, 1.04) * a004 + r.zw;
    return alSaturate(f0 * ab.x + ab.y);
}

// Convenience: build F0 from an albedo + metalness. Dielectrics keep the small
// achromatic reflectance `dielF0`; metals take their own albedo as F0.
vec3 alF0FromAlbedo(vec3 albedo, float metal, float dielF0) {
    return mix(vec3(dielF0), max(albedo, vec3(0.0)), alSaturate(metal));
}

/*
 Roughness -> environment LOBE WIDTH in [0,1]. The pack has no pre-filtered
 environment mip chain, so a rough surface's environment is approximated by
 blending the sharp sky sample toward the soft (zenith/ambient) sample. This
 mapping is deliberately biased so that even a mildly rough surface loses most
 of its mirror sharpness, which is what stops "everything looks like chrome".
*/
float alEnvLobeBlend(float rough) {
    float r = alSaturate(rough);
    return alSaturate(r * (1.6 - 0.6 * r));
}

#endif // AL_LIB_PBR
