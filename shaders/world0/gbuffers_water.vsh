#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"
#include "/lib/water.glsl"

/*
 gbuffers_water (vertex) — real water + translucents. Forward-lit AND surface data
 for the SSR/absorption composite pass.

 5.1.0 WATER OVERHAUL: real GERSTNER wave DISPLACEMENT of the water surface (only
 real water — mc_Entity 10001 — is displaced; glass/ice/portals are left flat).
 The displacement is evaluated in WORLD space (lib/water.glsl) and rotated into
 view space before projection, so water visibly swells and its crests pinch. The
 UNDISPLACED world XZ is forwarded (waterRefXZ) so the fragment stage can evaluate
 the analytic Gerstner normal + Jacobian at the correct rest position (per-pixel,
 crisper than an interpolated vertex normal). The last position write applies the
 TAA sub-pixel jitter (lib/jitter.glsl, identity when TAA is off).
*/

uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;      // world-space camera (wave phase in world XZ)
uniform float frameTimeCounter;   // wave animation time

// Block-ID attribute (Iris fills mc_Entity.x from block.properties; = 10001.0
// for the water blocks we mapped, something else for glass/ice/slime/etc.).
in vec4 mc_Entity;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
out vec3 playerPos;
out vec2 waterRefXZ;             // UNDISPLACED world XZ (Gerstner rest position)
// 1.0 for real water, 0.0 for every other translucent that routes through this
// program. `flat` (330-core) — it is a per-primitive classification, not a value
// to interpolate. The fragment stage gates ALL water-specific behaviour on it.
flat out float isWater;
flat out float isNetherPortal;   // 1.0 for nether_portal (block.properties 10002)
flat out float isEndPortal;      // 1.0 for end_portal / end_gateway (10003) — fallback
                                 // route in case Iris draws it as a translucent
flat out float isIce;            // 1.0 for regular (translucent) ice (10052) — glassy SSR

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
    isWater        = (mc_Entity.x == 10001.0) ? 1.0 : 0.0;
    isNetherPortal = (mc_Entity.x == 10002.0) ? 1.0 : 0.0;
    isEndPortal    = (mc_Entity.x == 10003.0) ? 1.0 : 0.0;
    isIce          = (mc_Entity.x == 10052.0) ? 1.0 : 0.0;

    // Undisplaced world position (the Gerstner rest position for the fragment).
    vec3 worldPos = (gbufferModelViewInverse * viewPos).xyz + cameraPosition;
    waterRefXZ = worldPos.xz;

#ifdef WATER_WAVES
    // GERSTNER DISPLACEMENT — real water only. Evaluate the world-space wave
    // displacement and rotate it into view space (modelview inverse is orthonormal,
    // so world->view is its transpose) before projecting.
    if (isWater > 0.5) {
        vec3 disp = alGerstnerDisplace(worldPos.xz, frameTimeCounter);
        // SHORELINE SAFETY: damp the HORIZONTAL pull so water vertices can't drag
        // away from the solid block beside them and open a seam/void at the shore.
        // Vertical swell is kept in full; the fragment normal keeps full steepness.
        disp.xz *= AL_WATER_HORIZ_DAMP;
        viewPos.xyz += transpose(mat3(gbufferModelViewInverse)) * disp;
    }
#endif

    gl_Position = gl_ProjectionMatrix * viewPos;   // == ftransform() when undisplaced

    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal   = mat3(gbufferModelViewInverse) * viewN;
    playerPos = (gbufferModelViewInverse * viewPos).xyz;   // DISPLACED surface point

    gl_Position = alJitter(gl_Position);   // TAA jitter (identity when TAA off)
}
