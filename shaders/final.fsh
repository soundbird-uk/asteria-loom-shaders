#version 330 compatibility
#include "/settings.glsl"
#include "/lib/common.glsl"
#include "/lib/color.glsl"
#include "/lib/encoding.glsl"

/*
 final (fragment) — output to the screen.

 Pipeline: exposure -> placeholder filmic tonemap -> linear->sRGB, with an
 optional DEBUG_VIEW that bypasses grading to inspect raw G-buffer channels.
 final writes to the default framebuffer, so it carries NO RENDERTARGETS
 directive (it is the documented exception, alongside the shadow pass).

 Sampler count: 5 (colortex0, colortex1, colortex2, colortex3, depthtex0)

 ==========================================================================
 CANONICAL BUFFER-FORMAT DECLARATIONS
 --------------------------------------------------------------------------
 Iris reads the colortexNFormat / shadowcolorNFormat declarations as TEXT,
 and they MUST stay inside a comment: the format tokens (RGBA16F, RGBA8,
 RGBA16, ...) are NOT valid GLSL identifiers, so a real driver (confirmed on
 macOS GL 4.1) rejects them as "undeclared identifier" if they appear as live
 code. Commenting them is the documented Iris idiom — the loader still parses
 them, the GLSL compiler never sees them. Per the Phase-1 contract these live
 HERE and nowhere else; this comment block is the single source of truth.

   colortex0    RGBA16F  HDR scene colour (sky + lit scene + translucents)
   colortex1    RGBA8    albedo.rgb, a = vanilla AO / spare
   colortex2    RGBA16   octahedral normal .rg, lightmap (block,sky) .ba
   colortex3    RGBA8    matID/255 .r, flags/255 .g, ba spare
   shadowcolor0 RGBA8    reserved for Phase 2 (coloured/translucent shadows);
                         Phase 1's shadow pass is depth-only, so nothing is
                         allocated yet — this only reserves the format.
 ==========================================================================
*/

/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA8;
const int colortex2Format = RGBA16;
const int colortex3Format = RGBA8;
const int shadowcolor0Format = RGBA8;
*/

// Shadow-map sizing (shadowMapResolution / shadowDistance) is declared in
// settings.glsl as literal-valued const GUI options — Iris' ConstDirectiveParser
// reads their literal text with no macro expansion, so the option must BE the
// constant. They are NOT redeclared here (settings.glsl is already included
// above) to avoid a duplicate directive.

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D depthtex0;

uniform float near;
uniform float far;

in vec2 texcoord;

layout(location = 0) out vec4 fragColor;

// Linearise hardware depth to [0,1] over the view frustum (debug view 4).
float alLinearizeDepth(float d) {
    float z = d * 2.0 - 1.0;
    float lin = (2.0 * near * far) / (far + near - z * (far - near));
    return alSaturate(lin / far);
}

void main() {
    // ---- Debug views (bypass grading) -----------------------------------
#if DEBUG_VIEW == 1
    // Albedo (as stored, sRGB).
    fragColor = vec4(texture(colortex1, texcoord).rgb, 1.0);
    return;
#elif DEBUG_VIEW == 2
    // World normal, remapped to [0,1] for display.
    vec3 n = alDecodeNormal(texture(colortex2, texcoord).rg);
    fragColor = vec4(n * 0.5 + 0.5, 1.0);
    return;
#elif DEBUG_VIEW == 3
    // Lightmap: block in red, sky in green.
    vec2 lm = texture(colortex2, texcoord).ba;
    fragColor = vec4(lm.x, lm.y, 0.0, 1.0);
    return;
#elif DEBUG_VIEW == 4
    // Linear depth as greyscale.
    float ld = alLinearizeDepth(texture(depthtex0, texcoord).r);
    fragColor = vec4(vec3(ld), 1.0);
    return;
#elif DEBUG_VIEW == 5
    // Material ID scaled into a visible grey ramp.
    int id = alDecodeMatID(texture(colortex3, texcoord).r);
    fragColor = vec4(vec3(float(id) / 8.0), 1.0);
    return;
#else
    // ---- Normal path: exposure -> tonemap -> sRGB -----------------------
    vec3 hdr = texture(colortex0, texcoord).rgb;
    hdr *= EXPOSURE;

    vec3 mapped = alTonemapPlaceholder(hdr);   // PHASE 4: replace with AgX
    vec3 srgb   = alLinearToSrgb(mapped);

    fragColor = vec4(srgb, 1.0);
    return;
#endif
}
