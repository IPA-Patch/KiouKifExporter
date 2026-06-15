#!/usr/bin/env python3
"""Smoke test: verify that a UnityFramework Mach-O contains an
``LC_LOAD_DYLIB`` (or ``LC_LOAD_WEAK_DYLIB``) entry pointing at
KiouKifExporter.dylib.

Walks every load command of every architecture slice and prints each
``LOAD_DYLIB`` / ``LOAD_WEAK_DYLIB`` entry it finds. Exit status:

  0 — at least one slice references
       ``@executable_path/Frameworks/KiouKifExporter.dylib``
  1 — no slice references it
  2 — input file is missing / unparseable / lief unavailable

Designed as a CI step to confirm ``patch_unity.py`` ran successfully and
the patched binary is fit to bundle into the .ipa.
"""

from __future__ import annotations

import argparse
import sys

DEFAULT_NEEDLE = "@executable_path/Frameworks/KiouKifExporter.dylib"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Verify that a Mach-O loads KiouKifExporter.dylib via LC_LOAD_DYLIB.",
    )
    parser.add_argument("target", help="Path to UnityFramework Mach-O")
    parser.add_argument(
        "--needle",
        default=DEFAULT_NEEDLE,
        help=f"Dylib path to look for (default: {DEFAULT_NEEDLE}).",
    )
    args = parser.parse_args()

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
            # Match either LC_LOAD_DYLIB or LC_LOAD_WEAK_DYLIB.
            name = getattr(cmd_type, "name", str(cmd_type))
            if name not in ("LOAD_DYLIB", "LOAD_WEAK_DYLIB"):
                continue
            lib_name = getattr(cmd, "name", "<unknown>")
            marker = " <-- MATCH" if lib_name == args.needle else ""
            print(f"  {name}: {lib_name}{marker}")
            if lib_name == args.needle:
                slice_found = True
                found_anywhere = True
        if not slice_found:
            print(f"  (no entry matching {args.needle})")

    if found_anywhere:
        print(f"\nOK: {args.needle} is present.")
        return 0
    print(f"\nFAIL: {args.needle} not found in any slice.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
