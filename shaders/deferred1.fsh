#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/space.glsl"
#include "/lib/shadow.glsl"
#include "/lib/contact.glsl"
#include "/lib/lighting.glsl"

/*
 deferred1 (fragment) — the main opaque shading pass.

 (Phase 1's `deferred` lighting pass, renamed to deferred1 in Phase 2: the
 `deferred` slot now runs the GTAO pass ahead of this one. The shadow/lighting
 logic is unchanged; the only addition here is consuming the AO term from
 colortex4.)

 Reads the G-buffer, reconstructs world position from depth, evaluates the
 shared lighting model, and writes linear HDR back to colortex0.
 Sky pixels (depth == 1.0) pass the sky colour (already in colortex0 from the
 skybasic/skytextured passes) straight through untouched.

 NOTE: gbufferProjectionInverse / gbufferModelViewInverse are declared in
 lib/space.glsl (included above) — do NOT redeclare them here.

 AO: colortex4.r (1 = unoccluded) is read ONLY behind `#ifdef AO`. The AO pass
 (deferred) is dispatched only when AO is on; with AO off, colortex4 is a
 cleared (0,0) buffer whose .r would BLACKEN the ambient terms — hence the
 compile-time gate with a 1.0 fallback, never a runtime read of cleared data.

 Sampler count (max over branches):
   colortex0,1,2,3 + depthtex0                                   = 5
   + colortex4 (AO)                                              = 1  (AO on)
   + shadow samplers via lib/shadow.glsl (SHADOWS):
       hardware-flag path : shadowtex0 + shadowtex1HW + noisetex = 3  -> 9 total
       Mac fallback path  : shadowtex1 + noisetex               = 2  -> 8 total
   contact shadows (CONTACT_SHADOWS) reuse depthtex0/noisetex (no new sampler).
 Well within the 16-sampler Mac limit and the contract's <=14 budget.
*/

uniform sampler2D colortex0;   // sky / scene HDR
uniform sampler2D colortex1;   // albedo
uniform sampler2D colortex2;   // normal + lightmap
uniform sampler2D colortex3;   // matID + flags
#ifdef AO
uniform sampler2D colortex4;   // AO .r (1 = unoccluded), confidence .g
#endif
uniform sampler2D depthtex0;

uniform vec3 sunPosition;          // view space
uniform vec3 shadowLightPosition;  // view space, toward dominant light

in vec2 texcoord;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    float depth = texture(depthtex0, texcoord).r;

    // Sky: pass through whatever the sky passes already wrote.
    if (depth >= 1.0) {
        outColor = texture(colortex0, texcoord);
        return;
    }

    // --- Decode G-buffer --------------------------------------------------
    vec3  albedoSrgb = texture(colortex1, texcoord).rgb;
    vec3  albedoLin  = alSrgbToLinear(albedoSrgb);

    vec4  nl = texture(colortex2, texcoord);
    vec3  N  = alDecodeNormal(nl.rg);
    vec2  lm = nl.ba;                       // block, sky

    int matID = alDecodeMatID(texture(colortex3, texcoord).r);

    // Untextured primitives (selection outline, hitboxes, leads) must NOT be
    // sun/ambient shaded — pass their stored colour straight through.
    if (matID == AL_MATID_BASIC) {
        outColor = vec4(albedoLin, 1.0);
        return;
    }

    // --- Reconstruct position + light directions --------------------------
    vec3 viewPos   = alScreenToView(texcoord, depth);
    vec3 playerPos = alViewToPlayer(viewPos);

    vec3 wLightDir = normalize(alViewDirToWorld(shadowLightPosition));
    vec3 wSunDir   = normalize(alViewDirToWorld(sunPosition));
    float dayFactor = alDayFactor(wSunDir);

    // --- Shadow + shade ---------------------------------------------------
    float NdotL = max(dot(N, wLightDir), 0.0);
    // The hand is drawn with a separate (near) projection, so reconstructing
    // its world position with gbufferProjectionInverse is wrong and makes it
    // self-shadow flicker. Phase 1: skip shadowing hand pixels entirely.
    // (Proper fix later: a dedicated hand depth/projection path.)
    float shadowVis = (matID == AL_MATID_HAND)
                    ? 1.0
                    : alShadowVisibility(playerPos, N, NdotL);

    // Screen-space contact shadows multiply the shadow term for fine detail the
    // shadow map is too coarse to resolve. Hand exempt (its near projection makes
    // view reconstruction here invalid), same as the shadow-map path.
#ifdef CONTACT_SHADOWS
    if (matID != AL_MATID_HAND && NdotL > 0.0) {
        vec3  viewLightDir = normalize(shadowLightPosition);
        float dither = texture(noisetex, gl_FragCoord.xy / 256.0).x;
        shadowVis *= alContactShadow(depthtex0, viewPos, viewLightDir, dither);
    }
#endif

    // Ambient occlusion: darkens ONLY the indirect terms (sky ambient, night
    // floor, blocklight, bounce) — never the direct sun/moon. AO_STRENGTH scales
    // the effect via pow (>1 deepens crevices, <1 softens). Gated at compile
    // time: with AO off, colortex4 is cleared and must not be read.
    float ao = 1.0;
#ifdef AO
    ao = texture(colortex4, texcoord).r;
    ao = pow(alSaturate(ao), AO_STRENGTH);
#endif

    vec3 color = alLightPhase1(albedoLin, N, lm, shadowVis, wLightDir, dayFactor, ao);

    outColor = vec4(color, 1.0);
}
