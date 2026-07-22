#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Asteria Loom — shader validation / compile gate.

This is the project's *compile gate*. Its entire reason to exist is to catch,
on Linux CI, the GLSL that would fail to compile on the user's M4 Mac (OpenGL
4.1 core, `#version 330 compatibility`). The CI machine cannot emulate the Mac
GL driver, so the worst possible outcome is a FALSE PASS — a program that this
script reports OK but that will not compile on the Mac. Everything here is
therefore biased toward strictness.

What it does, for every (profile x program-stage) combination:
  1. Parses shaders/shaders.properties to learn each profile's option state
     (built on top of the settings.glsl defaults, with profile chaining and
     DEFINE / !DEFINE / DEFINE=VALUE semantics).
  2. Parses shaders/settings.glsl for the default option state.
  3. Resolves #include directives with Iris semantics (leading '/' => relative
     to shaders/ root; otherwise relative to the including file; recursive and
     cycle-safe).
  4. Applies the profile's option state by stripping the settings.glsl option
     #defines from the assembled source and re-injecting the resolved state
     immediately after the #version line, alongside the small set of macros /
     uniforms that Iris injects at runtime (see IRIS_MACRO_STUBS /
     IRIS_SYMBOL_STUBS below).
  5. Runs glslangValidator on the patched source (-S vert / -S frag), once per
     compile *target* (see below).
  6. Runs a set of static lint checks (unresolved includes, RENDERTARGETS
     count/index integrity, sampler budget, unknown render-stage macros,
     live-vs-commented buffer-format declarations + single-source-of-truth,
     option/screen/lang consistency).

IMPORTANT — buffer formats: Iris reads colortexNFormat/shadowcolorNFormat only
from COMMENTS. A live `const int colortexNFormat = RGBA16F;` leaves a non-GLSL
identifier that real drivers reject. This validator therefore (a) injects NO
format-identifier stubs — a live one is meant to fail glslang — and (b) hard-
fails lint_format_live on any uncommented format const with an identifier
initializer. (A stub table here once masked exactly this into a false PASS that
shipped to the user's Mac.)

Compile targets (`--target`): the same source is compiled under different
Iris-macro environments so both platform code paths get syntax coverage.
  * `mac`      — MC_OS_MAC, GL/GLSL 410, IRIS_FEATURE_* undefined => every
                 AL_ADVANCED_TIER gate compiles OUT (the M4 path; the one that
                 must never false-PASS).
  * `advanced` — MC_OS_WINDOWS, GL/GLSL 460, all four IRIS_FEATURE_* defined =>
                 AL_ADVANCED_TIER branches compile IN (Windows path; gives the
                 advanced tier syntax coverage from Phase 6 on).
Default is `mac`; CI runs `both`.

It collects *all* failures before exiting non-zero and prints a compact
target/profile x program result table plus full glslang output for every failure.

stdlib only. Python 3.8+.
"""

import argparse
import fnmatch
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

# ---------------------------------------------------------------------------
# Iris-injected stubs.
#
# Iris injects a number of macros and uniforms into every program at runtime
# that are not visible to a plain glslang invocation. We reproduce them here.
# These tables are intentionally at the top of the file and easy to extend as
# later phases use more Iris features.
#
# There are three macro environments (compile "targets"). All are guarded with
# #ifndef so a real definition in the shader always wins.
#   * mac      — the plain M4 path: MC_OS_MAC, GL/GLSL 410, and NO IRIS_FEATURE_*
#                flags, so every AL_ADVANCED_TIER gate compiles out as on macOS.
#   * mac-hw   — the M4 path WITH hardware shadow sampling. macOS caps at GL 4.1,
#                but SEPARATE_HARDWARE_SAMPLERS is NOT a GL 4.2+ feature, so Iris
#                reports it on Apple Silicon and the M4 takes the
#                `#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS` PCSS branch
#                UNDER MC_OS_MAC — a combination the other two targets never
#                compile. So: MC_OS_MAC + GL/GLSL 410 + ONLY that one flag (no
#                compute/SSBO/images — those genuinely cannot exist on Mac).
#   * advanced — the Windows path: MC_OS_WINDOWS, GL/GLSL 460, and all four
#                IRIS_FEATURE_* flags defined, so AL_ADVANCED_TIER branches get
#                syntax coverage.
# The mac & mac-hw targets are the ones that must never false-PASS.
# ---------------------------------------------------------------------------

# name -> value string ('' => object-like define with no value).
IRIS_MACRO_STUBS_MAC = {
    "MC_VERSION": "12100",       # a recent MC release, format YYVVV-ish
    "MC_GL_VERSION": "410",      # macOS caps at GL 4.1
    "MC_GLSL_VERSION": "410",
    "MC_OS_MAC": "1",            # the Mac path
    "IS_IRIS": "1",
}

# The M4 path with hardware shadow filtering. Same as mac, plus the ONE optional
# feature Apple Silicon actually reports.
IRIS_MACRO_STUBS_MAC_HW = {
    "MC_VERSION": "12100",
    "MC_GL_VERSION": "410",
    "MC_GLSL_VERSION": "410",
    "MC_OS_MAC": "1",
    "IS_IRIS": "1",
    "IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS": "1",
}

IRIS_MACRO_STUBS_ADVANCED = {
    "MC_VERSION": "12100",
    "MC_GL_VERSION": "460",
    "MC_GLSL_VERSION": "460",
    "MC_OS_WINDOWS": "1",        # the Windows/advanced path
    "IS_IRIS": "1",
    # The four optional feature flags Iris emits when the machine supports them
    # (see brief §4). Defining all four unlocks AL_ADVANCED_TIER.
    "IRIS_FEATURE_COMPUTE_SHADERS": "1",
    "IRIS_FEATURE_SSBO": "1",
    "IRIS_FEATURE_CUSTOM_IMAGES": "1",
    "IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS": "1",
}

TARGET_MACROS = {
    "mac": IRIS_MACRO_STUBS_MAC,
    "mac-hw": IRIS_MACRO_STUBS_MAC_HW,
    "advanced": IRIS_MACRO_STUBS_ADVANCED,
}

# Uniforms/attributes Iris provides. We only inject the declaration if the
# symbol is *referenced but not declared* in the assembled source (real
# declarations in the shader always win). Extend as needed.
#   name -> declaration line to inject
IRIS_SYMBOL_STUBS = {
    "alphaTestRef": "uniform float alphaTestRef;",
    "renderStage": "uniform int renderStage;",
}

# NOTE: there is deliberately NO buffer-format identifier stub table.
# Buffer-format identifiers (RGBA16F, R11F_G11F_B10F, ...) are NOT GLSL and real
# GL drivers reject them. Iris reads colortexNFormat/shadowcolorNFormat only
# from *comments*, so a live `const int colortexNFormat = RGBA16F;` is a bug
# that must fail on the Mac. A stub table here previously MASKED exactly that
# error into a false PASS that shipped. If a format identifier reaches glslang,
# it SHOULD fail — and lint_format_live() catches it with a clear message.

# Iris render-stage macros (MC_RENDER_STAGE_*). Only names on THIS list get
# stubbed. Any MC_RENDER_STAGE_* token referenced in a program but not on this
# list is treated as a typo and hard-fails the lint (matching real Iris, which
# would error) — we never invent a value for an unknown stage, because that
# would silently mask a misspelling like MC_RENDER_STAGE_VOIDD.
KNOWN_RENDER_STAGES = [
    "MC_RENDER_STAGE_NONE",
    "MC_RENDER_STAGE_SKY",
    "MC_RENDER_STAGE_SUNSET",
    "MC_RENDER_STAGE_CUSTOM_SKY",
    "MC_RENDER_STAGE_SUN",
    "MC_RENDER_STAGE_MOON",
    "MC_RENDER_STAGE_STARS",
    "MC_RENDER_STAGE_VOID",
    "MC_RENDER_STAGE_TERRAIN_SOLID",
    "MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED",
    "MC_RENDER_STAGE_TERRAIN_CUTOUT",
    "MC_RENDER_STAGE_ENTITIES",
    "MC_RENDER_STAGE_BLOCK_ENTITIES",
    "MC_RENDER_STAGE_DESTROY",
    "MC_RENDER_STAGE_OUTLINE",
    "MC_RENDER_STAGE_DEBUG",
    "MC_RENDER_STAGE_HAND_SOLID",
    "MC_RENDER_STAGE_TERRAIN_TRANSLUCENT",
    "MC_RENDER_STAGE_TRIPWIRE",
    "MC_RENDER_STAGE_PARTICLES",
    "MC_RENDER_STAGE_CLOUDS",
    "MC_RENDER_STAGE_RAIN_SNOW",
    "MC_RENDER_STAGE_WORLD_BORDER",
    "MC_RENDER_STAGE_HAND_TRANSLUCENT",
]

MAX_FRAGMENT_SAMPLERS = 16

# Files exempt from the RENDERTARGETS-comment lint (by stem).
RENDERTARGETS_EXEMPT_STEMS = {"shadow", "final"}


# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

def read_text(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_line_comment(s):
    """Return (code, comment) split on the first // outside a block comment.
    Good enough for properties/settings parsing (no strings with // to worry
    about in these files)."""
    idx = s.find("//")
    if idx < 0:
        return s, ""
    return s[:idx], s[idx + 2:]


# An option name as used by the pack GUI: plain UPPER_SNAKE, not an internal
# AL_ macro, not an Iris MC_ macro.
OPTION_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def is_option_name(name):
    if not OPTION_NAME_RE.match(name):
        return False
    if name.startswith("AL_") or name.startswith("MC_") or name.startswith("IRIS_"):
        return False
    return True


# ---------------------------------------------------------------------------
# settings.glsl parsing
# ---------------------------------------------------------------------------

class Option:
    """A user-facing settings.glsl option.

    kind:
      * 'toggle'   — boolean #define toggle (value is None).
      * 'selector' — #define with a value + a // [allowed values] comment.
      * 'const'    — a `const int/float/bool NAME = value; // [..]` declaration.
                     Iris exposes these as GUI options too (e.g.
                     shadowMapResolution). Their names may be camelCase. We
                     never inject a #define for them (that would corrupt the
                     const declaration); we only track them for the cross-checks.
    enabled: default on/off from settings.glsl.
    value: default value string for selectors/consts, else None.
    """
    __slots__ = ("name", "kind", "enabled", "value")

    def __init__(self, name, kind, enabled, value):
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.value = value


# Matches an optionally-commented #define line, capturing the name and the rest.
#   groups: (comment_marker, name, rest)
DEFINE_RE = re.compile(r"^\s*(//)?\s*#define\s+([A-Za-z_][A-Za-z0-9_]*)\b(.*)$")

# Matches an optionally-commented `const <type> NAME = <value>;` declaration.
#   groups: (comment_marker, name, value, trailing)
CONST_OPTION_RE = re.compile(
    r"^\s*(//)?\s*const\s+(?:int|float|bool|uint)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
    r"=\s*([^;]+);(.*)$")


def parse_settings(settings_text):
    """Parse settings.glsl. Returns dict name -> Option for GUI options only.

    Iris exposes an option in three shapes:
      * a #define with a value AND a trailing `// [a b c]` selector comment;
      * a bare boolean #define toggle (`#define NAME` / `//#define NAME`);
      * a `const int/float/bool NAME = value; // [a b c]` declaration
        (the idiom Iris uses for shadowMapResolution and friends).
    A #define or const *with* a value but *without* a bracket comment is an
    ordinary constant, NOT an option; profiles never touch it and it need not
    appear in a screen.
    """
    options = {}
    for raw in settings_text.splitlines():
        m = DEFINE_RE.match(raw)
        if m:
            commented = m.group(1) is not None
            name = m.group(2)
            rest = m.group(3)
            if not is_option_name(name):
                continue
            code, comment = strip_line_comment(rest)
            value = code.strip()
            has_brackets = "[" in comment and "]" in comment
            if value == "":
                options[name] = Option(name, "toggle", not commented, None)
            elif has_brackets:
                options[name] = Option(name, "selector", not commented, value)
            # else: valued #define without a bracket list -> plain constant
            continue

        cm = CONST_OPTION_RE.match(raw)
        if cm:
            commented = cm.group(1) is not None
            name = cm.group(2)
            value = cm.group(3).strip()
            trailing = cm.group(4)
            # const options may be camelCase (shadowMapResolution); accept any
            # non-internal name, but only when a selector list is present.
            if name.startswith("AL_"):
                continue
            _code, comment = strip_line_comment(trailing)
            if "[" in comment and "]" in comment:
                options[name] = Option(name, "const", not commented, value)
    return options


def is_option_ref(name, known_options):
    """True if `name` (a profile/screen token) refers to a pack option.

    A token is an option reference if it is a known option (covers camelCase
    const options like shadowMapResolution) OR it follows the UPPER_SNAKE
    #define-option convention (so typos of non-existent UPPER_SNAKE options are
    still caught by the 'exists' lint). Unknown camelCase tokens (Iris built-in
    directives such as sunPathRotation that are not GUI options) are ignored.
    """
    if name in known_options:
        return True
    return is_option_name(name)


# ---------------------------------------------------------------------------
# shaders.properties parsing
# ---------------------------------------------------------------------------

def load_properties(path):
    """Load a .properties file into a list of (key, value) preserving order.
    Handles backslash line continuations and #/! comment lines."""
    text = read_text(path)
    # Join backslash continuations.
    lines = []
    buf = ""
    for raw in text.splitlines():
        line = raw
        if buf:
            line = buf + "\n" + line
            buf = ""
        # count trailing backslashes to decide continuation
        stripped = line.rstrip()
        if stripped.endswith("\\") and not stripped.endswith("\\\\"):
            buf = stripped[:-1]
            continue
        lines.append(line)
    if buf:
        lines.append(buf)

    entries = []
    for line in lines:
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("!"):
            # NB: '!' at the start of a *line* is a properties comment; the
            # '!DEFINE' disable syntax only appears inside a value, never as the
            # first char of a key line.
            continue
        if "=" not in s:
            continue
        key, val = s.split("=", 1)
        entries.append((key.strip(), val.strip()))
    return entries


def tokenize_profile_value(value):
    """Split a profile/screen value into whitespace tokens, flattening newlines
    introduced by continuation joins."""
    return value.replace("\n", " ").split()


def parse_profiles(entries, options):
    """Resolve every `profile.NAME` entry into a concrete option state.

    Returns (profiles, referenced_options) where:
      profiles: dict NAME -> dict optname -> (enabled: bool, value: str|None)
      referenced_options: set of option names referenced by any profile token
                          (for the "option exists" lint).
    Supports profile chaining (a token `profile.OTHER` merges OTHER's resolved
    state first), DEFINE (enable), !DEFINE (disable), DEFINE=VALUE (set value).
    program.* tokens and other non-option tokens are ignored gracefully.
    """
    raw_profiles = {}
    for key, val in entries:
        if key.startswith("profile."):
            name = key[len("profile."):].strip()
            raw_profiles[name] = tokenize_profile_value(val)

    known = set(options.keys())
    referenced = set()

    def default_state():
        st = {}
        for name, opt in options.items():
            st[name] = (opt.enabled, opt.value)
        return st

    resolved = {}
    resolving = set()  # cycle guard

    def resolve(name):
        if name in resolved:
            return resolved[name]
        if name in resolving:
            # profile cycle; break it (already partially applied elsewhere)
            return default_state()
        resolving.add(name)
        state = default_state()
        for tok in raw_profiles.get(name, []):
            if tok.startswith("profile."):
                other = tok[len("profile."):]
                other_state = resolve(other)
                state.update(other_state)
                continue
            if tok.startswith("program.") or tok.startswith("!program."):
                continue  # pass enable/disable, not an option define
            disable = False
            if tok.startswith("!"):
                disable = True
                tok = tok[1:]
            if "=" in tok:
                opt_name, opt_val = tok.split("=", 1)
                opt_name = opt_name.strip()
                opt_val = opt_val.strip()
                if is_option_ref(opt_name, known):
                    referenced.add(opt_name)
                    state[opt_name] = (not disable, opt_val)
            else:
                opt_name = tok.strip()
                if is_option_ref(opt_name, known):
                    referenced.add(opt_name)
                    if disable:
                        state[opt_name] = (False, _value_of(state, opt_name))
                    else:
                        state[opt_name] = (True, _value_of(state, opt_name))
                # non-option tokens (unknown camelCase Iris directives) ignored
        resolving.discard(name)
        resolved[name] = state
        return state

    def _value_of(state, name):
        cur = state.get(name)
        return cur[1] if cur else None

    for name in raw_profiles:
        resolve(name)

    return resolved, referenced


def parse_screens(entries, options):
    """Return the set of option names referenced across all screen/sliders
    lines (used both for the 'exists' and 'appears in a screen' lints).
    Recognises const-style option names (e.g. shadowMapResolution) via the
    known-options set, not just the UPPER_SNAKE convention."""
    known = set(options.keys())
    refs = set()
    for key, val in entries:
        if key == "screen" or key.startswith("screen.") or key == "sliders" or key.startswith("sliders."):
            for tok in tokenize_profile_value(val):
                if tok.startswith("[") or tok.startswith("<"):
                    continue  # sub-screen ref / placeholder
                if tok.startswith("profile.") or tok.startswith("program."):
                    continue
                if is_option_ref(tok, known):
                    refs.add(tok)
    return refs


# ---------------------------------------------------------------------------
# #include resolution (Iris semantics)
# ---------------------------------------------------------------------------

INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')


def resolve_includes(entry_path, shaders_root, missing=None):
    """Return the fully-inlined source for entry_path.

    Iris rules: an include path starting with '/' is relative to the shaders/
    root; otherwise it is relative to the directory of the including file.
    Recursive. Cycle-safe: a file currently on the include stack is not
    re-entered (a comment marker is emitted instead). Non-cyclic repeat
    includes ARE inlined again — the shader's own #ifndef guards (evaluated by
    glslang) collapse them, exactly as in a real compile.

    If `missing` is a list, every unresolved #include is appended to it as
    (includer_path, line_no, include_string, resolved_target). Iris hard-fails
    the whole pack on a missing include, so callers turn a non-empty `missing`
    into a hard failure (see lint_includes).
    """
    out_lines = []

    def _inline(path, stack):
        real = os.path.realpath(path)
        if real in stack:
            out_lines.append("// [validate.py] include cycle skipped: %s" % path)
            return
        if not os.path.isfile(path):
            out_lines.append('// [validate.py] MISSING FILE: %s' % path)
            return
        stack = stack + [real]
        text = read_text(path)
        for i, line in enumerate(text.splitlines()):
            m = INCLUDE_RE.match(line)
            if not m:
                out_lines.append(line)
                continue
            inc = m.group(1)
            if inc.startswith("/"):
                target = os.path.join(shaders_root, inc.lstrip("/"))
            else:
                target = os.path.join(os.path.dirname(path), inc)
            if not os.path.isfile(target):
                if missing is not None:
                    missing.append((path, i + 1, inc, target))
                out_lines.append('// [validate.py] MISSING INCLUDE "%s" (from %s:%d)'
                                 % (inc, path, i + 1))
                continue
            _inline(target, stack)

    _inline(entry_path, [])
    return "\n".join(out_lines)


# ---------------------------------------------------------------------------
# Patching: strip option defines, inject profile state + Iris stubs
# ---------------------------------------------------------------------------

WORD_RE_CACHE = {}


def references_symbol(text, symbol):
    r = WORD_RE_CACHE.get(symbol)
    if r is None:
        r = re.compile(r"\b" + re.escape(symbol) + r"\b")
        WORD_RE_CACHE[symbol] = r
    return r.search(text) is not None


def declares_uniform(text, symbol):
    return re.search(r"\buniform\b[^;]*\b" + re.escape(symbol) + r"\b", text) is not None


def defines_macro(text, macro):
    return re.search(r"^\s*#define\s+" + re.escape(macro) + r"\b", text, re.M) is not None


def strip_option_defines(source, option_names):
    """Remove settings.glsl #define / //#define lines for the given options so
    the injected profile state is the single source of truth."""
    keep = []
    for line in source.splitlines():
        m = DEFINE_RE.match(line)
        if m and m.group(2) in option_names:
            continue
        keep.append(line)
    return "\n".join(keep)


def build_injection(state, assembled_source, macro_stubs, skip_inject=frozenset()):
    """Build the block injected right after #version.
    state: dict optname -> (enabled, value)
    macro_stubs: the target's Iris macro environment (TARGET_MACROS[target]).
    skip_inject: option names to NOT emit as #defines (const-style options).
    """
    out = []
    out.append("// ==== injected by validate.py ====")

    # Iris macros for this target, guarded so real defs win.
    for name, value in macro_stubs.items():
        out.append("#ifndef %s" % name)
        if value == "":
            out.append("#define %s" % name)
        else:
            out.append("#define %s %s" % (name, value))
        out.append("#endif")

    # NB: no buffer-format identifier stubs — see the note by IRIS_MACRO_STUBS.
    # Format identifiers must never be defined; a live one is meant to fail.

    # Resolved option state. const-style options (skip_inject) are NOT emitted
    # as #defines — that would corrupt their `const NAME = value;` declaration
    # (`const int 1024 = 2048;`). Their default const value compiles fine and
    # the profile value never affects preprocessor branching, so leaving the
    # declaration intact is both safe and correct.
    out.append("// options (resolved profile state)")
    for name in sorted(state):
        if name in skip_inject:
            continue
        enabled, value = state[name]
        if not enabled:
            continue  # disabled => intentionally undefined
        if value is None or value == "":
            out.append("#define %s" % name)
        else:
            out.append("#define %s %s" % (name, value))

    # Iris symbol stubs (only if referenced-and-undeclared).
    stub_lines = []
    for sym, decl in IRIS_SYMBOL_STUBS.items():
        if references_symbol(assembled_source, sym) and not declares_uniform(assembled_source, sym):
            stub_lines.append(decl)

    # Render-stage macros: stub ONLY known ones (F3). Unknown MC_RENDER_STAGE_*
    # tokens are deliberately left undefined here and caught by lint_render_stages
    # so a typo surfaces as a clear failure instead of being masked.
    referenced_stages = set(re.findall(r"\bMC_RENDER_STAGE_[A-Z0-9_]+\b", assembled_source))
    for idx, name in enumerate(KNOWN_RENDER_STAGES):
        if name in referenced_stages and not defines_macro(assembled_source, name):
            stub_lines.append("#ifndef %s\n#define %s %d\n#endif" % (name, name, idx))

    if stub_lines:
        out.append("// Iris symbol stubs (only injected when missing)")
        out.extend(stub_lines)

    out.append("// ==== end injected ====")
    return "\n".join(out)


def patch_source(program_path, shaders_root, state, option_names, macro_stubs,
                 skip_inject=frozenset()):
    """Return the fully patched, glslang-ready source for one program under one
    profile and compile target."""
    assembled = resolve_includes(program_path, shaders_root)
    assembled = strip_option_defines(assembled, option_names)
    injection = build_injection(state, assembled, macro_stubs, skip_inject)

    lines = assembled.splitlines()
    # find the #version line (should be the first non-empty line)
    version_idx = None
    for i, line in enumerate(lines):
        if line.lstrip().startswith("#version"):
            version_idx = i
            break
    if version_idx is None:
        # No #version -> surface as a real problem, inject at very top.
        return injection + "\n" + assembled
    head = lines[: version_idx + 1]
    tail = lines[version_idx + 1:]
    return "\n".join(head) + "\n" + injection + "\n" + "\n".join(tail)


# ---------------------------------------------------------------------------
# Program discovery
# ---------------------------------------------------------------------------

def discover_programs(shaders_root):
    """Return list of (rel_name, abs_path, stage) for every program stage file.
    Programs live at the shaders/ root and (future phases) worldN/ folders.
    lib/ holds includes only and is excluded."""
    progs = []
    patterns = [
        os.path.join(shaders_root, "*.vsh"),
        os.path.join(shaders_root, "*.fsh"),
        os.path.join(shaders_root, "world*", "*.vsh"),
        os.path.join(shaders_root, "world*", "*.fsh"),
    ]
    seen = set()
    for pat in patterns:
        for path in sorted(glob.glob(pat)):
            if os.sep + "lib" + os.sep in path:
                continue
            rp = os.path.realpath(path)
            if rp in seen:
                continue
            seen.add(rp)
            rel = os.path.relpath(path, shaders_root)
            stage = "vert" if path.endswith(".vsh") else "frag"
            progs.append((rel, path, stage))
    return progs


# ---------------------------------------------------------------------------
# glslang
# ---------------------------------------------------------------------------

def find_glslang():
    for name in ("glslangValidator", "glslang"):
        p = shutil.which(name)
        if p:
            return p, name
    return None, None


def run_glslang(glslang_path, glslang_name, patched_path, stage):
    """Run glslang on one file. Returns (ok, output)."""
    cmd = [glslang_path]
    # `glslang` (the newer binary) and `glslangValidator` both accept -S.
    cmd += ["-S", stage, patched_path]
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              universal_newlines=True)
    except OSError as e:
        return False, "failed to invoke glslang: %s" % e
    return proc.returncode == 0, proc.stdout


# ---------------------------------------------------------------------------
# Static lint checks
# ---------------------------------------------------------------------------

# A colortexNFormat / shadowcolorNFormat const declaration and its initializer.
#   groups: (buffer-name, initializer)
FORMAT_CONST_DECL_RE = re.compile(
    r"const\s+int\s+((?:colortex\d+|shadowcolor\d+)Format)\s*=\s*([^;]+);")

# Just the presence of such a declaration (name only), used for the canonical
# 'declared exactly once' check inside comments.
FORMAT_CONST_NAME_RE = re.compile(r"const\s+int\s+(?:colortex\d+|shadowcolor\d+)Format\b")

# An integer literal (decimal or hex) — a valid Format initializer if someone
# hand-codes the GL enum number; a format *identifier* (RGBA16F) is not.
INT_LITERAL_RE = re.compile(r"^[+-]?(?:0[xX][0-9a-fA-F]+|\d+)[uU]?$")

# A `uniform <...>samplerXXX <declarator-list>;` statement. The declarator list
# is captured so we can count comma-separated names (F1).
UNIFORM_SAMPLER_STMT_RE = re.compile(
    r"\buniform\s+(?:(?:lowp|mediump|highp)\s+)?"
    r"[A-Za-z0-9_]*sampler[A-Za-z0-9_]*\s+([^;{}]*?);", re.S)

# The RENDERTARGETS index list inside the directive comment (F4).
RENDERTARGETS_LIST_RE = re.compile(r"/\*\s*RENDERTARGETS\s*:\s*([0-9,\s]+?)\*/", re.I)

# A global fragment `out` declaration (optionally with an explicit location and
# an array size). Function out-params don't match (they end in ')' not ';').
FRAG_OUT_RE = re.compile(
    r"(?:layout\s*\(\s*location\s*=\s*(\d+)\s*\)\s*)?"
    r"\bout\s+(?:(?:lowp|mediump|highp|flat)\s+)*\w+\s+(\w+)\s*"
    r"(?:\[\s*(\d+)\s*\])?\s*;")


def strip_comments(text):
    """Remove block and line comments (so commented-out code doesn't count)."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def extract_comments(text):
    """Return the concatenated *contents* of every block and line comment.
    This is where Iris reads buffer-format declarations from, so the canonical
    format block is found here (not in live code)."""
    parts = []
    for m in re.finditer(r"/\*.*?\*/", text, flags=re.S):
        parts.append(m.group(0)[2:-2])
    for m in re.finditer(r"//([^\n]*)", text):
        parts.append(m.group(1))
    return "\n".join(parts)


def count_samplers(code):
    """Count sampler *declarators*, handling comma-separated lists and sampler
    arrays. `uniform sampler2D a, b, c[4];` => 1 + 1 + 4 = 6."""
    total = 0
    for m in UNIFORM_SAMPLER_STMT_RE.finditer(code):
        for decl in m.group(1).split(","):
            decl = decl.strip()
            if not decl:
                continue
            am = re.search(r"\[\s*(\d+)\s*\]", decl)
            total += int(am.group(1)) if am else 1
    return total


def lint_includes(programs, shaders_root):
    """Iris hard-fails on a missing #include; so do we (F2)."""
    errs = []
    for rel, path, stage in programs:
        missing = []
        resolve_includes(path, shaders_root, missing=missing)
        for includer, line_no, inc, target in missing:
            inc_rel = os.path.relpath(includer, shaders_root)
            tgt_rel = os.path.relpath(target, shaders_root)
            errs.append('%s: unresolved #include "%s" at %s:%d (looked for %s)'
                        % (rel, inc, inc_rel, line_no, tgt_rel))
    return errs


def lint_rendertargets(programs, shaders_root):
    """Every .fsh except shadow/final must carry a RENDERTARGETS comment, and
    its index list must be internally consistent with the fragment's outputs
    (F4): same count as `out` declarations, every index in 0..15, no dupes."""
    errs = []
    for rel, path, stage in programs:
        if stage != "frag":
            continue
        stem = os.path.splitext(os.path.basename(rel))[0]
        if stem in RENDERTARGETS_EXEMPT_STEMS:
            continue
        raw = read_text(path)
        m = RENDERTARGETS_LIST_RE.search(raw)
        if not m:
            errs.append("%s: missing /* RENDERTARGETS: ... */ comment" % rel)
            continue
        tokens = [t for t in re.split(r"[,\s]+", m.group(1).strip()) if t]
        try:
            idxs = [int(t) for t in tokens]
        except ValueError:
            errs.append("%s: malformed RENDERTARGETS list: %r" % (rel, m.group(1).strip()))
            continue
        if not idxs:
            errs.append("%s: empty RENDERTARGETS list" % rel)
            continue
        for ix in idxs:
            if ix < 0 or ix > 15:
                errs.append("%s: RENDERTARGETS index %d out of range 0..15" % (rel, ix))
        if len(set(idxs)) != len(idxs):
            errs.append("%s: RENDERTARGETS has duplicate index(es): %s"
                        % (rel, ", ".join(str(i) for i in idxs)))

        # Count fragment outputs in the assembled source.
        code = strip_comments(resolve_includes(path, shaders_root))
        out_count = 0
        out_locs = []
        for om in FRAG_OUT_RE.finditer(code):
            size = int(om.group(3)) if om.group(3) else 1
            out_count += size
            if om.group(1) is not None:
                out_locs.append(int(om.group(1)))
        if out_count != len(idxs):
            errs.append("%s: %d fragment `out` target(s) but %d RENDERTARGETS entry(ies)"
                        % (rel, out_count, len(idxs)))
        if out_locs and sorted(out_locs) != list(range(len(out_locs))):
            errs.append("%s: explicit `out` locations %s are not a contiguous 0..N-1 set"
                        % (rel, sorted(out_locs)))
    return errs


def lint_sampler_budget(programs, shaders_root):
    """No fragment program may declare > MAX_FRAGMENT_SAMPLERS samplers
    (post-include). Counts declarators, not statements (F1)."""
    errs = []
    for rel, path, stage in programs:
        if stage != "frag":
            continue
        code = strip_comments(resolve_includes(path, shaders_root))
        n = count_samplers(code)
        if n > MAX_FRAGMENT_SAMPLERS:
            errs.append("%s: %d fragment samplers (max %d)" % (rel, n, MAX_FRAGMENT_SAMPLERS))
    return errs


def lint_render_stages(programs, shaders_root):
    """Any referenced MC_RENDER_STAGE_* not on KNOWN_RENDER_STAGES is a typo /
    invalid stage and fails (F3). A shader may define its own as an escape
    hatch (then it isn't 'unknown')."""
    errs = []
    known = set(KNOWN_RENDER_STAGES)
    for rel, path, stage in programs:
        code = strip_comments(resolve_includes(path, shaders_root))
        for tok in sorted(set(re.findall(r"\bMC_RENDER_STAGE_[A-Z0-9_]+\b", code))):
            if tok not in known and not defines_macro(code, tok):
                errs.append("%s: unknown render-stage macro %s "
                            "(typo? not a valid Iris MC_RENDER_STAGE_*)" % (rel, tok))
    return errs


def lint_format_live(programs, shaders_root):
    """HARD FAIL: an UNCOMMENTED colortexNFormat / shadowcolorNFormat const whose
    initializer is a format identifier (not an integer literal).

    Iris reads these declarations from *comments*; a live one leaves an
    identifier like RGBA16F in the GLSL, which real GL drivers reject (this is
    the field bug that shipped when a stub table masked it). We detect this
    post include-resolution but on the comment-stripped ('live') source, so a
    decl inside /* */ or after // is fine.
    """
    errs = []
    for rel, path, stage in programs:
        live = strip_comments(resolve_includes(path, shaders_root))
        for m in FORMAT_CONST_DECL_RE.finditer(live):
            buf, init = m.group(1), m.group(2).strip()
            if not INT_LITERAL_RE.match(init):
                errs.append(
                    "%s: live `const int %s = %s;` — buffer-format identifiers are "
                    "not GLSL and are rejected by real drivers; Iris parses format "
                    "declarations from COMMENTS, so wrap the whole format block in "
                    "/* ... */" % (rel, buf, init))
    return errs


def lint_format_canonical(shaders_root):
    """The canonical buffer-format block (now living inside comments) must
    appear in exactly one source file."""
    files_with = []
    for root, _dirs, files in os.walk(shaders_root):
        for fn in files:
            if not (fn.endswith(".fsh") or fn.endswith(".vsh") or fn.endswith(".glsl")):
                continue
            path = os.path.join(root, fn)
            comments = extract_comments(read_text(path))
            if FORMAT_CONST_NAME_RE.search(comments):
                files_with.append(os.path.relpath(path, shaders_root))
    errs = []
    if len(files_with) == 0:
        errs.append("no commented colortexNFormat/shadowcolorNFormat declarations "
                    "found (expected the canonical format block in exactly one file)")
    elif len(files_with) > 1:
        errs.append("colortexNFormat/shadowcolorNFormat block declared in multiple "
                    "files: %s (must be exactly one)" % ", ".join(sorted(files_with)))
    return errs


def lint_option_consistency(options, profile_refs, screen_refs, lang_option_keys):
    """Cross-check options between settings.glsl, shaders.properties and lang.
    Returns (fail_errors, warnings)."""
    fails = []
    warns = []
    opt_names = set(options.keys())

    # Every referenced option (profiles + screens) must exist in settings.glsl.
    for name in sorted(profile_refs - opt_names):
        fails.append("option %s referenced by a profile does not exist in settings.glsl" % name)
    for name in sorted(screen_refs - opt_names):
        fails.append("option %s referenced by a screen/sliders line does not exist in settings.glsl" % name)

    # Every settings option must appear in some screen.
    for name in sorted(opt_names - screen_refs):
        fails.append("option %s in settings.glsl never appears in a screen" % name)

    # Every settings option should have an option.X lang entry (warn only).
    for name in sorted(opt_names - lang_option_keys):
        warns.append("option %s has no option.%s entry in lang/en_us.lang" % (name, name))

    return fails, warns


def parse_lang_option_keys(lang_path):
    keys = set()
    if not os.path.isfile(lang_path):
        return keys
    for line in read_text(lang_path).splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            continue
        key = s.split("=", 1)[0].strip()
        m = re.match(r"^option\.([A-Za-z0-9_]+)$", key)
        if m:
            keys.add(m.group(1))
    return keys


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

class ValidationResult:
    def __init__(self):
        self.compile_results = {}   # (profile, rel) -> (ok, output)
        self.lint_fails = []
        self.lint_warns = []
        self.setup_errors = []
        self.glslang_available = True
        self.profiles = []
        self.programs = []
        self.targets = []

    def any_failures(self):
        if self.setup_errors or self.lint_fails:
            return True
        for ok, _ in self.compile_results.values():
            if not ok:
                return True
        return False


def run_validation(shaders_root, out_dir, profile_filter=None, program_glob=None,
                   keep=False, require_glslang=True, verbose=True, targets=None):
    """Core pipeline. Returns a ValidationResult."""
    result = ValidationResult()
    if targets is None:
        targets = ["mac"]
    result.targets = list(targets)

    props_path = os.path.join(shaders_root, "shaders.properties")
    settings_path = os.path.join(shaders_root, "settings.glsl")
    lang_path = os.path.join(shaders_root, "lang", "en_us.lang")

    if not os.path.isdir(shaders_root):
        result.setup_errors.append("shaders directory not found: %s" % shaders_root)
        return result
    if not os.path.isfile(props_path):
        result.setup_errors.append("missing shaders.properties: %s" % props_path)
    if not os.path.isfile(settings_path):
        result.setup_errors.append("missing settings.glsl: %s" % settings_path)
    if result.setup_errors:
        return result

    settings_text = read_text(settings_path)
    options = parse_settings(settings_text)

    entries = load_properties(props_path)
    profiles, profile_refs = parse_profiles(entries, options)
    screen_refs = parse_screens(entries, options)
    lang_keys = parse_lang_option_keys(lang_path)

    option_names = set(options.keys())
    # const-style options must never be #define-injected (would corrupt the
    # `const NAME = value;` declaration).
    const_option_names = {n for n, o in options.items() if o.kind == "const"}

    # --- static lints (profile-independent) ---
    all_programs = discover_programs(shaders_root)
    result.programs = [rel for rel, _p, _s in all_programs]

    result.lint_fails += lint_includes(all_programs, shaders_root)
    result.lint_fails += lint_rendertargets(all_programs, shaders_root)
    result.lint_fails += lint_sampler_budget(all_programs, shaders_root)
    result.lint_fails += lint_render_stages(all_programs, shaders_root)
    result.lint_fails += lint_format_live(all_programs, shaders_root)
    result.lint_fails += lint_format_canonical(shaders_root)
    of, ow = lint_option_consistency(options, profile_refs, screen_refs, lang_keys)
    result.lint_fails += of
    result.lint_warns += ow

    # --- select profiles ---
    profile_names = sorted(profiles.keys())
    if profile_filter:
        profile_names = [p for p in profile_names if p in profile_filter]
        if not profile_names:
            result.setup_errors.append("no profiles matched filter: %s" % ", ".join(profile_filter))
            return result
    if not profile_names:
        result.setup_errors.append("no profiles found in shaders.properties")
        return result
    result.profiles = profile_names

    # --- select programs ---
    programs = all_programs
    if program_glob:
        programs = [p for p in programs
                    if fnmatch.fnmatch(os.path.basename(p[0]), program_glob)
                    or fnmatch.fnmatch(p[0], program_glob)]
        if not programs:
            result.setup_errors.append("no programs matched glob: %s" % program_glob)
            return result

    # --- glslang ---
    glslang_path, glslang_name = find_glslang()
    if glslang_path is None:
        result.glslang_available = False
        if require_glslang:
            result.setup_errors.append(
                "glslangValidator not found on PATH — install glslang-tools "
                "(cannot run the compile gate)")
            return result

    # --- compile every target x profile x program ---
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    for target in targets:
        macro_stubs = TARGET_MACROS[target]
        for profile in profile_names:
            state = profiles[profile]
            prof_out = os.path.join(out_dir, target, profile)
            for rel, path, stage in programs:
                patched = patch_source(path, shaders_root, state, option_names,
                                       macro_stubs, const_option_names)
                dest = os.path.join(prof_out, rel)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "w", encoding="utf-8") as f:
                    f.write(patched)
                if result.glslang_available:
                    ok, output = run_glslang(glslang_path, glslang_name, dest, stage)
                else:
                    ok, output = True, "(glslang unavailable — compile skipped)"
                result.compile_results[(target, profile, rel)] = (ok, output)

    if not keep and os.path.isdir(out_dir):
        shutil.rmtree(out_dir)

    return result


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def print_report(result, verbose=True):
    out = sys.stdout

    if result.setup_errors:
        out.write("\nSETUP ERRORS:\n")
        for e in result.setup_errors:
            out.write("  - %s\n" % e)

    # Compile summary table — one matrix per target.
    if result.compile_results:
        profiles = result.profiles
        programs = sorted({rel for (_t, _p, rel) in result.compile_results})
        namew = max([len(p) for p in programs] + [7]) + 2
        for target in result.targets:
            out.write("\nCompile matrix [target=%s] (profile x program):\n\n" % target)
            header = " " * (namew + 2) + "".join("%-9s" % p for p in profiles)
            out.write(header + "\n")
            for rel in programs:
                row = "  %-*s" % (namew, rel)
                for prof in profiles:
                    ok, _ = result.compile_results.get((target, prof, rel), (True, ""))
                    row += "%-9s" % ("OK" if ok else "FAIL")
                out.write(row + "\n")

    # Full glslang output for failures.
    fails = [(k, v) for k, v in result.compile_results.items() if not v[0]]
    if fails:
        out.write("\nCOMPILE FAILURES:\n")
        for (target, prof, rel), (_ok, output) in sorted(fails):
            out.write("\n--- [target=%s] [%s] %s ---\n" % (target, prof, rel))
            out.write(output.rstrip() + "\n")

    if result.lint_fails:
        out.write("\nLINT FAILURES:\n")
        for e in result.lint_fails:
            out.write("  - %s\n" % e)

    if result.lint_warns:
        out.write("\nLINT WARNINGS:\n")
        for w in result.lint_warns:
            out.write("  - %s\n" % w)

    # Verdict.
    n_compile_fail = len(fails)
    if result.any_failures():
        out.write("\nRESULT: FAIL (%d compile failure(s), %d lint failure(s))\n"
                  % (n_compile_fail, len(result.lint_fails)))
    else:
        note = "" if result.glslang_available else " [glslang unavailable — compile skipped]"
        out.write("\nRESULT: PASS%s (%d program(s) x %d profile(s) x %d target(s) [%s], %d warning(s))\n"
                  % (note, len(result.programs), len(result.profiles), len(result.targets),
                     ",".join(result.targets), len(result.lint_warns)))


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

SELFTEST_SETTINGS = """\
// fake settings.glsl for self-test
#define SHADOWS // toggle, on by default
//#define EXTRA_BROKEN // toggle, off by default -> guards broken code
#define VC_QUALITY 2 // [1 2 4]
#define AL_SUN_TINT vec3(1.0, 0.9, 0.8) // internal constant, not an option
// const-style GUI option (Iris idiom), camelCase name, profile-overridable:
const int shadowMapResolution = 2048; // [1024 2048 3072]
"""

SELFTEST_PROPERTIES = """\
iris.features.optional = COMPUTE_SHADERS SSBO
separateEntityDraws = true
program.shadow.enabled = SHADOWS

profile.POTATO = !SHADOWS !EXTRA_BROKEN VC_QUALITY=1 shadowMapResolution=1024
profile.HIGH   = profile.POTATO SHADOWS VC_QUALITY=4 shadowMapResolution=3072
profile.BROKENON = profile.HIGH EXTRA_BROKEN

screen = <profile> [LIGHTING]
screen.LIGHTING = SHADOWS EXTRA_BROKEN VC_QUALITY shadowMapResolution
sliders = VC_QUALITY shadowMapResolution
"""

SELFTEST_LANG = """\
option.SHADOWS=Shadows
option.VC_QUALITY=Cloud Quality
option.shadowMapResolution=Shadow Resolution
# NB: EXTRA_BROKEN intentionally missing -> should produce a lang WARNING
"""

SELFTEST_LIB_UTIL = """\
#ifndef AL_LIB_UTIL
#define AL_LIB_UTIL
#include "/lib/util2.glsl"
float al_util(float x){ return al_util2(x) * 2.0; }
#endif
"""

SELFTEST_LIB_UTIL2 = """\
#ifndef AL_LIB_UTIL2
#define AL_LIB_UTIL2
float al_util2(float x){ return x + 1.0; }
#endif
"""

# Good fragment: valid, has RENDERTARGETS, uses include chain, uses alphaTestRef
# (undeclared -> exercises the stub), and gates broken code behind EXTRA_BROKEN.
SELFTEST_GOOD_FSH = """\
#version 330 compatibility
/* RENDERTARGETS: 0 */
#include "/settings.glsl"
#include "/lib/util.glsl"
uniform sampler2D gtexture;
in vec2 uv;
out vec4 color;
void main(){
    float a = al_util(uv.x);
#ifdef EXTRA_BROKEN
    this is not valid glsl at all &&& ;
#endif
    if (a < alphaTestRef) discard;
    color = vec4(a, VC_QUALITY, 0.0, 1.0);
}
"""

SELFTEST_GOOD_VSH = """\
#version 330 compatibility
#include "/settings.glsl"
out vec2 uv;
void main(){
    uv = vec2(0.0);
    gl_Position = ftransform();
}
"""

# Always-broken fragment (syntax error regardless of options).
SELFTEST_BROKEN_FSH = """\
#version 330 compatibility
/* RENDERTARGETS: 0 */
out vec4 color;
void main(){
    color = vec4(1.0)   // <-- missing semicolon => compile error
    color.x = 0.0;
}
"""

# Fragment deliberately MISSING its RENDERTARGETS comment (lint should catch).
SELFTEST_NORT_FSH = """\
#version 330 compatibility
out vec4 color;
void main(){ color = vec4(1.0); }
"""


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def self_test():
    print("=== validate.py self-test ===")
    glslang_path, _ = find_glslang()
    have_glslang = glslang_path is not None
    print("glslang available: %s" % ("yes" if have_glslang else "NO (compile assertions will be skipped)"))

    tmp = tempfile.mkdtemp(prefix="al-selftest-")
    try:
        sh = os.path.join(tmp, "shaders")
        _write(os.path.join(sh, "settings.glsl"), SELFTEST_SETTINGS)
        _write(os.path.join(sh, "shaders.properties"), SELFTEST_PROPERTIES)
        _write(os.path.join(sh, "lang", "en_us.lang"), SELFTEST_LANG)
        _write(os.path.join(sh, "lib", "util.glsl"), SELFTEST_LIB_UTIL)
        _write(os.path.join(sh, "lib", "util2.glsl"), SELFTEST_LIB_UTIL2)
        _write(os.path.join(sh, "deferred.fsh"), SELFTEST_GOOD_FSH)
        _write(os.path.join(sh, "deferred.vsh"), SELFTEST_GOOD_VSH)
        # Canonical buffer-format block: lives INSIDE a comment (the location
        # Iris reads it from). final.fsh is the single source of truth.
        _write(os.path.join(sh, "final.fsh"),
               "#version 330 compatibility\n"
               "/* Buffer formats (Iris reads these from this comment):\n"
               "const int colortex0Format = RGBA16F;\n"
               "const int colortex1Format = RGBA8;\n"
               "*/\n"
               "out vec4 c;\nvoid main(){ c = vec4(1.0); }\n")

        failures = []

        def check(cond, msg):
            status = "ok " if cond else "FAIL"
            print("  [%s] %s" % (status, msg))
            if not cond:
                failures.append(msg)

        # --- Part 1: the good pack should PASS ---
        out_dir = os.path.join(tmp, "out")
        res = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)

        # parsing sanity
        check("SHADOWS" in res.programs or True, "programs discovered: %s" % ", ".join(sorted(res.programs)))
        check(set(res.profiles) == {"POTATO", "HIGH", "BROKENON"},
              "profiles parsed: %s" % ", ".join(sorted(res.profiles)))
        # EXTRA_BROKEN lang warning present
        check(any("EXTRA_BROKEN" in w and "lang" in w for w in res.lint_warns),
              "missing-lang option produces a warning")
        # no lint FAILURES on the good pack
        check(not res.lint_fails, "clean pack has no lint failures (got: %s)" % res.lint_fails)

        if have_glslang:
            # good program compiles under POTATO and HIGH (EXTRA_BROKEN off)
            check(res.compile_results[("mac", "POTATO", "deferred.fsh")][0],
                  "good .fsh compiles under POTATO (EXTRA_BROKEN disabled)")
            check(res.compile_results[("mac", "HIGH", "deferred.fsh")][0],
                  "good .fsh compiles under HIGH")
            check(res.compile_results[("mac", "POTATO", "deferred.vsh")][0],
                  "good .vsh compiles under POTATO")
            # under BROKENON, EXTRA_BROKEN is defined -> broken code compiled in
            check(not res.compile_results[("mac", "BROKENON", "deferred.fsh")][0],
                  "profile define injection works: EXTRA_BROKEN=on breaks the .fsh")

        # good programs pass under --target both (restrict to the profiles that
        # are meant to compile; BROKENON exists specifically to fail).
        res_both = run_validation(sh, out_dir, keep=False, require_glslang=False,
                                  verbose=False, targets=["mac", "advanced"],
                                  profile_filter={"POTATO", "HIGH"})
        check(not res_both.any_failures(),
              "good programs pass under --target both (mac + advanced), POTATO/HIGH")

        # --- Part 2: an always-broken program should FAIL ---
        _write(os.path.join(sh, "composite.fsh"), SELFTEST_BROKEN_FSH)
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        res2 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        if have_glslang:
            check(not res2.compile_results[("mac", "HIGH", "composite.fsh")][0],
                  "always-broken .fsh is caught as a compile FAILURE")
            check(res2.any_failures(), "overall result is FAIL when a program is broken")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # --- Part 3: missing RENDERTARGETS is a lint failure ---
        _write(os.path.join(sh, "prepare.fsh"), SELFTEST_NORT_FSH)
        _write(os.path.join(sh, "prepare.vsh"), SELFTEST_GOOD_VSH)
        res3 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("prepare.fsh" in e and "RENDERTARGETS" in e for e in res3.lint_fails),
              "missing RENDERTARGETS comment is caught as a lint failure")
        os.remove(os.path.join(sh, "prepare.fsh"))
        os.remove(os.path.join(sh, "prepare.vsh"))

        # --- Part 4: duplicate canonical format block (2nd file) is caught ---
        # A second file with the format block *in a comment* => two canonical
        # sources => fail. (Commented, so it must NOT trip the live-format lint.)
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "// const int colortex2Format = RGBA16F;\n"
               "out vec4 c;\nvoid main(){c=vec4(1.0);}\n")
        res4 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("Format" in e and "multiple" in e for e in res4.lint_fails),
              "duplicate canonical format block across files is caught")
        check(not any("live `const int" in e for e in res4.lint_fails),
              "a commented format decl does NOT trip the live-format lint")
        os.remove(os.path.join(sh, "composite.fsh"))

        # --- Part 5: option referenced by profile but absent from settings ---
        bad_props = SELFTEST_PROPERTIES + "\nprofile.BADREF = GHOST_OPTION\n"
        _write(os.path.join(sh, "shaders.properties"), bad_props)
        res5 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("GHOST_OPTION" in e for e in res5.lint_fails),
              "profile referencing a non-existent option is caught")
        _write(os.path.join(sh, "shaders.properties"), SELFTEST_PROPERTIES)

        # --- Regression F1: comma-separated sampler list over budget ---
        samplers = ", ".join("s%d" % i for i in range(17))  # 17 samplers, one stmt
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "uniform sampler2D %s;\nout vec4 c;\nvoid main(){ c = texture(s0, vec2(0.0)); }\n"
               % samplers)
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        resF1 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "17 fragment samplers" in e for e in resF1.lint_fails),
              "F1: comma-separated 17-sampler declaration is counted and fails the 16 budget")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # --- Regression F2: unresolved #include hard-fails ---
        _write(os.path.join(sh, "composite.fsh"),
               '#version 330 compatibility\n/* RENDERTARGETS: 0 */\n'
               '#include "/lib/does_not_exist.glsl"\nout vec4 c;\nvoid main(){ c = vec4(1.0); }\n')
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        resF2 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "unresolved #include" in e and "does_not_exist" in e
                  for e in resF2.lint_fails),
              "F2: an unresolved #include is a hard lint failure (with includer:line)")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # --- Regression F3: unknown MC_RENDER_STAGE_* fails (typo) ---
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "uniform int renderStage;\nout vec4 c;\n"
               "void main(){ c = vec4(renderStage == MC_RENDER_STAGE_VOIDD ? 1.0 : 0.0); }\n")
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        resF3 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "MC_RENDER_STAGE_VOIDD" in e for e in resF3.lint_fails),
              "F3: a misspelled MC_RENDER_STAGE_* is caught (not silently stubbed)")
        # and a correctly-spelled stage does NOT fail
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "uniform int renderStage;\nout vec4 c;\n"
               "void main(){ c = vec4(renderStage == MC_RENDER_STAGE_STARS ? 1.0 : 0.0); }\n")
        resF3b = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(not any("MC_RENDER_STAGE_STARS" in e for e in resF3b.lint_fails),
              "F3: a valid MC_RENDER_STAGE_* is accepted")
        if have_glslang:
            check(resF3b.compile_results[("mac", "HIGH", "composite.fsh")][0],
                  "F3: valid render-stage program also compiles (stub injected)")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # --- Regression F4: out-count vs RENDERTARGETS mismatch fails ---
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "out vec4 a;\nout vec4 b;\nvoid main(){ a = vec4(1.0); b = vec4(0.0); }\n")
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        resF4 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "RENDERTARGETS" in e and "target(s)" in e
                  for e in resF4.lint_fails),
              "F4: 2 outs but 1 RENDERTARGETS entry is caught as a mismatch")
        # duplicate index is also caught
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 1,1 */\n"
               "out vec4 a;\nout vec4 b;\nvoid main(){ a = vec4(1.0); b = vec4(0.0); }\n")
        resF4b = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "duplicate" in e for e in resF4b.lint_fails),
              "F4: duplicate RENDERTARGETS index is caught")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # --- Regression FIELD BUG (a): live (uncommented) format const with a
        # format identifier must FAIL the lint AND (now the stub table is gone)
        # actually fail to compile, instead of the masked false PASS that
        # shipped to the user's M4 Mac. ---
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "const int colortex0Format = RGBA16F;\n"   # LIVE, not commented
               "out vec4 c;\nvoid main(){ c = vec4(1.0); }\n")
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        resFB = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("composite.fsh" in e and "live `const int colortex0Format" in e
                  for e in resFB.lint_fails),
              "FIELD(a): uncommented format const with identifier initializer is a hard lint FAIL")
        if have_glslang:
            check(not resFB.compile_results[("mac", "HIGH", "composite.fsh")][0],
                  "FIELD(a): the format identifier now reaches glslang and fails (mask removed)")
        os.remove(os.path.join(sh, "composite.fsh"))
        os.remove(os.path.join(sh, "composite.vsh"))

        # a LIVE format const with an INTEGER initializer is NOT flagged (only
        # format-identifier initializers are).
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "const int colortex0Format = 34842;\n"
               "out vec4 c;\nvoid main(){ c = vec4(1.0); }\n")
        resFBi = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(not any("live `const int" in e for e in resFBi.lint_fails),
              "FIELD: a live format const with an integer literal is not flagged")
        os.remove(os.path.join(sh, "composite.fsh"))

        # (b) the comment-wrapped canonical block in the good pack's final.fsh
        # PASSES the live lint and satisfies the single-source lint (proved by
        # the good pack being lint-clean in Part 1 -> re-assert explicitly here).
        check(not any("Format" in e for e in res.lint_fails),
              "FIELD(b): comment-wrapped format block passes live + single-source lints")

        # (c) const-style slider option: parsed, screen-recognised, and
        # profile-overridable (shadowMapResolution).
        _opts = parse_settings(SELFTEST_SETTINGS)
        check(_opts.get("shadowMapResolution") is not None
              and _opts["shadowMapResolution"].kind == "const"
              and _opts["shadowMapResolution"].value == "2048",
              "const(c): `const int shadowMapResolution ... // [..]` parsed as a const option")
        _entries = load_properties(os.path.join(sh, "shaders.properties"))
        _profs, _ = parse_profiles(_entries, _opts)
        check(_profs["POTATO"]["shadowMapResolution"] == (True, "1024")
              and _profs["HIGH"]["shadowMapResolution"] == (True, "3072"),
              "const(c): profiles override the const option value (POTATO=1024, HIGH=3072)")
        check("shadowMapResolution" in parse_screens(_entries, _opts),
              "const(c): camelCase const option recognised in screen/sliders lines")
        if have_glslang:
            check(res.compile_results[("mac", "HIGH", "deferred.fsh")][0],
                  "const(c): const option is NOT #define-injected (program still compiles)")

        # --- Regression F2 (mac-hw target): the SEPARATE_HARDWARE_SAMPLERS flag
        # must be injected under MC_OS_MAC for the M4's hardware-PCSS branch.
        # hwtest.fsh: the flag branch is valid; the else branch is broken. So it
        # compiles under mac-hw (flag ON) and FAILS under plain mac (flag OFF) —
        # proving the flag genuinely flips per target, not that the code is
        # always valid. ---
        _write(os.path.join(sh, "hwtest.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "out vec4 c;\n"
               "#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS\n"
               "uniform sampler2DShadow shadowtex0HW;   // only on the HW path\n"
               "#endif\n"
               "void main(){\n"
               "#ifdef IRIS_FEATURE_SEPARATE_HARDWARE_SAMPLERS\n"
               "    c = vec4(1.0);                       // valid HW-path code\n"
               "#else\n"
               "    @@@ not-valid-glsl @@@ ;             // active only when flag OFF\n"
               "#endif\n"
               "}\n")
        _write(os.path.join(sh, "hwtest.vsh"), SELFTEST_GOOD_VSH)
        resHW = run_validation(sh, out_dir, keep=False, require_glslang=False,
                               verbose=False, targets=["mac", "mac-hw", "advanced"])
        check(resHW.targets == ["mac", "mac-hw", "advanced"],
              "mac-hw: three targets run (mac, mac-hw, advanced)")
        if have_glslang:
            check(resHW.compile_results[("mac-hw", "HIGH", "hwtest.fsh")][0],
                  "mac-hw: SEPARATE_HARDWARE_SAMPLERS injected under MC_OS_MAC (HW branch compiles)")
            check(not resHW.compile_results[("mac", "HIGH", "hwtest.fsh")][0],
                  "mac-hw: plain mac does NOT inject the flag (HW branch compiled out, else active)")
            check(resHW.compile_results[("advanced", "HIGH", "hwtest.fsh")][0],
                  "mac-hw: advanced also has the flag (HW branch compiles)")
        os.remove(os.path.join(sh, "hwtest.fsh"))
        os.remove(os.path.join(sh, "hwtest.vsh"))

        print("")
        if failures:
            print("SELF-TEST FAILED: %d assertion(s) failed" % len(failures))
            return 1
        print("SELF-TEST PASSED%s" % ("" if have_glslang else " (glslang steps skipped)"))
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def default_shaders_root():
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.join(os.path.dirname(here), "shaders")


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Asteria Loom shader compile gate (glslang over every profile x program).")
    ap.add_argument("--shaders-dir", default=None,
                    help="path to the shaders/ directory (default: ../shaders relative to this script)")
    ap.add_argument("--out", default=None,
                    help="build dir for patched output (default: <repo>/out/patched)")
    ap.add_argument("--profile", action="append", default=None,
                    help="restrict to a profile (repeatable)")
    ap.add_argument("--program", default=None,
                    help="restrict to programs matching this glob (e.g. 'gbuffers_*.fsh')")
    ap.add_argument("--target",
                    choices=["mac", "mac-hw", "advanced", "both", "all"], default="mac",
                    help="compile-macro environment(s): mac (plain M4 path, default), "
                         "mac-hw (M4 + hardware shadow sampling), "
                         "advanced (Windows/AL_ADVANCED_TIER path), "
                         "both (mac+advanced, back-compat), or all (mac+mac-hw+advanced)")
    ap.add_argument("--keep", action="store_true",
                    help="keep the patched output under --out instead of deleting it")
    ap.add_argument("--self-test", action="store_true",
                    help="run the built-in self-test (fabricates a tiny fake pack) and exit")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()

    shaders_root = args.shaders_dir or default_shaders_root()
    shaders_root = os.path.realpath(shaders_root)
    repo_root = os.path.dirname(shaders_root)
    out_dir = args.out or os.path.join(repo_root, "out", "patched")

    target_sets = {
        "both": ["mac", "advanced"],
        "all": ["mac", "mac-hw", "advanced"],
    }
    targets = target_sets.get(args.target, [args.target])

    result = run_validation(
        shaders_root, out_dir,
        profile_filter=set(args.profile) if args.profile else None,
        program_glob=args.program,
        keep=args.keep,
        require_glslang=True,
        targets=targets,
    )
    print_report(result)

    if result.setup_errors:
        return 2
    return 1 if result.any_failures() else 0


if __name__ == "__main__":
    sys.exit(main())
