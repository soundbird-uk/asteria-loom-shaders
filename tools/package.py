#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Asteria Loom — release packager.

Builds one or both distributable zips:

  * dist/AsteriaLoom-<version>.zip           — the DEFAULT pack. Mac-safe:
    built from `shaders/` alone, and asserted to contain ZERO `.csh`.
  * dist/AsteriaLoom-Advanced-<version>.zip  — Windows/Linux ONLY. Built from
    `shaders/` with the `shaders-advanced/` OVERLAY copied on top.

Iris expects the zip root to CONTAIN a `shaders/` folder (drop the zip on Iris,
or unzip into shaderpacks/), so the archive members are `shaders/...` for BOTH
variants — the advanced overlay lives in `shaders-advanced/` in the repo but is
packed into the same `shaders/` prefix.

WHY TWO ZIPS (field-confirmed 2026-07): Iris compiles EVERY `.csh` a pack ships,
unconditionally — `ProgramSet.readComputeArray` is not feature-gated — and macOS
(OpenGL 4.1) cannot compile compute shaders. So a single `.csh` anywhere in the
pack makes the WHOLE pack fail to load on macOS; `#ifdef` gating does not help,
the file's mere presence is fatal. The compute-using "advanced tier" therefore
has to ship as a separate archive. The mac-variant `.csh` assertion below is the
guard that keeps a stray overlay file from ever reaching the default zip.

OVERLAY CONTRACT: `shaders-advanced/` mirrors `shaders/` path-for-path and holds
ONLY files that differ from, or are new relative to, the canonical tree. Files
are keyed by their in-zip arcname, so an overlay entry REPLACES the base entry
of the same path. The tree is never duplicated.

ONE EXCEPTION — `shaders.properties` is APPENDED, not replaced. Replacing it
would force the overlay to restate every profile/screen/slider/directive of the
canonical file just to add two advanced lines, and that copy would go silently
stale on the next edit to the base. So the overlay supplies a FRAGMENT
(`shaders.properties.append`) and the packed file is base + separator +
fragment, built by tools/overlay_props.py — the same module tools/validate.py
uses, so what is validated is byte-identical to what ships. A full-replacement
`shaders.properties` in the overlay is a hard ERROR here.

Version resolution order:
  1. --version argument
  2. first `## [x.y.z]` heading in CHANGELOG.md
  3. the literal string "dev"

stdlib only. Python 3.8+.
"""

import argparse
import os
import re
import sys
import zipfile

# Shared with tools/validate.py — the single definition of how the overlay's
# shaders.properties fragment is merged onto the canonical file. Same directory
# as this script, so a plain import resolves when running `python3 tools/...`.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import overlay_props  # noqa: E402

# Repo-relative source roots. BASE is canonical and Mac-safe; OVERLAY is the
# thin delta applied on top of it for the advanced build.
BASE_ROOT_NAME = "shaders"
OVERLAY_ROOT_NAME = "shaders-advanced"

# The in-zip prefix Iris expects, for every variant.
ARC_PREFIX = "shaders"

# Files/dirs we never want in a distributed pack.
EXCLUDE_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini", ".gitkeep"}
EXCLUDE_DIR_NAMES = {"__pycache__", ".git"}
EXCLUDE_SUFFIXES = (".swp", ".swo", ".orig", ".rej", "~", ".pyc")
# Root-level paths (relative to a source root) that are repo documentation or
# build inputs, not shader assets:
#   * README.md                    — documents the overlay contract.
#   * shaders.properties.append    — the overlay's properties FRAGMENT. It is a
#     build input, not a file Iris understands; it is merged into
#     shaders.properties below and must never appear in the zip on its own.
EXCLUDE_REL_PATHS = {"README.md", overlay_props.APPEND_NAME}

# Which source roots each variant is built from, in overlay order.
VARIANT_ROOTS = {
    "mac": [BASE_ROOT_NAME],
    "advanced": [BASE_ROOT_NAME, OVERLAY_ROOT_NAME],
}

CHANGELOG_VERSION_RE = re.compile(r"^\s*##\s*\[?(\d+\.\d+\.\d+[^\]\s]*)\]?", re.M)


def resolve_version(repo_root, explicit):
    if explicit:
        return explicit
    changelog = os.path.join(repo_root, "CHANGELOG.md")
    if os.path.isfile(changelog):
        with open(changelog, "r", encoding="utf-8", errors="replace") as f:
            m = CHANGELOG_VERSION_RE.search(f.read())
            if m:
                return m.group(1)
    return "dev"


def should_exclude(name):
    if name in EXCLUDE_NAMES:
        return True
    for suf in EXCLUDE_SUFFIXES:
        if name.endswith(suf):
            return True
    return False


def collect_files(roots):
    """Collect the packable files from `roots` (a list of absolute source dirs,
    in overlay order).

    Returns an ordered dict arcname -> abs_path. Keying by arcname is what makes
    the overlay work: a later root's file REPLACES an earlier root's file at the
    same in-zip path, and new overlay paths simply add entries. arcnames are
    prefixed with 'shaders/' so the zip root contains the folder Iris wants.
    """
    collected = {}
    for src_root in roots:
        if not os.path.isdir(src_root):
            continue
        for root, dirs, files in os.walk(src_root):
            # prune excluded directories in place
            dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIR_NAMES)
            for fn in sorted(files):
                if should_exclude(fn):
                    continue
                abs_path = os.path.join(root, fn)
                rel = os.path.relpath(abs_path, src_root).replace(os.sep, "/")
                if rel in EXCLUDE_REL_PATHS:
                    continue
                arcname = ARC_PREFIX + "/" + rel
                collected[arcname] = abs_path
    return collected


def zip_name(variant, version):
    if variant == "advanced":
        return "AsteriaLoom-Advanced-%s.zip" % version
    return "AsteriaLoom-%s.zip" % version


def build_variant(variant, repo_root, out_dir, version):
    """Build one variant's zip. Returns (rc, zip_path_or_None)."""
    roots = [os.path.join(repo_root, name) for name in VARIANT_ROOTS[variant]]
    if not os.path.isdir(roots[0]):
        sys.stderr.write("error: %s/ not found at %s\n" % (BASE_ROOT_NAME, roots[0]))
        return 2, None

    collected = collect_files(roots)
    if not collected:
        sys.stderr.write("error: no files collected for variant '%s'\n" % variant)
        return 2, None

    # ---- GENERATED members (content not read from a single source file) ------
    # arcname -> text. Currently just the merged shaders.properties for the
    # advanced variant; the base one stays a plain file copy.
    generated = {}
    if variant == "advanced":
        base_root = os.path.join(repo_root, BASE_ROOT_NAME)
        overlay_root = os.path.join(repo_root, OVERLAY_ROOT_NAME)
        try:
            merged = overlay_props.merged_properties(base_root, overlay_root)
        except overlay_props.OverlayPropsError as e:
            sys.stderr.write("error: %s\n" % e)
            return 3, None
        if merged is not None:
            generated[ARC_PREFIX + "/" + overlay_props.PROPS_NAME] = merged

    # ---- HARD SAFETY ASSERT (the reason the split exists) -------------------
    # The mac/default zip must contain ZERO compute programs. Iris compiles
    # every .csh it finds, and macOS GL 4.1 cannot compile compute shaders, so
    # one stray file breaks pack loading entirely. Refuse to write the archive.
    if variant == "mac":
        stray = sorted(a for a in collected if a.endswith(".csh"))
        if stray:
            sys.stderr.write(
                "error: refusing to write the macOS-safe pack — %d compute program(s) "
                "(.csh) would be included:\n" % len(stray))
            for a in stray:
                sys.stderr.write("  - %s  (from %s)\n" % (a, collected[a]))
            sys.stderr.write(
                "Iris compiles every .csh a pack ships and macOS (OpenGL 4.1) cannot "
                "compile compute shaders, so the whole pack would fail to load. Compute "
                "programs belong in %s/ and ship only in the Advanced zip.\n"
                % OVERLAY_ROOT_NAME)
            return 3, None

    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, zip_name(variant, version))
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for arcname in sorted(collected):
            # A generated member replaces the file that would otherwise be
            # copied at this path (the merged properties supersedes the base
            # file copy) — written from text so the zip carries exactly the
            # bytes tools/validate.py compiled against.
            if arcname in generated:
                zf.writestr(arcname, generated.pop(arcname))
            else:
                zf.write(collected[arcname], arcname)
        for arcname in sorted(generated):     # generated-only paths, if any
            zf.writestr(arcname, generated[arcname])

    print("Packaged %d file(s) [variant=%s] -> %s" % (len(collected), variant, zip_path))
    return 0, zip_path


def default_repo_root():
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.dirname(here)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Package Asteria Loom into Iris-installable zip(s).")
    ap.add_argument("--version", default=None,
                    help="version string (default: from CHANGELOG.md, else 'dev')")
    ap.add_argument("--repo-root", default=None,
                    help="repo root (default: parent of this script's dir)")
    ap.add_argument("--out-dir", default=None,
                    help="output dir for the zip(s) (default: <repo>/dist)")
    ap.add_argument("--variant", choices=["mac", "advanced", "all"], default="mac",
                    help="which pack to build: mac (default, macOS-safe, zero .csh), "
                         "advanced (shaders/ + shaders-advanced/ overlay; Windows/Linux "
                         "only), or all (both)")
    args = ap.parse_args(argv)

    repo_root = os.path.realpath(args.repo_root or default_repo_root())
    version = resolve_version(repo_root, args.version)
    out_dir = args.out_dir or os.path.join(repo_root, "dist")

    variants = ["mac", "advanced"] if args.variant == "all" else [args.variant]
    for variant in variants:
        rc, _path = build_variant(variant, repo_root, out_dir, version)
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
