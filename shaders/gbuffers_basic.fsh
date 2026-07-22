#version 330 compatibility
#include "/settings.glsl"
#include "/lib/encoding.glsl"

/*
 gbuffers_basic (fragment) — untextured primitives into the G-buffer.
 Albedo is the vertex colour; a fixed up-normal keeps deferred shading sane.
 Sampler count: 0
*/

in vec2 lmcoord;
in vec4 glcolor;

/* RENDERTARGETS: 1,2,3 */
layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outNormalLm;
layout(location = 2) out vec4 outMaterial;

void main() {
    vec4 albedo = glcolor;

    outAlbedo   = vec4(albedo.rgb, 1.0);
    outNormalLm = vec4(alEncodeNormal(vec3(0.0, 1.0, 0.0)), lmcoord);
    outMaterial = vec4(alEncodeMatID(AL_MATID_BASIC),
                       alEncodeFlags(AL_FLAG_NONE), 0.0, 0.0);
}
