#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"
#include "/lib/portal.glsl"

/*
 gbuffers_block (fragment) — block entities into the opaque G-buffer.

 END PORTAL / GATEWAY (block.properties 10003): vanilla renders these with a
 special block-entity renderer that Iris does not reproduce, so they read as flat
 black. We detect them via mc_Entity and paint a revamped 3D parallax STARFIELD
 with an ethereal glow (lib/portal.glsl). It is tagged AL_MATID_BASIC so deferred1
 passes it through UNLIT (self-lit look); the stars are bright so composite bloom
 gives the ethereal glow. We write the starfield through the sRGB store because
 deferred1's BASIC branch decodes colortex1 sRGB->linear.

 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform float alphaTestRef;
uniform vec3  cameraPosition;
uniform float frameTimeCounter;

in vec2 texcoord;
in vec2 lmcoord;
in vec4 glcolor;
in vec3 wnormal;
in vec3 playerPos;
flat in float isEndPortal;

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLm;
layout(location = 2) out vec4 outMaterial;

void main() {
    vec3 N = normalize(wnormal);

    if (isEndPortal > 0.5) {
        // Parallax starfield in the portal plane -> a 3D "deep space" look.
        vec3  Vw  = normalize(-playerPos);
        vec3  wp  = playerPos + cameraPosition;
        vec3  up0 = (abs(N.y) < 0.9) ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3  tang = normalize(cross(up0, N));
        vec3  bit  = cross(N, tang);
        vec2  pc  = vec2(dot(wp, tang), dot(wp, bit));
        vec2  par = vec2(dot(Vw, tang), dot(Vw, bit));
        vec3  star = alEndPortal(pc, par, frameTimeCounter);
        // Store sRGB so deferred1's BASIC pass-through (sRGB->linear) reproduces it.
        outAlbedo   = vec4(alLinearToSrgb(star), 1.0);
        outNormalLm = vec4(alEncodeNormal(N), lmcoord);
        outMaterial = vec4(alEncodeMatID(AL_MATID_BASIC),
                           alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
        return;
    }

    vec4 albedo = texture(gtexture, texcoord) * glcolor;
    if (albedo.a < alphaTestRef) discard;

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(N), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_BLOCK),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
