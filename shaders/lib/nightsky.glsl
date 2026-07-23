#ifndef AL_LIB_NIGHTSKY
#define AL_LIB_NIGHTSKY

/*
============================================================================
 lib/nightsky.glsl — procedural night sky (Phase 3, NIGHT SKY agent)
----------------------------------------------------------------------------
 Self-contained, sampler-free, pure procedural (hash + value-noise) night
 sky rendered additively over the atmosphere. LOCKED public interface:

     vec3 alNightSky(vec3 worldDir, float nightFactor)

 - worldDir   : normalized world-space view direction (caller normalizes;
                we re-guard anyway for NaN safety).
 - nightFactor: 0 at day, 1 at deep night. EVERYTHING scales with it so the
                sky fades in through dusk and vanishes by day.
 - returns    : ADDITIVE linear HDR radiance. Total energy is deliberately
                kept well BELOW the moon disc — dreamy/painterly, not a
                planetarium poster (brief §3 "soft filmic / dreamy").

 Three layers, all behind `#ifdef NIGHT_SKY` with a hard `vec3(0.0)` fallback:
   1. Starfield  — octahedral hash-cell stars, magnitude distribution,
                   colour-temperature variation, gentle slow twinkle,
                   resolution-independent anti-aliased points.
   2. Galaxy band— value-noise FBM density along a fixed tilted great circle,
                   bright core + wispy edges, warm/cool dust hue drift.
   3. Shooting stars — deterministic time-hashed great-circle streaks,
                   ~one every 20-40 s, ~0.7 s life, thin fading tail. Stateless.

 GLSL 330 only. No compute/SSBO/images. Zero samplers, zero textures. NaN-safe
 (all normalize / acos / asin / divisions guarded or clamped). Cost per sky
 pixel: one hash + one octahedral decode for the star cell, ~2-3 value-noise
 octaves for the galaxy, a small handful of ops for the streak.

 CELL MAPPING CHOICE — OCTAHEDRAL.
   The direction sphere is mapped to the unit square [0,1]^2 via the standard
   octahedral projection. Chosen over lat-long precisely to AVOID POLE PINCHING:
   a lat-long grid crowds cells into vanishing slivers at the zenith/nadir,
   which makes stars clump and shimmer overhead. The octahedral map keeps cell
   solid-angles within a small (~2x) bound everywhere with no singular point,
   so star density stays even across the whole sphere including straight up.
   The only distortion is a mild stretch along the octahedron's diagonal edges,
   which is harmless for sub-pixel points. Sub-cell jitter is bounded to the
   cell interior (see AL_STAR_JITTER) so a star's disc never crosses a cell
   edge — that lets us test ONLY the pixel's own cell (1 hash) instead of a
   3x3 neighbourhood, at the cost of a barely-perceptible position regularity
   that is invisible at 70+ cells across.
============================================================================
*/

#include "/lib/common.glsl"

// frameTimeCounter drives twinkle + shooting-star timing. Guarded by a SHARED
// macro (not just this lib's include guard) so a program that ALSO declares
// frameTimeCounter itself — e.g. composite2 pulling in lib/blackhole.glsl, which
// pulls in this file — does not double-declare it. Whoever declares first wins;
// the other side sees AL_UNIFORM_FRAMETIME already set and skips.
#ifndef AL_UNIFORM_FRAMETIME
#define AL_UNIFORM_FRAMETIME
uniform float frameTimeCounter;
#endif

/* ------------------------------------------------------------------------
   TUNABLES (internal, not GUI — edit + hot-reload). The only GUI options are
   NIGHT_SKY (toggle) and STARS_DENSITY (slider), both in settings.glsl.
   ------------------------------------------------------------------------ */

// -- Starfield --
#define AL_STAR_CELLS       72.0    // octahedral cells per axis (density grid)
#define AL_STAR_THRESHOLD   0.34    // base P(star exists) per cell (x STARS_DENSITY)
#define AL_STAR_JITTER      0.55    // sub-cell jitter span (kept < 1 so the star
                                    // stays clear of the cell edge -> single-cell test)
#define AL_STAR_RADIUS      0.0016  // angular core radius (rad) — ~1.5px@1080p, crisp@4K
#define AL_STAR_HALO        2.0     // halo radius as a multiple of the core (soft glow)
#define AL_STAR_MAG_POWER   6.0     // magnitude curve: higher => more faint, fewer bright
#define AL_STAR_BRIGHT      0.42    // brightest-star linear radiance (stays below moon)
#define AL_STAR_FLOOR       0.05    // faintest visible star's fraction of full brightness
#define AL_TWINKLE_AMP      0.14    // twinkle amplitude (small — dreamy, not disco)
#define AL_TWINKLE_SPEED    0.9     // twinkle base angular speed (rad/s — slow)

// -- Galaxy band --
// Galactic pole = normal of the band's great circle. A y-component of ~0.5
// tilts the band roughly 60 deg from the horizon (pole ~30 deg above horizon),
// so the Milky Way arcs diagonally across the sky with visible structure.
#define AL_GALAXY_POLE      vec3(0.36, 0.50, 0.79)
#define AL_GALAXY_WIDTH     0.32    // half-width (in |dot(dir,pole)|) of the diffuse band
#define AL_GALAXY_CORE_W    0.12    // half-width of the bright dense core lane
#define AL_GALAXY_BRIGHT    0.030   // peak galaxy linear radiance (well below moon & stars)
#define AL_GALAXY_FREQ      2.6     // value-noise frequency along the band
#define AL_GALAXY_CONTRAST  1.7     // FBM contrast (wisps vs. voids)

// -- Shooting stars --
#define AL_SHOOT_PERIOD     6.0     // seconds per candidate slot
#define AL_SHOOT_CHANCE     0.22    // P(slot fires) => avg interval ~PERIOD/CHANCE (~27 s)
#define AL_SHOOT_LIFETIME   0.7     // visible life (s)
#define AL_SHOOT_ARC        0.55    // total arc travelled over the life (rad)
#define AL_SHOOT_TAIL       0.16    // tail length behind the head (rad)
#define AL_SHOOT_THICK      0.0040  // streak half-thickness (rad) — thin
#define AL_SHOOT_BRIGHT     0.85    // head linear radiance (bright but tiny area)

/* ------------------------------------------------------------------------
   Hashes (Dave-Hoskins style: fract-mul-permute, high quality, no textures).
   ------------------------------------------------------------------------ */

vec4 alHash42(vec2 p) {
    vec4 p4 = fract(vec4(p.xyxy) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

vec4 alHash41(float p) {
    vec4 p4 = fract(vec4(p) * vec4(0.1031, 0.1030, 0.0973, 0.1099));
    p4 += dot(p4, p4.wzxy + 33.33);
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

/* ------------------------------------------------------------------------
   Octahedral sphere<->square mapping (no poles, ~even solid angle).
   ------------------------------------------------------------------------ */

vec2 alOctSign(vec2 v) {
    return vec2(v.x >= 0.0 ? 1.0 : -1.0, v.y >= 0.0 ? 1.0 : -1.0);
}

// dir (unit) -> uv in [0,1]^2
vec2 alOctEncode(vec3 n) {
    float d = abs(n.x) + abs(n.y) + abs(n.z);
    n /= max(d, 1e-8);
    vec2 p = n.xy;
    if (n.z < 0.0) p = (1.0 - abs(p.yx)) * alOctSign(p);
    return p * 0.5 + 0.5;
}

// uv in [0,1]^2 -> unit dir (NaN-safe normalize)
vec3 alOctDecode(vec2 f) {
    f = f * 2.0 - 1.0;
    vec3 n = vec3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
    float t = max(-n.z, 0.0);
    n.x += n.x >= 0.0 ? -t : t;
    n.y += n.y >= 0.0 ? -t : t;
    float len = length(n);
    return len > 1e-8 ? n / len : vec3(0.0, 1.0, 0.0);
}

/* ------------------------------------------------------------------------
   3D value noise + small FBM for the galaxy (seamless on the sphere: sampled
   directly on the direction vector, so no atan/seam artefacts).
   ------------------------------------------------------------------------ */

float alValHash(vec3 p) {
    p = fract(p * 0.3183099 + 0.1);
    p *= 17.0;
    return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float alNoise3(vec3 x) {
    vec3 i = floor(x);
    vec3 f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = alValHash(i + vec3(0.0, 0.0, 0.0));
    float n100 = alValHash(i + vec3(1.0, 0.0, 0.0));
    float n010 = alValHash(i + vec3(0.0, 1.0, 0.0));
    float n110 = alValHash(i + vec3(1.0, 1.0, 0.0));
    float n001 = alValHash(i + vec3(0.0, 0.0, 1.0));
    float n101 = alValHash(i + vec3(1.0, 0.0, 1.0));
    float n011 = alValHash(i + vec3(0.0, 1.0, 1.0));
    float n111 = alValHash(i + vec3(1.0, 1.0, 1.0));
    return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
               mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}

// 3 octaves — the whole galaxy cost. Returns ~[0,1].
float alFbm3(vec3 x) {
    float s = 0.0;
    float a = 0.5;
    float norm = 0.0;
    for (int o = 0; o < 3; o++) {
        s += a * alNoise3(x);
        norm += a;
        x *= 2.03;
        a *= 0.5;
    }
    return s / max(norm, 1e-5);
}

/* ------------------------------------------------------------------------
   Layer 1 — starfield.
   ------------------------------------------------------------------------ */

vec3 alStarfield(vec3 dir) {
    vec2 uv = alOctEncode(dir);
    vec2 cell = floor(uv * AL_STAR_CELLS);

    vec4 h = alHash42(cell + 3.17);

    // Existence: threshold scaled by the user density slider (capped so 2.0
    // can't push every cell into a star).
    float thresh = min(AL_STAR_THRESHOLD * STARS_DENSITY, 0.92);
    if (h.x > thresh) return vec3(0.0);

    // Sub-cell position, jitter bounded to the interior so the disc never
    // crosses the cell edge (single-cell test stays correct).
    vec2 jitter = 0.5 + (h.yz - 0.5) * AL_STAR_JITTER;
    vec2 starUV = (cell + jitter) / AL_STAR_CELLS;
    vec3 starDir = alOctDecode(starUV);

    // Angular separation (NaN-safe).
    float cd = clamp(dot(dir, starDir), -1.0, 1.0);
    float ang = acos(cd);

    // Anti-aliased point: crisp core + faint soft halo. Resolution-independent
    // (angular radius), so it stays a clean point from 1080p to 4K.
    float core = 1.0 - smoothstep(0.0, AL_STAR_RADIUS, ang);
    float halo = 1.0 - smoothstep(0.0, AL_STAR_RADIUS * AL_STAR_HALO, ang);
    float shape = core + 0.18 * halo * halo;
    if (shape <= 0.0) return vec3(0.0);

    // Magnitude distribution: many faint, few bright.
    float mag = mix(AL_STAR_FLOOR, 1.0, pow(h.w, AL_STAR_MAG_POWER));

    // Colour temperature: subtle blue-white <-> warm orange. Reuse hash bits
    // (no extra hash). Kept gentle so the field reads mostly silver-white.
    float temp = fract(h.x * 13.0 + h.w * 7.0);
    vec3 warm = vec3(1.00, 0.82, 0.62);
    vec3 cool = vec3(0.78, 0.85, 1.00);
    vec3 col = mix(warm, cool, temp);

    // Gentle slow twinkle: small amplitude, per-star phase + rate.
    float twPhase = h.x * AL_TAU;
    float twRate = AL_TWINKLE_SPEED * (0.6 + h.w);
    float tw = 1.0 + AL_TWINKLE_AMP * sin(frameTimeCounter * twRate + twPhase);

    return col * (shape * mag * AL_STAR_BRIGHT * tw);
}

/* ------------------------------------------------------------------------
   Layer 2 — galaxy band.
   ------------------------------------------------------------------------ */

vec3 alGalaxy(vec3 dir) {
    vec3 pole = normalize(AL_GALAXY_POLE);
    float s = dot(dir, pole);                 // signed distance from band plane

    // Diffuse band envelope + brighter narrow core lane.
    float band = exp(-(s * s) / (2.0 * AL_GALAXY_WIDTH * AL_GALAXY_WIDTH));
    float core = exp(-(s * s) / (2.0 * AL_GALAXY_CORE_W * AL_GALAXY_CORE_W));
    float envelope = band * 0.7 + core * 0.6;
    if (envelope <= 0.001) return vec3(0.0);

    // Value-noise structure: wisps and dark rifts. FBM sampled on the sphere.
    float n = alFbm3(dir * AL_GALAXY_FREQ + 11.0);
    float density = pow(clamp(n, 0.0, 1.0), AL_GALAXY_CONTRAST);
    // A second, lower-frequency band gives a dark central dust lane along core.
    float rift = alFbm3(dir * (AL_GALAXY_FREQ * 0.5) + 47.0);
    density *= mix(1.0, 0.45, core * smoothstep(0.35, 0.65, rift));

    // Warm/cool dust hue drift from a slow noise field. Kept faint.
    float hue = alFbm3(dir * 1.3 + 5.0);
    vec3 warmDust = vec3(0.95, 0.80, 0.66);
    vec3 coolDust = vec3(0.62, 0.72, 0.98);
    vec3 col = mix(coolDust, warmDust, smoothstep(0.35, 0.65, hue));

    return col * (envelope * density * AL_GALAXY_BRIGHT);
}

/* ------------------------------------------------------------------------
   Layer 3 — shooting stars (stateless, deterministic from time hashes).
   ------------------------------------------------------------------------ */

vec3 alRandDir(vec2 seed) {
    // Uniform-ish direction, biased to the upper hemisphere (streaks above the
    // horizon). z (up) in [0.15, 1.0].
    vec4 r = alHash42(seed);
    float z = mix(0.15, 1.0, r.x);
    float a = r.y * AL_TAU;
    float rad = sqrt(max(1.0 - z * z, 0.0));
    return vec3(rad * cos(a), z, rad * sin(a));
}

vec3 alShootingStar(vec3 dir) {
    float t = frameTimeCounter;
    float idx = floor(t / AL_SHOOT_PERIOD);
    float local = t - idx * AL_SHOOT_PERIOD;      // 0 .. PERIOD

    vec4 h = alHash41(idx + 0.5);
    if (h.x > AL_SHOOT_CHANCE) return vec3(0.0);  // slot did not fire
    if (local > AL_SHOOT_LIFETIME) return vec3(0.0);

    float u = local / AL_SHOOT_LIFETIME;          // 0 .. 1 progress

    // Great-circle path: a start direction and a distinct second point define
    // the rotation axis (plane normal). Guard degeneracy.
    vec3 start = alRandDir(vec2(idx * 1.7, 4.2));
    vec3 other = alRandDir(vec2(idx * 2.3, 9.1));
    vec3 axis = cross(start, other);
    float al = length(axis);
    if (al < 1e-3) return vec3(0.0);
    axis /= al;

    // In-plane basis: e1 = start (arc angle 0), e2 = axis x e1.
    vec3 e1 = start;
    vec3 e2 = normalize(cross(axis, e1));

    float headAngle = u * AL_SHOOT_ARC;

    // Pixel position relative to the great circle.
    float sp = clamp(dot(dir, axis), -1.0, 1.0);
    float perpAng = abs(asin(sp));                // angular dist from plane
    vec3 proj = dir - axis * dot(dir, axis);
    float pl = length(proj);
    if (pl < 1e-4) return vec3(0.0);
    proj /= pl;
    float pixAngle = atan(dot(proj, e2), dot(proj, e1));

    // Distance BEHIND the head, wrapped into (-pi, pi].
    float rel = headAngle - pixAngle;
    rel = mod(rel + AL_PI, AL_TAU) - AL_PI;
    if (rel < 0.0 || rel > AL_SHOOT_TAIL) return vec3(0.0);  // ahead / past tail

    float along = 1.0 - rel / AL_SHOOT_TAIL;      // 1 at head -> 0 at tail end
    float thick = 1.0 - smoothstep(0.0, AL_SHOOT_THICK, perpAng);
    float tail = along * along;                    // brighter near the head
    float lifeFade = sin(clamp(u, 0.0, 1.0) * AL_PI);  // ease in/out over life

    float I = thick * tail * lifeFade;
    vec3 col = vec3(0.92, 0.96, 1.00);
    return col * (I * AL_SHOOT_BRIGHT);
}

/* ------------------------------------------------------------------------
   Public entry.
   ------------------------------------------------------------------------ */

vec3 alNightSky(vec3 worldDir, float nightFactor) {
#ifdef NIGHT_SKY
    float nf = clamp(nightFactor, 0.0, 1.0);
    if (nf <= 0.0) return vec3(0.0);

    float len = length(worldDir);
    if (len < 1e-6) return vec3(0.0);
    vec3 dir = worldDir / len;

    // Fade the whole sky out below the horizon (the void plane is drawn there).
    float horizon = smoothstep(-0.06, 0.10, dir.y);
    if (horizon <= 0.0) return vec3(0.0);

    vec3 col = vec3(0.0);
    col += alStarfield(dir);
    col += alGalaxy(dir);
    col += alShootingStar(dir);

    col *= horizon * nf;

    // Final NaN/negative guard (comparisons, not isnan — Apple-GL friendly).
    col = max(col, vec3(0.0));
    if (!(col.r <= 1e9) || !(col.g <= 1e9) || !(col.b <= 1e9)) return vec3(0.0);
    return col;
#else
    return vec3(0.0);
#endif
}

#endif // AL_LIB_NIGHTSKY
