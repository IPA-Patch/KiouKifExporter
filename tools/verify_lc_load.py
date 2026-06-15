#!/usr/bin/env python3
"""Smoke test: verify that a Mach-O contains an ``LC_LOAD_DYLIB`` (or
``LC_LOAD_WEAK_DYLIB``) entry pointing at a specific dylib path.

Walks every load command of every architecture slice and prints each
``LOAD_DYLIB`` / ``LOAD_WEAK_DYLIB`` entry it finds. The needle to match
against is supplied with ``--needle`` or, when omitted, looked up from
``--recipe``'s ``DYLIB_PATH`` attribute.

Exit status:
  0  at least one slice references the needle
  1  no slice references the needle
  2  input file is missing / unparseable / lief unavailable

Designed as a CI step to confirm ``patch_macho.py`` ran successfully and
the patched binary is fit to bundle into the .ipa.
"""

from __future__ import annotations

import argparse
import importlib
import sys


def _needle_from_recipe(name: str) -> str:
    if "." not in name:
        name = f"tools.recipes.{name}"
    try:
        mod = importlib.import_module(name)
    except ImportError as e:
        raise SystemExit(f"error: failed to import recipe {name!r}: {e}") from e
    needle = getattr(mod, "DYLIB_PATH", None)
    if not needle:
        raise SystemExit(f"error: recipe {name!r} does not define DYLIB_PATH")
    return needle


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify that a Mach-O loads a given dylib via LC_LOAD_DYLIB.",
    )
    parser.add_argument("target", help="Path to the Mach-O.")
    parser.add_argument(
        "--needle",
        help="Dylib path to look for (e.g. @executable_path/Frameworks/Foo.dylib).",
    )
    parser.add_argument(
        "--recipe",
        help="Recipe to source DYLIB_PATH from when --needle is not supplied.",
    )
    args = parser.parse_args()

    if not args.needle and not args.recipe:
        print(
            "error: pass --needle <path> or --recipe <name>", file=sys.stderr
        )
        return 2

    needle = args.needle or _needle_from_recipe(args.recipe)

    try:
        import lief
    except ImportError:
        print("error: lief is not installed", file=sys.stderr)
        return 2

    parsed = lief.MachO.parse(args.target)
    if parsed is None:
        print(f"error: failed to parse {args.target}", file=sys.stderr)
        return 2

    if isinstance(parsed, lief.MachO.FatBinary):
        slices = [parsed.at(i) for i in range(parsed.size)]
    else:
        slices = [parsed]

    found_anywhere = False
    for idx, binary in enumerate(slices):
        cpu = binary.header.cpu_type
        print(f"=== slice[{idx}] cpu={cpu} ===")
        slice_found = False
        for cmd in binary.commands:
            cmd_type = cmd.command
            name = getattr(cmd_type, "name", str(cmd_type))
            if name not in ("LOAD_DYLIB", "LOAD_WEAK_DYLIB"):
                continue
            lib_name = getattr(cmd, "name", "<unknown>")
            marker = " <-- MATCH" if lib_name == needle else ""
            print(f"  {name}: {lib_name}{marker}")
            if lib_name == needle:
                slice_found = True
                found_anywhere = True
        if not slice_found:
            print(f"  (no entry matching {needle})")

    if found_anywhere:
        print(f"\nOK: {needle} is present.")
        return 0
    print(f"\nFAIL: {needle} not found in any slice.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
