#version 330 compatibility
#include "/settings.glsl"
#include "/lib/color.glsl"

/*
 gbuffers_skytextured (fragment) — the vanilla sun/moon (and custom sky)
 textures, blended over the atmosphere sky in colortex0.

 Phase 3: the vanilla SUN texture is DISCARDED — the procedural HDR sun disc in
 gbuffers_skybasic replaces it (matched to the atmosphere/lighting colour). The
 MOON texture is KEPT, with the HDR boost (SUNMOON_BRIGHTNESS) so it reads
 through the tonemap. SUNMOON_BRIGHTNESS is therefore effectively MOON-ONLY now
 (the sun disc has its own SUN_DISC_BRIGHTNESS); any other custom sky textures a
 resource pack draws through this stage keep the boost too.

 Sampler count: 1 (gtexture)
*/

uniform sampler2D gtexture;
uniform int renderStage;

in vec2 texcoord;
in vec4 glcolor;

/* RENDERTARGETS: 0 */
layout(location = 0) out vec4 outColor;

void main() {
    // The procedural disc owns the sun — drop the vanilla sun texture.
    if (renderStage == MC_RENDER_STAGE_SUN) {
        discard;
    }

    vec4 c = texture(gtexture, texcoord) * glcolor;
    c.rgb = alSrgbToLinear(c.rgb) * SUNMOON_BRIGHTNESS;
    outColor = c;   // alpha preserved; Iris blends this over the sky
}
