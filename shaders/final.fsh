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
 Iris scans shaders for these `const` declarations; per the Phase-1 contract
 they live HERE and NOWHERE ELSE. Keep this the single source of truth.

   colortex0  RGBA16F  HDR scene colour (sky + lit scene + translucents)
   colortex1  RGBA8    albedo.rgb, a = vanilla AO / spare
   colortex2  RGBA16   octahedral normal .rg, lightmap (block,sky) .ba
   colortex3  RGBA8    matID/255 .r, flags/255 .g, ba spare
 ==========================================================================
*/
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA8;
const int colortex2Format = RGBA16;
const int colortex3Format = RGBA8;

// Shadow map sizing, driven by the settings defines (see lib/shadow.glsl).
const int   shadowMapResolution = SHADOW_RESOLUTION;
const float shadowDistance       = float(SHADOW_DISTANCE);
// Declared for Phase 2 (coloured/translucent shadows). Phase 1's shadow pass
// is depth-only and writes NO colour, so no shadowcolor buffer is allocated
// yet; this reserves the format so the Phase-2 seam is a one-line change.
const int   shadowcolor0Format = RGBA8;

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
