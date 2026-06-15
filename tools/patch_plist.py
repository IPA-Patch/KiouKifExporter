#!/usr/bin/env python3
"""Set keys on an Info.plist (or any plist) in place.

Adds/overwrites the given keys on the plist at ``--target``. Keys come
from either ``--recipe <name>`` (a recipe module under ``tools.recipes``
exposing ``PLIST_KEYS: dict``) or one or more ``--set KEY=VALUE`` flags
on the command line.

Value parsing for ``--set``:
  - ``true`` / ``false`` (case-insensitive) become Python booleans.
  - An integer literal becomes ``int``.
  - Anything else is stored as a string.

Idempotent — re-running on an already-patched plist is a no-op.

The input can be either a binary plist or an XML plist; ``plistlib``
chooses the right reader automatically. The output is rewritten in the
same format the input had (binary stays binary, XML stays XML), so the
bundle keeps whatever shape its codesign hashes expect.
"""

from __future__ import annotations

import argparse
import importlib
import plistlib
import sys


def _detect_format(raw: bytes) -> plistlib.PlistFormat:
    if raw.startswith(b"bplist"):
        return plistlib.FMT_BINARY
    return plistlib.FMT_XML


def _parse_kv(s: str) -> tuple[str, object]:
    if "=" not in s:
        raise argparse.ArgumentTypeError(f"--set value must be KEY=VALUE, got {s!r}")
    key, raw_value = s.split("=", 1)
    if not key:
        raise argparse.ArgumentTypeError(f"--set key is empty in {s!r}")
    lowered = raw_value.strip().lower()
    if lowered == "true":
        return key, True
    if lowered == "false":
        return key, False
    try:
        return key, int(raw_value)
    except ValueError:
        return key, raw_value


def _load_recipe_keys(name: str) -> dict:
    if "." not in name:
        name = f"tools.recipes.{name}"
    try:
        mod = importlib.import_module(name)
    except ImportError as e:
        raise SystemExit(f"error: failed to import recipe {name!r}: {e}") from e
    keys = getattr(mod, "PLIST_KEYS", None)
    if not isinstance(keys, dict):
        raise SystemExit(
            f"error: recipe {name!r} does not define PLIST_KEYS dict"
        )
    return keys


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Set keys on a plist (Info.plist or any other).",
    )
    parser.add_argument("target", help="Path to the plist (read+write).")
    parser.add_argument(
        "--recipe",
        help="Recipe to pull PLIST_KEYS from (module name under tools.recipes).",
    )
    parser.add_argument(
        "--set",
        action="append",
        default=[],
        metavar="KEY=VALUE",
        help="Set an individual key. Repeatable. Booleans/ints are parsed; "
        "everything else is stored as a string.",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Print whether the keys are already present without writing.",
    )
    args = parser.parse_args()

    keys: dict = {}
    if args.recipe:
        keys.update(_load_recipe_keys(args.recipe))
    for kv in args.set:
        k, v = _parse_kv(kv)
        keys[k] = v

    if not keys:
        print(
            "error: nothing to set — pass --recipe or one or more --set KEY=VALUE",
            file=sys.stderr,
        )
        return 2

    with open(args.target, "rb") as f:
        raw = f.read()
    fmt = _detect_format(raw)
    pl = plistlib.loads(raw)

    changed = []
    for key, value in keys.items():
        cur = pl.get(key)
        if cur == value:
            print(f"  SKIP  {key} = {value!r} (already set)")
            continue
        if args.verify_only:
            print(f"  TODO  {key} = {value!r} (currently {cur!r})")
            changed.append(key)
            continue
        pl[key] = value
        print(f"  SET   {key} = {value!r} (was {cur!r})")
        changed.append(key)

    if args.verify_only:
        return 0

    if not changed:
        print(f"{args.target}: nothing to do — all keys already set.")
        return 0

    with open(args.target, "wb") as f:
        plistlib.dump(pl, f, fmt=fmt)
    fmt_label = "binary" if fmt == plistlib.FMT_BINARY else "XML"
    print(f"Wrote {args.target} ({fmt_label}, {len(changed)} key(s) updated).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
