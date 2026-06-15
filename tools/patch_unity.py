#!/usr/bin/env python3
"""
Static binary patcher for UnityFramework — Phase 1.5 of KiouKifExporter.

Produces a patched UnityFramework Mach-O suitable for the Sideloaded /
TrollStored iOS 18 install path, where iOS 18 Code Signing Monitor SIGKILLs
any runtime inline hook (Dobby / Substrate / frida-gum) the moment it tries
to write into __TEXT.

How the patch chain works (high-level — see
docs/plans/kiou_kif_exporter_binpatch.md for the full design):

  1. Add an LC_LOAD_DYLIB pointing at
     @executable_path/Frameworks/KiouKifExporter.dylib, so dyld auto-loads
     the export hook on app launch.
  2. Reserve an 8-byte slot in __bss (the SLOT) that the dylib constructor
     fills with its hook function pointer. Writing to __DATA does not
     trigger CSM.
  3. For every IMatchMode.OnMatchEndAsync entry (5 modes), replace the
     prologue's first 4 bytes with `B <cave>`.
  4. The cave preserves caller registers, calls the hook through the SLOT,
     restores registers, executes the displaced prologue instruction, and
     branches to <orig_OnMatchEndAsync + 4>.

This file currently ships the arm64 encoder library + the argparse main
loop and stops there. The actual PATCHES / CAVE_PATCHES lists are empty
placeholders. Wiring them up is Phase 1.5b – Phase 1.5e in the design
document.
"""
from __future__ import annotations

import argparse
import os
import sys


# ===========================================================================
# arm64 instruction encoders.
#
# Copied from packages/tweak/KiouEditor/tools/patch_unity.py — these have
# been hardened by the KiouEditor cave patches and are byte-accurate against
# real UnityFramework instructions. Keep them in sync; if KiouEditor's
# encoders change, port the change over.
# ===========================================================================

def mov_w0_imm_ret(imm: int) -> bytes:
    """Encode `MOV W0, #imm` (MOVZ, LSL #0) + `RET` (8 bytes, little-endian)."""
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    movz = 0x52800000 | (imm << 5) | 0  # Rd = W0
    ret = 0xD65F03C0
    return movz.to_bytes(4, "little") + ret.to_bytes(4, "little")


def movz_w_imm(rd: int, imm: int) -> bytes:
    """Encode `MOVZ Wd, #imm, LSL #0` (4 bytes, little-endian)."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    insn = 0x52800000 | (imm << 5) | rd
    return insn.to_bytes(4, "little")


def ldr_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `LDR Wt, [Xn, #off]` (4 bytes). `off` is a byte offset, must be 4B-aligned."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if off < 0 or off % 4 != 0 or off > 0xFFF * 4:
        raise ValueError(f"LDR W off out of imm12*4 range: {off}")
    imm12 = off // 4
    insn = 0xB9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def strb_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `STRB Wt, [Xn, #off]` (4 bytes). `off` is a byte offset in [0, 4095]."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if not (0 <= off <= 0xFFF):
        raise ValueError(f"STRB off out of imm12 range: {off}")
    insn = 0x39000000 | (off << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def cmp_w_imm(rn: int, imm: int) -> bytes:
    """Encode `CMP Wn, #imm` (alias for SUBS WZR, Wn, #imm). 4 bytes; imm in [0, 4095]."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"CMP imm out of imm12 range: {imm}")
    insn = 0x7100001F | (imm << 10) | (rn << 5)
    return insn.to_bytes(4, "little")


_COND_CODES = {
    "EQ": 0, "NE": 1, "CS": 2, "CC": 3, "MI": 4, "PL": 5, "VS": 6, "VC": 7,
    "HI": 8, "LS": 9, "GE": 10, "LT": 11, "GT": 12, "LE": 13, "AL": 14, "NV": 15,
}


def cset_w_cond(rd: int, cond: str) -> bytes:
    """Encode `CSET Wd, <cond>` (alias for CSINC Wd, WZR, WZR, !cond). 4 bytes."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if cond not in _COND_CODES:
        raise ValueError(f"unknown condition: {cond}")
    c = _COND_CODES[cond] ^ 1  # CSET inverts
    insn = 0x1A9F07E0 | (c << 12) | rd
    return insn.to_bytes(4, "little")


def b_imm(src: int, dst: int) -> bytes:
    """Encode `B <dst>` placed at `src` (4 bytes). Both must be 4B-aligned and within +/-128 MiB."""
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"B requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"B out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x14000000 | imm26
    return insn.to_bytes(4, "little")


def bl_imm(src: int, dst: int) -> bytes:
    """Encode `BL <dst>` placed at `src` (4 bytes). Like `b_imm` but link-register variant."""
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"BL requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"BL out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x94000000 | imm26
    return insn.to_bytes(4, "little")


def br_x(rn: int) -> bytes:
    """Encode `BR Xn` (indirect jump). 4 bytes."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    insn = 0xD61F0000 | (rn << 5)
    return insn.to_bytes(4, "little")


def blr_x(rn: int) -> bytes:
    """Encode `BLR Xn` (indirect call). 4 bytes."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    insn = 0xD63F0000 | (rn << 5)
    return insn.to_bytes(4, "little")


def ret_insn() -> bytes:
    """Encode `RET` (4 bytes)."""
    return (0xD65F03C0).to_bytes(4, "little")


def stp_pre_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `STP Xt1, Xt2, [Xn, #off]!` (pre-index, 64-bit pair). off in [-512, 504], 8B aligned."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9800000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def stp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `STP Xt1, Xt2, [Xn, #off]` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9000000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `LDP Xt1, Xt2, [Xn, #off]` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9400000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_post_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode `LDP Xt1, Xt2, [Xn], #off` (post-index)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA8C00000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def adrp(rd: int, src_va: int, dst_va: int) -> bytes:
    """Encode `ADRP Xd, page_of(dst)`. src_va is the address this insn lives at."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    src_page = src_va & ~0xFFF
    dst_page = dst_va & ~0xFFF
    delta_pages = (dst_page - src_page) >> 12
    if not (-(1 << 20) <= delta_pages < (1 << 20)):
        raise ValueError(f"ADRP out of range: delta_pages={delta_pages}")
    imm21 = delta_pages & 0x1FFFFF
    immlo = imm21 & 3
    immhi = (imm21 >> 2) & 0x7FFFF
    insn = 0x90000000 | (immlo << 29) | (immhi << 5) | rd
    return insn.to_bytes(4, "little")


def add_x_imm(rd: int, rn: int, imm: int) -> bytes:
    """Encode `ADD Xd, Xn, #imm` (sf=1, 12-bit unsigned imm, no shift)."""
    if not (0 <= rd < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"ADD imm out of imm12 range: {imm}")
    insn = 0x91000000 | (imm << 10) | (rn << 5) | rd
    return insn.to_bytes(4, "little")


def ldr_x_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode `LDR Xt, [Xn, #off]` (64-bit, byte-offset must be 8B aligned)."""
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off < 0 or off % 8 != 0 or off > 0xFFF * 8:
        raise ValueError(f"LDR X off out of imm12*8 range: {off}")
    imm12 = off // 8
    insn = 0xF9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def mov_reg(rd: int, rm: int, sf: int = 1) -> bytes:
    """Encode `MOV Xd, Xm` (alias for ORR Xd, XZR, Xm). sf=1 for 64-bit, sf=0 for 32-bit."""
    if not (0 <= rd < 32 and 0 <= rm < 32):
        raise ValueError("register out of range")
    insn = (sf << 31) | 0x2A0003E0 | (rm << 16) | rd  # ORR Wd, WZR, Wm
    return insn.to_bytes(4, "little")


def adrp_add_pair(src_va: int, rd: int, target_va: int) -> bytes:
    """Emit `ADRP Xd, page; ADD Xd, Xd, #lo12` to materialize the address of `target_va` in Xd.
    Two instructions, 8 bytes total."""
    out = bytearray()
    out += adrp(rd, src_va, target_va)
    lo12 = target_va & 0xFFF
    out += add_x_imm(rd, rd, lo12)
    return bytes(out)


def adrp_ldr_x_pair(src_va: int, rd_tmp: int, ptr_va: int) -> bytes:
    """Emit `ADRP Xd, page; LDR Xd, [Xd, #lo12]` to load the 8-byte value stored at ptr_va.
    Used for classref / selref / GOT entries. ptr_va must be 8-byte aligned."""
    if ptr_va % 8 != 0:
        raise ValueError(f"ptr_va not 8-aligned: 0x{ptr_va:X}")
    out = bytearray()
    out += adrp(rd_tmp, src_va, ptr_va)
    lo12 = ptr_va & 0xFFF
    out += ldr_x_imm(rd_tmp, rd_tmp, lo12)
    return bytes(out)


# ===========================================================================
# Mach-O modifications (Phase 1.5d).
#
# - add_lc_load_dylib(target, dylib_path)
#     Inserts `LC_LOAD_DYLIB @executable_path/Frameworks/KiouKifExporter.dylib`
#     at the tail of the load command region. Requires the load_commands
#     padding to be large enough to fit the new entry — currently this is
#     a stub that just emits a warning if it would overflow.
# - reserve_hook_slot(target)
#     Picks an 8-byte aligned, zero-filled offset inside __DATA,__bss (or
#     __DATA,__common) where the dylib constructor can publish its hook
#     function pointer. Returns the chosen RVA so cave payloads can ADRP
#     into it.
#
# Implementation deferred to Phase 1.5d. Below are the placeholder signatures
# only — wiring them up is the next task.
# ===========================================================================

def add_lc_load_dylib(target_path: str, dylib_path: str) -> None:
    """Add a new LC_LOAD_DYLIB load command pointing at `dylib_path`.

    NOT IMPLEMENTED. The plan is to use `lief` for this — see
    docs/plans/kiou_kif_exporter_binpatch.md sec 4.1.
    """
    raise NotImplementedError(
        "add_lc_load_dylib: implementation pending (Phase 1.5d). "
        "See docs/plans/kiou_kif_exporter_binpatch.md."
    )


def reserve_hook_slot(target_path: str) -> int:
    """Find or carve an 8-byte slot in __DATA/__bss/__common for the dylib
    constructor to drop a function pointer into. Returns the slot's RVA.

    NOT IMPLEMENTED. See docs/plans/kiou_kif_exporter_binpatch.md sec 4.2.
    """
    raise NotImplementedError(
        "reserve_hook_slot: implementation pending (Phase 1.5d). "
        "See docs/plans/kiou_kif_exporter_binpatch.md."
    )


# ===========================================================================
# Code cave region (Phase 1.5e).
#
# UnityFramework's `__TEXT,__oslogstring` ends with a multi-KB zero-fill
# inside the same r-x mapping as every other instruction. We carve cave
# payloads out of that range. The exact offsets need to be re-verified
# against the current KIOU 1.0.1 build 11 UnityFramework (KiouEditor's
# numbers may differ because KiouEditor itself reserved part of the cave
# already in its sibling install — DO NOT collide).
#
# CODE_CAVE_START_TBD and CODE_CAVE_END_TBD are placeholders; pin them in
# Phase 1.5e by running an oslogstring tail scan.
# ===========================================================================

CODE_CAVE_START_TBD = 0  # set in Phase 1.5e
CODE_CAVE_END_TBD   = 0  # set in Phase 1.5e


# ===========================================================================
# PATCHES (inline single-instruction replacements) — currently EMPTY.
#
# Each entry: (file_offset, expected_orig_bytes, replacement_bytes, label).
# Phase 1 (KIF auto-export) does not need any inline patches — the only
# behaviour change is hook installation, which is handled by CAVE_PATCHES.
# This list stays empty unless a future feature needs a leaf-function
# constant override.
# ===========================================================================

PATCHES: list = []


# ===========================================================================
# CAVE_PATCHES — each entry redirects 1 site instruction to a cave payload.
# Currently EMPTY; populated in Phase 1.5e once the cave region and slot
# RVAs are pinned. Each entry will look like:
#
#   (
#       0x59E5958,  # AIMatchMode.OnMatchEndAsync prologue site
#       bytes.fromhex("fd7bbda9"),  # expected: STP X29,X30,[SP,#-0x30]!
#       _build_match_end_cave_payload("AIMatchMode", 0x59E5958),
#       "AIMatchMode.OnMatchEndAsync: route to KIF cave",
#   ),
#
# `_build_match_end_cave_payload(tag, orig_va)` is the cave-content builder
# defined alongside the encoder helpers, parametrized over (cave_va) by
# the cave allocator in main(). See docs/plans/kiou_kif_exporter_binpatch.md
# sec 4.3 for the cave shape.
# ===========================================================================

CAVE_PATCHES: list = []


# ===========================================================================
# main() driver.
#
# Mirrors KiouEditor's patch_unity.py main(): walks PATCHES (apply inline),
# then walks CAVE_PATCHES (allocate sequentially in the cave, write the
# cave payload, redirect the site). For now both lists are empty so this
# script no-ops successfully, which is intentional — the skeleton ships
# first, the patches follow.
# ===========================================================================

def main() -> int:
    parser = argparse.ArgumentParser(
        description="KiouKifExporter Phase 1.5 — static UnityFramework patcher",
    )
    parser.add_argument(
        "target",
        help="Path to UnityFramework Mach-O",
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Report match/mismatch without writing.",
    )
    parser.add_argument(
        "--dylib-name",
        default="@executable_path/Frameworks/KiouKifExporter.dylib",
        help="LC_LOAD_DYLIB target path (default: %(default)s).",
    )
    parser.add_argument(
        "--no-add-dylib",
        action="store_true",
        help="Skip the LC_LOAD_DYLIB insertion step (debug aid).",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.target):
        print(f"error: not a file: {args.target}", file=sys.stderr)
        return 2

    if not PATCHES and not CAVE_PATCHES:
        print(
            "patch_unity.py: PATCHES and CAVE_PATCHES are both empty.\n"
            "This is the Phase 1.5a skeleton — no behaviour change applied.\n"
            "See docs/plans/kiou_kif_exporter_binpatch.md for the rollout plan.",
            file=sys.stderr,
        )
        return 0

    # ----- inline PATCHES (none defined yet, kept for symmetry with
    #       KiouEditor's tooling) -----
    mode = "rb" if args.verify_only else "r+b"
    with open(args.target, mode) as f:
        failures = 0
        for off, expected, new, label in PATCHES:
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
            if args.verify_only:
                print(f"  OK    {tag} (orig matches; would patch)")
            else:
                f.seek(off)
                f.write(new)
                print(f"  PATCH {tag}")

        # ----- cave-based patches (placeholder loop, runs zero iterations
        #       until CAVE_PATCHES gets populated in Phase 1.5e) -----
        if CAVE_PATCHES:
            print(
                "  WARN  cave allocator not implemented in skeleton; "
                "ignoring CAVE_PATCHES",
                file=sys.stderr,
            )

        if failures:
            print(f"\n{failures} mismatch(es) — aborting.", file=sys.stderr)
            return 1

    # ----- LC_LOAD_DYLIB insertion (Phase 1.5d) -----
    if not args.no_add_dylib:
        try:
            add_lc_load_dylib(args.target, args.dylib_name)
        except NotImplementedError as e:
            print(f"  WARN  {e}", file=sys.stderr)

    print(
        "\nDone (skeleton — no functional patches applied)."
        if args.verify_only
        else "\nDone (skeleton — no functional patches applied).",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
