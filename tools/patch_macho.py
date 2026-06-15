#!/usr/bin/env python3
"""Generic Mach-O static patcher.

Loads a recipe (a Python module under ``tools.recipes``) describing what
to patch and applies it to a target Mach-O. The recipe is fully
self-contained — it owns the cave region, the hook slot RVA, the patch
list, and the dylib name — so this driver carries zero per-target
knowledge.

Recipe contract — the module must expose:

  TARGET_BASENAME : str   expected ``os.path.basename(target)``
  DYLIB_PATH      : str   ``LC_LOAD_DYLIB`` target
  HOOK_SLOT_RVA   : int   the __DATA,__bss slot the dylib will publish
                          its hook pointer into (validated against the
                          binary's section layout before any write)
  CAVE_REGION     : (int, int)  (start, end_exclusive) for cave payloads
  PATCHES         : list  see tools.caves.InlinePatch
  CAVE_PATCHES    : list  see tools.caves.CavePatch

The recipe is the only place per-target constants live; the driver does
not interpret them, only iterates.

Usage:
  python3 -m tools.patch_macho --recipe kioukifexporter <path-to-macho>
  python3 -m tools.patch_macho --recipe kioukifexporter <macho> --verify-only
"""

from __future__ import annotations

import argparse
import importlib
import os
import sys

from tools.caves import apply_patches
from tools.machoops import add_lc_load_dylib, assert_slot_in_bss, reserve_hook_slot


def _load_recipe(name: str):
    """Import a recipe module by short name (e.g. ``kioukifexporter``)
    or fully-qualified module path (e.g. ``tools.recipes.kioukifexporter``).
    """
    if "." not in name:
        name = f"tools.recipes.{name}"
    try:
        return importlib.import_module(name)
    except ImportError as e:
        raise SystemExit(f"error: failed to import recipe {name!r}: {e}") from e


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Apply a static-patch recipe to a Mach-O binary.",
    )
    parser.add_argument(
        "target",
        help="Path to the Mach-O to patch.",
    )
    parser.add_argument(
        "--recipe",
        required=True,
        help="Recipe to apply (module name under tools.recipes, or full module path).",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Report match/mismatch without writing.",
    )
    parser.add_argument(
        "--no-add-dylib",
        action="store_true",
        help="Skip the LC_LOAD_DYLIB insertion step (debug aid).",
    )
    parser.add_argument(
        "--skip-target-check",
        action="store_true",
        help="Do not enforce that os.path.basename(target) == recipe.TARGET_BASENAME.",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.target):
        print(f"error: not a file: {args.target}", file=sys.stderr)
        return 2

    recipe = _load_recipe(args.recipe)
    target_basename = getattr(recipe, "TARGET_BASENAME", None)
    if target_basename and not args.skip_target_check:
        if os.path.basename(args.target) != target_basename:
            print(
                f"error: recipe {args.recipe!r} expects target basename "
                f"{target_basename!r}, but got {os.path.basename(args.target)!r}. "
                "Pass --skip-target-check to override.",
                file=sys.stderr,
            )
            return 1

    hook_slot_rva = getattr(recipe, "HOOK_SLOT_RVA", None)
    cave_region = getattr(recipe, "CAVE_REGION", None)
    patches = getattr(recipe, "PATCHES", [])
    cave_patches = getattr(recipe, "CAVE_PATCHES", [])
    dylib_path = getattr(recipe, "DYLIB_PATH", None)

    # ----- safety: confirm the recipe's hook slot still lives in __bss
    # We do this first, before any write, so a stale constant fails
    # loudly instead of corrupting the binary.
    if cave_patches and hook_slot_rva is not None:
        try:
            assert_slot_in_bss(args.target, hook_slot_rva)
        except RuntimeError as e:
            print(f"  FAIL  {e}", file=sys.stderr)
            return 1

    # ----- inline and cave patches -----
    if patches or cave_patches:
        if cave_region is None:
            print(
                "error: recipe defines CAVE_PATCHES but no CAVE_REGION.",
                file=sys.stderr,
            )
            return 1
        failures = apply_patches(
            args.target,
            patches,
            cave_patches,
            cave_region,
            verify_only=args.verify_only,
        )
        if failures:
            print(f"\n{failures} mismatch(es) — aborting.", file=sys.stderr)
            return 1

    # ----- LC_LOAD_DYLIB insertion -----
    if dylib_path and not args.no_add_dylib and not args.verify_only:
        try:
            add_lc_load_dylib(args.target, dylib_path)
        except NotImplementedError as e:
            print(f"  WARN  {e}", file=sys.stderr)

    # ----- hook slot probe -----
    # Sanity check: confirm the runtime-discovered slot still matches
    # the baked-in recipe constant the caves were compiled against.
    if hook_slot_rva is not None:
        try:
            slot_rva = reserve_hook_slot(args.target)
            if slot_rva is not None:
                print(f"  INFO  recipe HOOK_SLOT_RVA = 0x{hook_slot_rva:X}")
                if slot_rva != hook_slot_rva:
                    print(
                        f"  WARN  slot VA drift: reserve_hook_slot returned "
                        f"0x{slot_rva:X}, but caves were built against "
                        f"0x{hook_slot_rva:X}. Re-pin the recipe constant and "
                        "re-patch the binary.",
                        file=sys.stderr,
                    )
        except NotImplementedError as e:
            print(f"  WARN  {e}", file=sys.stderr)

    print("\nVerify pass complete." if args.verify_only else "\nAll patches applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
