#version 330 compatibility
#include "/settings.glsl"

/*
 gbuffers_particles (vertex) — smoke, flames, redstone dust, crit sparks,
 block-break, walk/sprint dust, etc.

 Particles render in the POST-deferred phase (we pin them there with
 `particles.ordering = after` in shaders.properties), so the G-buffer is
 already dead. This program is FORWARD-LIT and writes colortex0 directly.

 Particles are NON-DIRECTIONALLY lit (see the .fsh header for the field-bug
 rationale): they shade purely from their lightmap, so we forward NO world
 normal and NO player-space position — a camera-facing billboard's normal is
 unreliable and there is no shadow-map sampling to feed. Just UVs, lightmap and
 vertex colour.
*/

out vec2 texcoord;
out vec2 lmcoord;
out vec4 glcolor;

void main() {
    gl_Position = ftransform();

    texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
    lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    glcolor  = gl_Color;
}
