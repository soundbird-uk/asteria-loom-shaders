#version 330 compatibility
#include "/settings.glsl"

/*
 shadowcomp1 (vertex) — fullscreen pass over the SHADOW buffer.
 Identical to shadowcomp.vsh; see that file for why no varying is needed.
*/

void main() {
    gl_Position = ftransform();
}
