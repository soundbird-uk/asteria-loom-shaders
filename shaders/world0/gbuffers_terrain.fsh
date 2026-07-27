#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_terrain (fragment) — writes the opaque G-buffer.
 Sampler count: 1 (gtexture)

 5.4.0: also stores the EMITTER LIGHT LEVEL in colortex3.g for light-emitting
 blocks, which is what the deferred2 coloured-block-light gather weights each
 emitter by (see lib/encoding.glsl for why that channel is free). Terrain is the
 only writer: every vanilla light source that matters — torches, lava, fire,
 froglights, glowstone, lanterns, campfires, sea lanterns, shroomlights — is
 terrain geometry. Block entities / entities / particles keep writing 0 there,
 which the gather reads as "not an emitter" and skips.
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
flat in float emissive;   // 1.0 for light-emitting blocks (block.properties 10040)
flat in float emitLevel;  // emitter light level 0..1 from at_midBlock.w (0 = derive here)
flat in float endFrame;   // 1.0 for end_portal_frame (10041) — eye-only glow
flat in float reflAmt;    // reflectivity 0..1 (block.properties 10050/10051)
flat in float metalness;  // 1.0 = metal (albedo-tinted reflection)

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;    // colortex1
layout(location = 1) out vec4 outNormalLm;  // colortex2
layout(location = 2) out vec4 outMaterial;  // colortex3

void main() {
    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;   // cutout foliage etc.

    // Light sources tag matID EMISSIVE so deferred1 self-illuminates them from
    // this same albedo (their own texture colour) -> coloured glow + bloom halo.
    int matID = (emissive > 0.5) ? AL_MATID_EMISSIVE : AL_MATID_TERRAIN;

    // END PORTAL FRAME: glow ONLY the Eye of Ender, not the whole block. The eye is
    // teal (green+blue high, red low); the frame stone is pale endstone-yellow
    // (red+green high, blue low). Where the pixel reads teal, tag it EMISSIVE and
    // push the glow brighter/greener; the stone stays ordinary TERRAIN (normally
    // lit, NOT lightened — the old blanket-emissive bug).
    if (endFrame > 0.5) {
        vec3  a    = albedo.rgb;
        float teal = smoothstep(0.04, 0.18, a.g - a.r)
                   * smoothstep(-0.02, 0.12, a.b - a.r);
        if (teal > 0.5) {
            matID      = AL_MATID_EMISSIVE;
            albedo.rgb = a * vec3(0.85, 1.40, 1.30);          // brighter teal eye glow
        }
    }

    // Emitter light level -> colortex3.g (0 on everything that is not a light
    // source, which is also alEncodeFlags(AL_FLAG_NONE) — see encoding.glsl).
    float emit = 0.0;
#ifdef COLORED_BLOCKLIGHT
    // Compile-time gated: with the feature off nothing reads this channel, so it
    // stays 0.0 (== alEncodeFlags(AL_FLAG_NONE), the pre-5.4.0 value) and the
    // luminance fallback below is not even compiled in.
    if (matID == AL_MATID_EMISSIVE) {
        // Prefer the real light level from at_midBlock.w (vertex stage). When
        // that attribute is unavailable it arrives as 0 and we derive a stand-in
        // from albedo luminance — deliberately the SAME smoothstep deferred1
        // uses for self-illumination, so a lantern's dark metal frame reads as
        // "not emitting" here exactly as it does there and the gather picks up
        // the glass colour rather than the housing.
        emit = emitLevel;
        if (emit <= 0.0) {
            emit = smoothstep(0.22, 0.55, alLuminance(alSrgbToLinear(albedo.rgb)));
        }
    }
#endif

    outAlbedo   = vec4(albedo.rgb, 1.0);                       // a = AO spare
    outNormalLm = vec4(alEncodeNormal(wnormal), lmcoord);      // rg normal, ba lightmap
    // colortex3: r matID, g emitter level (== flags NONE when 0), b reflectivity,
    // a metalness (composite SSR).
    outMaterial = vec4(alEncodeMatID(matID),
                       alEncodeEmission(emit), reflAmt, metalness);
}
