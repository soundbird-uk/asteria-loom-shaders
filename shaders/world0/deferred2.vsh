#version 330 compatibility
#include "/settings.glsl"

/*
 deferred2 (vertex) — fullscreen pass. Iris supplies the fullscreen quad;
 ftransform() places it and gl_MultiTexCoord0 carries 0..1 screen uv.

 NOTE: this pass renders into HALF-RESOLUTION targets (size.buffer.colortex13 /
 colortex14 in shaders.properties), but that only changes the VIEWPORT — the
 fullscreen quad and its 0..1 uv are unchanged, so nothing here needs to know.
*/

out vec2 texcoord;

void main() {
    gl_Position = ftransform();
    texcoord = gl_MultiTexCoord0.xy;
}
