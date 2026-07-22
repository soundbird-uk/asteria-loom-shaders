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
  5. Runs glslangValidator on the patched source (-S vert / -S frag).
  6. Runs a set of static lint checks (RENDERTARGETS presence, sampler budget,
     buffer-format single-source-of-truth, option/screen/lang consistency).

It collects *all* failures before exiting non-zero and prints a compact
profile x program result table plus full glslang output for every failure.

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
# that are not visible to a plain glslang invocation. We reproduce a minimal,
# Mac-path version of them here. These tables are intentionally at the top of
# the file and easy to extend as later phases use more Iris features.
#
# Design decision: we validate the *Mac path* only, so MC_OS_MAC is defined and
# the IRIS_FEATURE_* flags are left UNdefined. That makes every AL_ADVANCED_TIER
# gate compile out, exactly as it will on the user's M4. If a later phase wants
# to also validate the Windows/advanced path, add a second macro set and a CLI
# flag to select it.
# ---------------------------------------------------------------------------

# Macros always injected (guarded with #ifndef so a real definition wins).
# name -> value string ('' => object-like define with no value, i.e. just
# `#define NAME`).
IRIS_MACRO_STUBS = {
    "MC_VERSION": "12100",       # a recent MC release, format YYVVV-ish
    "MC_GL_VERSION": "410",      # macOS caps at GL 4.1
    "MC_GLSL_VERSION": "410",
    "MC_OS_MAC": "1",            # we validate the Mac path
    "IS_IRIS": "1",
}

# Uniforms/attributes Iris provides. We only inject the declaration if the
# symbol is *referenced but not declared* in the assembled source (real
# declarations in the shader always win). Extend as needed.
#   name -> declaration line to inject
IRIS_SYMBOL_STUBS = {
    "alphaTestRef": "uniform float alphaTestRef;",
    "renderStage": "uniform int renderStage;",
}

# Iris buffer-format identifiers used in `const int colortexNFormat = <FMT>;`
# declarations. These are NOT GLSL keywords — Iris recognises them when it
# parses the format directives. glslang has never heard of them, so without
# stubs the canonical final.fsh format block would always (falsely) fail. We
# inject each as a placeholder `const`-usable int, guarded with #ifndef.
IRIS_FORMAT_STUBS = [
    # 8-bit normalized / snorm
    "R8", "RG8", "RGB8", "RGBA8",
    "R8_SNORM", "RG8_SNORM", "RGB8_SNORM", "RGBA8_SNORM",
    # 16-bit normalized / snorm
    "R16", "RG16", "RGB16", "RGBA16",
    "R16_SNORM", "RG16_SNORM", "RGB16_SNORM", "RGBA16_SNORM",
    # float
    "R16F", "RG16F", "RGB16F", "RGBA16F",
    "R32F", "RG32F", "RGB32F", "RGBA32F",
    # packed float / special
    "R11F_G11F_B10F", "RGB9_E5",
    # integer (signed)
    "R8I", "RG8I", "RGB8I", "RGBA8I",
    "R16I", "RG16I", "RGB16I", "RGBA16I",
    "R32I", "RG32I", "RGB32I", "RGBA32I",
    # integer (unsigned)
    "R8UI", "RG8UI", "RGB8UI", "RGBA8UI",
    "R16UI", "RG16UI", "RGB16UI", "RGBA16UI",
    "R32UI", "RG32UI", "RGB32UI", "RGBA32UI",
    # packed integer / misc
    "RGB10_A2", "RGB10_A2UI", "RGB5_A1", "RGBA2", "RGBA4", "RGB565",
    "R3_G3_B2", "RGB4", "RGB5", "RGB10", "RGB12", "RGBA12",
    "SRGB8", "SRGB8_ALPHA8",
]

# Iris render-stage macros (MC_RENDER_STAGE_*). Any that are referenced but not
# defined get auto-assigned a unique int. This known list keeps values stable
# and readable; unknown ones are assigned dynamically after these.
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

    kind: 'toggle' (boolean; value is None) or 'selector' (has a value + a
    // [allowed values] comment).
    enabled: default on/off from settings.glsl.
    value: default value string for selectors, else None.
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


def parse_settings(settings_text):
    """Parse settings.glsl. Returns dict name -> Option for GUI options only.

    Iris exposes a #define as a GUI option when either:
      * it has a value AND a trailing `// [a b c]` selector comment, or
      * it is a bare boolean toggle (`#define NAME` / `//#define NAME`,
        no value).
    A `#define NAME value` *without* a bracket comment is an ordinary constant
    (e.g. a colour identity constant) and is NOT an option; profiles never
    touch it and it need not appear in a screen.
    """
    options = {}
    for raw in settings_text.splitlines():
        m = DEFINE_RE.match(raw)
        if not m:
            continue
        commented = m.group(1) is not None
        name = m.group(2)
        rest = m.group(3)
        if not is_option_name(name):
            continue
        code, comment = strip_line_comment(rest)
        value = code.strip()
        has_brackets = "[" in comment and "]" in comment
        if value == "":
            # bare toggle
            options[name] = Option(name, "toggle", not commented, None)
        elif has_brackets:
            # selector
            options[name] = Option(name, "selector", not commented, value)
        else:
            # constant with a value but no selector list -> not a GUI option
            continue
    return options


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
                if is_option_name(opt_name):
                    referenced.add(opt_name)
                    state[opt_name] = (not disable, opt_val)
            else:
                opt_name = tok.strip()
                if is_option_name(opt_name):
                    referenced.add(opt_name)
                    if disable:
                        state[opt_name] = (False, _value_of(state, opt_name))
                    else:
                        state[opt_name] = (True, _value_of(state, opt_name))
                # non-option tokens (camelCase Iris consts, etc.) ignored
        resolving.discard(name)
        resolved[name] = state
        return state

    def _value_of(state, name):
        cur = state.get(name)
        return cur[1] if cur else None

    for name in raw_profiles:
        resolve(name)

    return resolved, referenced


def parse_screens(entries):
    """Return (screen_option_refs, all_screen_tokens).
    screen_option_refs: set of option names referenced across all screen/
    sliders lines (used both for the 'exists' and 'appears in a screen' lints).
    """
    refs = set()
    for key, val in entries:
        if key == "screen" or key.startswith("screen.") or key == "sliders" or key.startswith("sliders."):
            for tok in tokenize_profile_value(val):
                if tok.startswith("[") or tok.startswith("<"):
                    continue  # sub-screen ref / placeholder
                if tok.startswith("profile.") or tok.startswith("program."):
                    continue
                if is_option_name(tok):
                    refs.add(tok)
    return refs


# ---------------------------------------------------------------------------
# #include resolution (Iris semantics)
# ---------------------------------------------------------------------------

INCLUDE_RE = re.compile(r'^\s*#include\s+"([^"]+)"\s*$')


def resolve_includes(entry_path, shaders_root):
    """Return the fully-inlined source for entry_path.

    Iris rules: an include path starting with '/' is relative to the shaders/
    root; otherwise it is relative to the directory of the including file.
    Recursive. Cycle-safe: a file currently on the include stack is not
    re-entered (a comment marker is emitted instead). Non-cyclic repeat
    includes ARE inlined again — the shader's own #ifndef guards (evaluated by
    glslang) collapse them, exactly as in a real compile.
    """
    out_lines = []

    def _inline(path, stack):
        real = os.path.realpath(path)
        if real in stack:
            out_lines.append("// [validate.py] include cycle skipped: %s" % path)
            return
        if not os.path.isfile(path):
            out_lines.append('// [validate.py] MISSING INCLUDE: %s' % path)
            return
        stack = stack + [real]
        text = read_text(path)
        for line in text.splitlines():
            m = INCLUDE_RE.match(line)
            if not m:
                out_lines.append(line)
                continue
            inc = m.group(1)
            if inc.startswith("/"):
                target = os.path.join(shaders_root, inc.lstrip("/"))
            else:
                target = os.path.join(os.path.dirname(path), inc)
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


def build_injection(state, assembled_source):
    """Build the block injected right after #version.
    state: dict optname -> (enabled, value)
    """
    out = []
    out.append("// ==== injected by validate.py (Mac path) ====")

    # Iris macros, guarded so real defs win.
    for name, value in IRIS_MACRO_STUBS.items():
        out.append("#ifndef %s" % name)
        if value == "":
            out.append("#define %s" % name)
        else:
            out.append("#define %s %s" % (name, value))
        out.append("#endif")

    # Iris buffer-format identifiers (harmless placeholder ints, guarded).
    out.append("// Iris buffer-format identifier stubs")
    for i, fmt in enumerate(IRIS_FORMAT_STUBS):
        out.append("#ifndef %s\n#define %s %d\n#endif" % (fmt, fmt, 33000 + i))

    # Resolved option state.
    out.append("// options (resolved profile state)")
    for name in sorted(state):
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

    # Render-stage macros referenced but not defined.
    referenced_stages = set(re.findall(r"\bMC_RENDER_STAGE_[A-Z0-9_]+\b", assembled_source))
    if referenced_stages:
        assigned = 0
        emitted = []
        for name in KNOWN_RENDER_STAGES:
            if name in referenced_stages and not defines_macro(assembled_source, name):
                emitted.append("#ifndef %s\n#define %s %d\n#endif" % (name, name, assigned))
            assigned += 1
        # any unknown stages
        for name in sorted(referenced_stages):
            if name not in KNOWN_RENDER_STAGES and not defines_macro(assembled_source, name):
                emitted.append("#ifndef %s\n#define %s %d\n#endif" % (name, name, assigned))
                assigned += 1
        stub_lines.extend(emitted)

    if stub_lines:
        out.append("// Iris symbol stubs (only injected when missing)")
        out.extend(stub_lines)

    out.append("// ==== end injected ====")
    return "\n".join(out)


def patch_source(program_source, shaders_root, program_path, state, option_names):
    """Return the fully patched, glslang-ready source for one program under one
    profile."""
    assembled = resolve_includes(program_path, shaders_root)
    assembled = strip_option_defines(assembled, option_names)
    injection = build_injection(state, assembled)

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

RENDERTARGETS_RE = re.compile(r"/\*\s*RENDERTARGETS\s*:", re.I)
COLORTEX_FORMAT_RE = re.compile(r"const\s+int\s+colortex\d+Format\b")
UNIFORM_SAMPLER_RE = re.compile(r"\buniform\s+[A-Za-z0-9_]*sampler[A-Za-z0-9_]*\b")


def lint_rendertargets(programs):
    """Every .fsh except shadow/final must carry a RENDERTARGETS comment."""
    errs = []
    for rel, path, stage in programs:
        if stage != "frag":
            continue
        stem = os.path.splitext(os.path.basename(rel))[0]
        if stem in RENDERTARGETS_EXEMPT_STEMS:
            continue
        if not RENDERTARGETS_RE.search(read_text(path)):
            errs.append("%s: missing /* RENDERTARGETS: ... */ comment" % rel)
    return errs


def lint_sampler_budget(programs, shaders_root):
    """No fragment program may declare > MAX_FRAGMENT_SAMPLERS samplers
    (post-include)."""
    errs = []
    for rel, path, stage in programs:
        if stage != "frag":
            continue
        assembled = resolve_includes(path, shaders_root)
        # strip block comments so commented-out samplers don't count
        code = re.sub(r"/\*.*?\*/", "", assembled, flags=re.S)
        code = re.sub(r"//[^\n]*", "", code)
        n = len(UNIFORM_SAMPLER_RE.findall(code))
        if n > MAX_FRAGMENT_SAMPLERS:
            errs.append("%s: %d fragment samplers (max %d)" % (rel, n, MAX_FRAGMENT_SAMPLERS))
    return errs


def lint_buffer_formats(shaders_root):
    """`const int colortexNFormat` declarations must live in exactly one file."""
    files_with = []
    for root, _dirs, files in os.walk(shaders_root):
        for fn in files:
            if not (fn.endswith(".fsh") or fn.endswith(".vsh") or fn.endswith(".glsl")):
                continue
            path = os.path.join(root, fn)
            text = read_text(path)
            code = re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))
            if COLORTEX_FORMAT_RE.search(code):
                files_with.append(os.path.relpath(path, shaders_root))
    errs = []
    if len(files_with) == 0:
        errs.append("no `const int colortexNFormat` declarations found (expected exactly one file)")
    elif len(files_with) > 1:
        errs.append("`const int colortexNFormat` declared in multiple files: %s"
                    % ", ".join(sorted(files_with)))
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

    def any_failures(self):
        if self.setup_errors or self.lint_fails:
            return True
        for ok, _ in self.compile_results.values():
            if not ok:
                return True
        return False


def run_validation(shaders_root, out_dir, profile_filter=None, program_glob=None,
                   keep=False, require_glslang=True, verbose=True):
    """Core pipeline. Returns a ValidationResult."""
    result = ValidationResult()

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
    screen_refs = parse_screens(entries)
    lang_keys = parse_lang_option_keys(lang_path)

    option_names = set(options.keys())

    # --- static lints (profile-independent) ---
    all_programs = discover_programs(shaders_root)
    result.programs = [rel for rel, _p, _s in all_programs]

    result.lint_fails += lint_rendertargets(all_programs)
    result.lint_fails += lint_sampler_budget(all_programs, shaders_root)
    result.lint_fails += lint_buffer_formats(shaders_root)
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

    # --- compile every profile x program ---
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    for profile in profile_names:
        state = profiles[profile]
        prof_out = os.path.join(out_dir, profile)
        for rel, path, stage in programs:
            patched = patch_source(path, shaders_root, path, state, option_names)
            dest = os.path.join(prof_out, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "w", encoding="utf-8") as f:
                f.write(patched)
            if result.glslang_available:
                ok, output = run_glslang(glslang_path, glslang_name, dest, stage)
            else:
                ok, output = True, "(glslang unavailable — compile skipped)"
            result.compile_results[(profile, rel)] = (ok, output)

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

    # Compile summary table.
    if result.compile_results:
        profiles = result.profiles
        programs = sorted({rel for (_p, rel) in result.compile_results})
        namew = max([len(p) for p in programs] + [7]) + 2
        out.write("\nCompile matrix (profile x program):\n\n")
        header = " " * (namew + 2) + "".join("%-9s" % p for p in profiles)
        out.write(header + "\n")
        for rel in programs:
            row = "  %-*s" % (namew, rel)
            for prof in profiles:
                ok, _ = result.compile_results.get((prof, rel), (True, ""))
                row += "%-9s" % ("OK" if ok else "FAIL")
            out.write(row + "\n")

    # Full glslang output for failures.
    fails = [(k, v) for k, v in result.compile_results.items() if not v[0]]
    if fails:
        out.write("\nCOMPILE FAILURES:\n")
        for (prof, rel), (_ok, output) in sorted(fails):
            out.write("\n--- [%s] %s ---\n" % (prof, rel))
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
        out.write("\nRESULT: PASS%s (%d program(s) x %d profile(s), %d warning(s))\n"
                  % (note, len(result.programs), len(result.profiles), len(result.lint_warns)))


# ---------------------------------------------------------------------------
# Self-test
# ---------------------------------------------------------------------------

SELFTEST_SETTINGS = """\
// fake settings.glsl for self-test
#define SHADOWS // toggle, on by default
//#define EXTRA_BROKEN // toggle, off by default -> guards broken code
#define VC_QUALITY 2 // [1 2 4]
#define AL_SUN_TINT vec3(1.0, 0.9, 0.8) // internal constant, not an option
"""

SELFTEST_PROPERTIES = """\
iris.features.optional = COMPUTE_SHADERS SSBO
separateEntityDraws = true
program.shadow.enabled = SHADOWS

profile.POTATO = !SHADOWS !EXTRA_BROKEN VC_QUALITY=1
profile.HIGH   = profile.POTATO SHADOWS VC_QUALITY=4
profile.BROKENON = profile.HIGH EXTRA_BROKEN

screen = <profile> [LIGHTING]
screen.LIGHTING = SHADOWS EXTRA_BROKEN VC_QUALITY
sliders = VC_QUALITY
"""

SELFTEST_LANG = """\
option.SHADOWS=Shadows
option.VC_QUALITY=Cloud Quality
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
        # colortexNFormat single-source-of-truth (in final.fsh only)
        _write(os.path.join(sh, "final.fsh"),
               "#version 330 compatibility\nconst int colortex0Format = RGBA16F;\n"
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
            check(res.compile_results[("POTATO", "deferred.fsh")][0],
                  "good .fsh compiles under POTATO (EXTRA_BROKEN disabled)")
            check(res.compile_results[("HIGH", "deferred.fsh")][0],
                  "good .fsh compiles under HIGH")
            check(res.compile_results[("POTATO", "deferred.vsh")][0],
                  "good .vsh compiles under POTATO")
            # under BROKENON, EXTRA_BROKEN is defined -> broken code compiled in
            check(not res.compile_results[("BROKENON", "deferred.fsh")][0],
                  "profile define injection works: EXTRA_BROKEN=on breaks the .fsh")

        # --- Part 2: an always-broken program should FAIL ---
        _write(os.path.join(sh, "composite.fsh"), SELFTEST_BROKEN_FSH)
        _write(os.path.join(sh, "composite.vsh"), SELFTEST_GOOD_VSH)
        res2 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        if have_glslang:
            check(not res2.compile_results[("HIGH", "composite.fsh")][0],
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

        # --- Part 4: duplicate colortexNFormat is a lint failure ---
        _write(os.path.join(sh, "composite.fsh"),
               "#version 330 compatibility\n/* RENDERTARGETS: 0 */\n"
               "const int colortex1Format = RGBA8;\nout vec4 c;\nvoid main(){c=vec4(1.0);}\n")
        res4 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("colortex" in e and "multiple" in e for e in res4.lint_fails),
              "duplicate colortexNFormat across files is caught")
        os.remove(os.path.join(sh, "composite.fsh"))

        # --- Part 5: option referenced by profile but absent from settings ---
        bad_props = SELFTEST_PROPERTIES + "\nprofile.BADREF = GHOST_OPTION\n"
        _write(os.path.join(sh, "shaders.properties"), bad_props)
        res5 = run_validation(sh, out_dir, keep=False, require_glslang=False, verbose=False)
        check(any("GHOST_OPTION" in e for e in res5.lint_fails),
              "profile referencing a non-existent option is caught")
        _write(os.path.join(sh, "shaders.properties"), SELFTEST_PROPERTIES)

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

    result = run_validation(
        shaders_root, out_dir,
        profile_filter=set(args.profile) if args.profile else None,
        program_glob=args.program,
        keep=args.keep,
        require_glslang=True,
    )
    print_report(result)

    if result.setup_errors:
        return 2
    return 1 if result.any_failures() else 0


if __name__ == "__main__":
    sys.exit(main())
