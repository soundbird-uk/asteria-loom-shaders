#version 330 compatibility
#include "/settings.glsl"
#include "/lib/jitter.glsl"

/*
 gbuffers_water (vertex) — Phase 4 real water. Forward-lit AND (new) surface
 data for the SSR/absorption composite pass. We forward everything the shared
 lighting model needs plus the player-space position, which the fragment stage
 turns into a world position for the procedural ripple wave-noise. The last
 position line applies the TAA sub-pixel jitter (lib/jitter.glsl, identity when
 TAA is off) — water must jitter with every other jittered gbuffer or it
 shimmers against the resolved scene.
*/

uniform mat4 gbufferModelViewInverse;

// Block-ID attribute (Iris fills mc_Entity.x from block.properties; = 10001.0
// for the water blocks we mapped, something else for glass/ice/slime/etc.).
in vec4 mc_Entity;

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;
out vec3 wnormal;
out vec3 playerPos;
// 1.0 for real water, 0.0 for every other translucent that routes through this
// program. `flat` (330-core) — it is a per-primitive classification, not a value
// to interpolate. The fragment stage gates ALL water-specific behaviour on it.
flat out float isWater;
flat out float isNetherPortal;   // 1.0 for nether_portal (block.properties 10002)

void main() {
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
    gl_Position = gl_ProjectionMatrix * viewPos;   // == ftransform()

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
    isWater        = (mc_Entity.x == 10001.0) ? 1.0 : 0.0;
    isNetherPortal = (mc_Entity.x == 10002.0) ? 1.0 : 0.0;

    vec3 viewN = normalize(gl_NormalMatrix * gl_Normal);
    wnormal = mat3(gbufferModelViewInverse) * viewN;
    playerPos = (gbufferModelViewInverse * viewPos).xyz;

    gl_Position = alJitter(gl_Position);   // TAA jitter (identity when TAA off)
}
