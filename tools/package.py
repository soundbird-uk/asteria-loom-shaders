#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Asteria Loom — release packager.

Builds dist/AsteriaLoom-<version>.zip. Iris expects the zip root to CONTAIN a
`shaders/` folder (drop the zip on Iris, or unzip into shaderpacks/), so the
archive members are `shaders/...`.

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

# Files/dirs we never want in a distributed pack.
EXCLUDE_NAMES = {".DS_Store", "Thumbs.db", "desktop.ini", ".gitkeep"}
EXCLUDE_DIR_NAMES = {"__pycache__", ".git"}
EXCLUDE_SUFFIXES = (".swp", ".swo", ".orig", ".rej", "~", ".pyc")

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


def collect_files(shaders_root):
    """Yield (abs_path, arcname) for every packable file under shaders/.
    arcname is prefixed with 'shaders/' so the zip root contains the folder."""
    for root, dirs, files in os.walk(shaders_root):
        # prune excluded directories in place
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDE_DIR_NAMES)
        for fn in sorted(files):
            if should_exclude(fn):
                continue
            abs_path = os.path.join(root, fn)
            rel = os.path.relpath(abs_path, shaders_root)
            arcname = os.path.join("shaders", rel).replace(os.sep, "/")
            yield abs_path, arcname


def default_repo_root():
    here = os.path.dirname(os.path.realpath(__file__))
    return os.path.dirname(here)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Package Asteria Loom into an Iris-installable zip.")
    ap.add_argument("--version", default=None,
                    help="version string (default: from CHANGELOG.md, else 'dev')")
    ap.add_argument("--repo-root", default=None,
                    help="repo root (default: parent of this script's dir)")
    ap.add_argument("--out-dir", default=None,
                    help="output dir for the zip (default: <repo>/dist)")
    args = ap.parse_args(argv)

    repo_root = os.path.realpath(args.repo_root or default_repo_root())
    shaders_root = os.path.join(repo_root, "shaders")
    if not os.path.isdir(shaders_root):
        sys.stderr.write("error: shaders/ not found at %s\n" % shaders_root)
        return 2

    version = resolve_version(repo_root, args.version)
    out_dir = args.out_dir or os.path.join(repo_root, "dist")
    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, "AsteriaLoom-%s.zip" % version)

    count = 0
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for abs_path, arcname in collect_files(shaders_root):
            zf.write(abs_path, arcname)
            count += 1

    if count == 0:
        sys.stderr.write("error: no files packaged from %s\n" % shaders_root)
        os.remove(zip_path)
        return 2

    print("Packaged %d file(s) -> %s" % (count, zip_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
