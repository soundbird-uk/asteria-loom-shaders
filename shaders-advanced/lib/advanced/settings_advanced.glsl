#ifndef AL_LIB_ADVANCED_SETTINGS
#define AL_LIB_ADVANCED_SETTINGS

/*
 lib/advanced/settings_advanced.glsl — tunables for ADVANCED-TIER features only.

 WHY THIS FILE EXISTS AND NOT settings.glsl: everything in shaders/settings.glsl
 is compiled into the macOS build too, and every GUI option there is bound by a
 three-way contract (settings.glsl <-> a screen in shaders.properties <-> a
 lang entry) that tools/validate.py enforces. Constants that only a compute
 program can ever read have no business in that file: they would be dead weight
 in the Mac zip and an invitation to expose a GUI option the Mac build cannot
 honour. They live here, under lib/advanced/, which nothing in shaders/ is
 allowed to include (the isolation lint in tools/validate.py enforces that).

 Everything here is an internal `AL_`-prefixed define: file-tweakable, hot-
 reloadable, deliberately NOT a GUI option. Auto-exposure is a calibration, not
 a taste knob — the user-facing knob is EXPOSURE in settings.glsl, which trims
 the result in final.

 The metering RANGE knobs (KEY / MIN / MAX / STRENGTH / TAU) are NOT duplicated
 here. They stay in shaders/settings.glsl and the compute pass reads them from
 there, because the compute pass replaces only the METERING; the adaptation
 contract (asymmetric clamp + exponential integrator) is shared with the Mac
 path and must never fork.
*/

// --- Dispatch shape --------------------------------------------------------
// ONE workgroup, 16x16 = 256 invocations. Single-workgroup is a deliberate
// choice, not a limitation: a histogram needs a reduction over the WHOLE frame,
// and inside one workgroup that reduction is just shared memory + barrier(),
// with no SSBO, no second dispatch, and no cross-workgroup synchronisation
// (which GLSL does not offer within a dispatch anyway). The cost is one
// occupied SM for ~16k texel fetches — well under 0.1 ms — versus the several
// passes and a persistent buffer a tiled histogram would need. If this ever
// becomes a bottleneck the right answer is a tile pass + reduce pass, not a
// bigger single group.
#define AL_EXPO_GROUP_X 16
#define AL_EXPO_GROUP_Y 16

// Per-invocation sample tile: each invocation takes TILE_X x TILE_Y samples,
// so the group covers a (GROUP_X*TILE_X) x (GROUP_Y*TILE_Y) = 128x128 grid of
// strata over the frame — 16384 samples, exactly one per cell, coverage uniform
// by construction rather than statistically hoped for. At 1080p that is ~0.8%
// of pixels, far more than a histogram needs: the metering only has to resolve
// the percentile boundaries to a fraction of a stop, and the exponential
// integrator averages the remaining sampling noise over ~TAU seconds anyway.
// The strata are handed out INTERLEAVED (an invocation takes cells i, i+16,
// i+32, ...), not as a contiguous screen tile — see the sample loop for why.
#define AL_EXPO_TILE_X 8
#define AL_EXPO_TILE_Y 8

// --- Histogram shape -------------------------------------------------------
// Bin count. Must be <= the invocation count (AL_EXPO_GROUP_X * _Y) so the
// shared histogram can be cleared in one parallel step, and it is walked
// serially once by a single invocation, so keep it modest.
#define AL_EXPO_BINS 128

// The log2-luminance window the bins cover. Anything outside is clamped into
// the end bins (and therefore trimmed away by the percentile cuts below, which
// is exactly what we want for the sun disc and for pure black).
//   2^-12 = 0.00024  — well below a moonless night's scene luminance
//   2^+6  = 64       — well above a torch core; the sun/emissive tail lands in
//                      the top bin and is discarded rather than averaged in.
// 18 stops over 128 bins = ~0.14 stops per bin, finer than the ~0.02 exposure
// resolution the asymmetric clamp permits, so binning is never the limiting
// quantisation.
#define AL_EXPO_LOG_MIN (-12.0)
#define AL_EXPO_LOG_MAX (6.0)

// --- Robust target selection ----------------------------------------------
// Fraction of the sample population discarded from each tail before averaging.
// This is the entire reason the compute path exists: a mip average is the mean
// of the frame, so ONE bright sky, ONE torch in a black cave, or the sun disc
// drags the metering by a stop or more and the whole image breathes with it.
// Trimming both tails and averaging the middle band gives a robust central
// tendency instead — a trimmed mean in log space, i.e. a weighted median-ish
// estimator that only moves when a real majority of the frame moves.
//
// Asymmetric on purpose: the dark tail is cut harder (0.30) than the bright one
// (0.15). Minecraft frames are full of genuinely black texels — cave ceilings,
// unlit block faces, the void below the horizon — and those are not "the scene
// the player is looking at". The bright cut is gentler so a legitimately bright
// snowy noon still reads as bright rather than being trimmed down to its
// shadows. Their sum must stay well below 1.0 (the middle band would vanish;
// the code falls back to the neutral key if it ever does).
#define AL_EXPO_TRIM_DARK 0.30
#define AL_EXPO_TRIM_BRIGHT 0.15

// --- Persistent state layout ----------------------------------------------
// colortex5.a texel (0,0) is the CONTRACT slot: written by the Mac path's
// composite14 and read by final. The compute integrator does not use it as its
// own state (see final.csh) — it keeps last frame's adapted exposure in
// the texel below and only MIRRORS the result into (0,0). Both texels' rgb (AO
// history) are preserved byte-exact.
#define AL_EXPO_SLOT_OUT ivec2(0, 0)
#define AL_EXPO_SLOT_STATE ivec2(1, 0)

#endif // AL_LIB_ADVANCED_SETTINGS
