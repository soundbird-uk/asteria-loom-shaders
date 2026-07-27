#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Asteria Loom — the ADVANCED overlay's shaders.properties APPEND mechanism.

WHY THIS MODULE EXISTS (and why it is shared rather than duplicated):

`shaders-advanced/` is a thin overlay whose files REPLACE their `shaders/`
counterpart by path. That is exactly right for a program the advanced build
genuinely rewrites — and exactly WRONG for `shaders.properties`, which is one
big file describing the WHOLE pack (profiles, screens, sliders, blend/size/
program directives). An overlay copy of it would have to restate all of that
just to add two advanced lines, and would then silently go stale on every edit
to the canonical file: the Mac zip would get the new profile/screen/slider and
the Advanced zip would keep serving a months-old copy. Nothing would fail —
the pack would just quietly behave differently in the two builds. That class of
bug (a directive that is read by nobody / by the wrong reader, failing SILENTLY)
is the same one that cost this pack every temporal feature once already.

So the overlay does NOT get to replace shaders.properties. It supplies a
FRAGMENT — `shaders-advanced/shaders.properties.append` — and the effective
file shipped in the Advanced zip is:

    shaders/shaders.properties   (verbatim, always current)
  + SEPARATOR                    (a loud, generated comment banner)
  + the .append fragment

Both consumers of the overlay build the merged file through THIS module —
`tools/package.py` when it writes the Advanced zip, and `tools/validate.py`
when `materialize_overlay()` stages the merged tree for the compile gate — so
the file the validator checks is byte-identical to the file that ships. If the
merge logic lived in both scripts it would be two sources of truth for the
thing whose entire purpose is to stop there being two sources of truth.

Java `.properties` semantics (what Iris parses this with): on a DUPLICATE key
the LAST assignment wins. Since the fragment is concatenated last, it can both
ADD keys and OVERRIDE base keys — but it can never lose a base key it does not
mention, which is the whole point.

stdlib only. Python 3.8+.
"""

import os

# The canonical properties file, relative to a source root.
PROPS_NAME = "shaders.properties"

# The overlay's fragment. Deliberately NOT named `*.properties`: it is not a
# loadable file on its own, and the name makes the append relationship obvious
# in a directory listing. It is never shipped inside the zip.
APPEND_NAME = "shaders.properties.append"

# The banner written between base and fragment. Kept here (not in either tool)
# so the two tools cannot drift by a single character — the equality of their
# outputs is what the CI diff check asserts.
SEPARATOR = """
# ===========================================================================
# BEGIN ADVANCED OVERLAY APPEND
# ---------------------------------------------------------------------------
# GENERATED FILE — do not edit this copy.
#
# Everything ABOVE this banner is shaders/shaders.properties verbatim (the
# canonical, macOS-safe file). Everything BELOW comes from
# shaders-advanced/%s and applies only to the
# Windows/Linux Advanced build.
#
# The two halves are concatenated at build time by tools/package.py and
# reproduced identically by tools/validate.py, so the Advanced zip can never
# carry a stale copy of the canonical directives. Edit
# shaders/shaders.properties (for both builds) or the .append fragment (for the
# Advanced build only) — never this merged result.
#
# .properties duplicate-key rule: the LAST assignment wins, and the fragment is
# last, so it may override a base key as well as add new ones.
# ===========================================================================
""" % APPEND_NAME


class OverlayPropsError(Exception):
    """A structurally invalid overlay (e.g. a full-replacement properties file).
    Both tools turn this into a clear, actionable error and refuse to build."""


def base_props_path(base_root):
    return os.path.join(base_root, PROPS_NAME)


def append_path(overlay_root):
    return os.path.join(overlay_root, APPEND_NAME)


def check_overlay(base_root, overlay_root):
    """Raise OverlayPropsError if the overlay violates the append contract.

    The one hard rule: the overlay must NOT contain a full `shaders.properties`.
    That is the staleness trap this module exists to close, and it fails
    silently (a stale copy is still a perfectly valid file), so it has to be a
    build-time ERROR that names the replacement mechanism rather than a warning
    nobody reads.
    """
    full = os.path.join(overlay_root, PROPS_NAME)
    if os.path.isfile(full):
        raise OverlayPropsError(
            "%s is a FULL REPLACEMENT of the canonical properties file, which the "
            "overlay contract forbids: it duplicates every profile/screen/slider/"
            "directive of shaders/%s and goes silently stale the moment the "
            "canonical file changes (the Mac zip gets the edit, the Advanced zip "
            "keeps the old copy, and nothing errors). Delete it and put ONLY the "
            "advanced-specific lines in %s — the build concatenates base + "
            "separator + fragment for you."
            % (os.path.join(os.path.basename(overlay_root), PROPS_NAME),
               PROPS_NAME, os.path.join(os.path.basename(overlay_root), APPEND_NAME)))

    if os.path.isfile(append_path(overlay_root)) and not os.path.isfile(base_props_path(base_root)):
        raise OverlayPropsError(
            "overlay supplies %s but the base tree has no %s to append to (%s)"
            % (APPEND_NAME, PROPS_NAME, base_props_path(base_root)))


def _read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def merge_text(base_text, append_text):
    """base + separator + fragment. The only place the join is defined."""
    if not base_text.endswith("\n"):
        base_text += "\n"
    if append_text and not append_text.endswith("\n"):
        append_text += "\n"
    return base_text + SEPARATOR + append_text


def merged_properties(base_root, overlay_root):
    """Return the effective shaders.properties text for the Advanced build, or
    None when the overlay ships no fragment (then the base file is used as-is).

    Raises OverlayPropsError on a contract violation (see check_overlay)."""
    check_overlay(base_root, overlay_root)
    ap = append_path(overlay_root)
    if not os.path.isfile(ap):
        return None
    return merge_text(_read(base_props_path(base_root)), _read(ap))
