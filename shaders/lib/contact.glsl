#ifndef AL_LIB_CONTACT
#define AL_LIB_CONTACT

/*
 lib/contact.glsl — screen-space contact shadows (Phase 2).

 A short view-space raymarch from the shaded point toward the sun/moon. Where
 the depth buffer shows geometry crossing the ray within a thin thickness
 window, the point is in a fine-scale contact shadow the shadow map is too
 coarse to resolve (block bases, pressed-together geometry, small detail).

 Called ONLY from deferred (the opaque lighting pass); the result MULTIPLIES
 the PCSS shadow term. Behind `#ifdef CONTACT_SHADOWS`. The hand is exempted by
 the caller (matID == AL_MATID_HAND), same as the shadow-map path.

 Kept decoupled from the caller's sampler names: the scene depth sampler is
 passed in as a parameter (legal in GLSL 3.30). depthtex + the inverse
 projection (for view reconstruction) come via lib/space.glsl.
 Sampler count contribution: 0 (depth sampler is the caller's; only the forward
 gbufferProjection uniform is added).
*/

#include "/lib/common.glsl"
// space.glsl gives alScreenToView + gbufferProjectionInverse (guarded re-include)
#include "/lib/space.glsl"

#ifdef CONTACT_SHADOWS

uniform mat4 gbufferProjection;   // view -> clip (project ray samples to screen)

/*
   depthTex      : scene depth (depthtex0) — passed by the caller
   viewPos       : shaded point in view space
   viewLightDir  : normalized view-space direction TOWARD the light
   dither        : 0..1 per-pixel start jitter (breaks up banding)
 Returns 1.0 = unshadowed, 0.0 = a nearby occluder was hit.
*/
float alContactShadow(sampler2D depthTex, vec3 viewPos, vec3 viewLightDir, float dither) {
    float stepLen = AL_CONTACT_LENGTH / float(AL_CONTACT_STEPS);
    vec3  rayStep = viewLightDir * stepLen;

    // Start one dithered step off the surface so we never self-intersect.
    vec3 rayPos = viewPos + rayStep * (1.0 + dither);

    for (int i = 0; i < AL_CONTACT_STEPS; i++) {
        vec4 clip = gbufferProjection * vec4(rayPos, 1.0);
        if (clip.w <= 0.0) break;                 // behind the camera
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;  // off-screen

        float sceneDepth = texture(depthTex, uv).r;
        if (sceneDepth < 1.0) {
            // Scene view-space position under this screen sample.
            vec3 sceneView = alScreenToView(uv, sceneDepth);
            // View looks down -Z: a larger (less negative) z is closer to camera.
            // The ray is occluded when the scene surface sits IN FRONT of the ray
            // by more than a bias but within a thin thickness (a real occluder,
            // not a distant background).
            float diff = sceneView.z - rayPos.z;
            if (diff > AL_CONTACT_BIAS && diff < AL_CONTACT_THICKNESS) {
                return 0.0;
            }
        }
        rayPos += rayStep;
    }
    return 1.0;
}

#endif // CONTACT_SHADOWS
#endif // AL_LIB_CONTACT
