"""Target-agnostic engine for applying inline patches and cave-routed
patches to a Mach-O on disk.

A recipe supplies:

  - ``PATCHES``: a list of ``(file_offset, expected_orig, replacement, label)``
    inline single-or-multi-byte replacements.
  - ``CAVE_PATCHES``: a list of ``(site_off, expected_orig_insn,
    build_payload, label)`` where ``build_payload(cave_va) -> bytes``
    constructs the cave contents given the cave's allocated virtual
    address. The original 4-byte instruction at ``site_off`` is replaced
    with ``B <cave_va>``.
  - ``CAVE_REGION``: the (start, end) file offsets carved out for cave
    payloads. The driver allocates caves sequentially from ``start``;
    overflow past ``end`` is a build-time error.

The driver itself never names what is being patched. That keeps it
reusable across binaries and across feature scopes.
"""

from __future__ import annotations

from typing import Callable

from .encode import b_imm

InlinePatch = tuple[int, bytes, bytes, str]
CavePatch = tuple[int, bytes, Callable[[int], bytes], str]
CaveRegion = tuple[int, int]


def apply_patches(
    target_path: str,
    patches: list[InlinePatch],
    cave_patches: list[CavePatch],
    cave_region: CaveRegion,
    *,
    verify_only: bool = False,
) -> int:
    """Walk ``patches`` and ``cave_patches`` against the file at
    ``target_path`` and apply them in place (or report what would be
    written, when ``verify_only`` is set).

    Returns the number of failed entries; 0 means the file is now (or
    already was) fully patched.

    Idempotency: each entry's "already applied" state is detected
    byte-for-byte. Re-running this function on an already-patched binary
    is a no-op (every entry prints SKIP).
    """
    if not patches and not cave_patches:
        return 0

    cave_start, cave_end = cave_region
    mode = "rb" if verify_only else "r+b"
    with open(target_path, mode) as f:
        failures = 0
        for off, expected, new, label in patches:
            if len(new) != len(expected):
                raise AssertionError(
                    f"patch length mismatch for {label}: "
                    f"expected={len(expected)} new={len(new)}"
                )
            f.seek(off)
            cur = f.read(len(expected))
            tag = f"[{off:#x}] {label}"
            if cur == new:
                print(f"  SKIP  {tag} (already patched)")
                continue
            if cur != expected:
                failures += 1
                print(
                    f"  FAIL  {tag}\n"
                    f"        expected {expected.hex()}\n"
                    f"        got      {cur.hex()}"
                )
                continue
            if verify_only:
                print(f"  OK    {tag} (orig matches; would patch)")
            else:
                f.seek(off)
                f.write(new)
                print(f"  PATCH {tag}")

        # Allocate caves sequentially from cave_start in declaration
        # order. Allocation is deterministic so re-runs land cave bytes
        # at the exact same addresses, and the "already patched" SKIP
        # path can match both the site and the cave content byte-for-byte.
        cave_cursor = cave_start
        for site_off, expected, build_payload, label in cave_patches:
            if len(expected) != 4:
                raise AssertionError(f"cave-patch site must be one 4B insn: {label}")

            payload = build_payload(cave_cursor)
            if len(payload) % 4 != 0:
                raise AssertionError(
                    f"cave payload not 4B-aligned for {label}: len={len(payload)}"
                )
            if cave_cursor + len(payload) > cave_end:
                print(
                    f"  FAIL  cave overflow for {label}: "
                    f"need 0x{len(payload):X} B at 0x{cave_cursor:X}, "
                    f"only 0x{cave_end - cave_cursor:X} B remain"
                )
                failures += 1
                continue

            site_patch = b_imm(site_off, cave_cursor)
            tag = (
                f"[{site_off:#x}] {label}  "
                f"(cave @ 0x{cave_cursor:X}, {len(payload)} B)"
            )

            f.seek(site_off)
            cur_site = f.read(4)
            f.seek(cave_cursor)
            cur_cave = f.read(len(payload))

            already = cur_site == site_patch and cur_cave == payload
            virgin = cur_site == expected and cur_cave == b"\x00" * len(payload)

            if already:
                print(f"  SKIP  {tag} (already patched)")
                cave_cursor += len(payload)
                continue
            if not virgin:
                failures += 1
                detail = []
                if cur_site != expected and cur_site != site_patch:
                    detail.append(
                        f"site expected {expected.hex()} or "
                        f"{site_patch.hex()}, got {cur_site.hex()}"
                    )
                if cur_cave != b"\x00" * len(payload) and cur_cave != payload:
                    detail.append(
                        "cave was not zero-fill nor the matching payload "
                        f"(first 16 B: {cur_cave[:16].hex()})"
                    )
                print(f"  FAIL  {tag}\n        " + "\n        ".join(detail))
                cave_cursor += len(payload)
                continue

            if verify_only:
                print(f"  OK    {tag} (orig matches; would patch)")
            else:
                # Write the cave first, then redirect the site. If we
                # were interrupted between the two writes, the site
                # would still point at its original instruction.
                f.seek(cave_cursor)
                f.write(payload)
                f.seek(site_off)
                f.write(site_patch)
                print(f"  PATCH {tag}")
            cave_cursor += len(payload)

        return failures
