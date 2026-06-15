#!/usr/bin/env python3
"""
Patch a KIOU.app/Info.plist to expose its sandbox through Files.app.

Adds the two keys iOS reads at install time to decide whether the bundle
shows up under "On My iPhone -> <app>" in the Files app:

    UIFileSharingEnabled               = YES
    LSSupportsOpeningDocumentsInPlace  = YES

Idempotent — re-running on an already-patched plist is a no-op.

The input can be either a binary plist or an XML plist; plistlib chooses
the right reader automatically. The output is rewritten in the same
format the input had (binary stays binary, XML stays XML), so the bundle
keeps whatever shape its codesign hashes expect.
"""

from __future__ import annotations

import argparse
import plistlib
import sys


KEYS = (
    ("UIFileSharingEnabled", True),
    ("LSSupportsOpeningDocumentsInPlace", True),
)


def detect_format(raw: bytes) -> plistlib.PlistFormat:
    if raw.startswith(b"bplist"):
        return plistlib.FMT_BINARY
    return plistlib.FMT_XML


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Add UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace to an Info.plist.",
    )
    parser.add_argument("plist", help="Path to Info.plist (read+write).")
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Print whether the keys are already present without writing.",
    )
    args = parser.parse_args()

    with open(args.plist, "rb") as f:
        raw = f.read()
    fmt = detect_format(raw)
    pl = plistlib.loads(raw)

    changed = []
    for key, value in KEYS:
        cur = pl.get(key)
        if cur == value:
            print(f"  SKIP  {key} = {value} (already set)")
            continue
        if args.verify_only:
            print(f"  TODO  {key} = {value} (currently {cur!r})")
            changed.append(key)
            continue
        pl[key] = value
        print(f"  SET   {key} = {value} (was {cur!r})")
        changed.append(key)

    if args.verify_only:
        return 0

    if not changed:
        print("Info.plist already exposes Files.app — no write needed.")
        return 0

    with open(args.plist, "wb") as f:
        plistlib.dump(pl, f, fmt=fmt)
    fmt_label = "binary" if fmt == plistlib.FMT_BINARY else "XML"
    print(f"Wrote {args.plist} ({fmt_label}, {len(changed)} key(s) updated).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
