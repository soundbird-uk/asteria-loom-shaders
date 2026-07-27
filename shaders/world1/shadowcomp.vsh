#version 330 compatibility
#include "/settings.glsl"

/*
 shadowcomp (vertex) — fullscreen pass over the SHADOW buffer.

 shadowcomp programs are the shadow pass's composites: they run immediately
 after `shadow`, at shadowMapResolution, and write shadowcolor targets. Iris
 supplies the fullscreen quad exactly as it does for composite/deferred, so
 ftransform() places it.

 No varying is needed: the fragment stage addresses the voxel atlas from
 gl_FragCoord (an exact integer texel index), never from a uv — the atlas is a
 packed address space and interpolated coordinates have no meaning in it.
*/

void main() {
    gl_Position = ftransform();
}
