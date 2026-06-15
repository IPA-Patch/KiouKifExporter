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
# Encoders moved to tools/encode.py so they can be unit-tested in
# isolation against llvm-mc golden values, and reused by sibling
# patchers without copy-paste drift. Future migration target:
# https://github.com/IPA-Patch/Shared (the shared/ submodule).
# ===========================================================================

from encode import (
    add_x_imm,
    adrp,
    adrp_ldr_x_pair,
    b_imm,
    blr_x,
    ldp_off_x,
    ldp_post_x,
    ldr_x_imm,
    movz_w_imm,
    stp_off_x,
    stp_pre_x,
)


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


def _encode_macho_version(major: int, minor: int, patch: int) -> int:
    """Encode a (major, minor, patch) triple into the Mach-O 32-bit dylib
    version format: ``xxxx.yy.zz`` packed as ``(major << 16) | (minor << 8) | patch``.
    """
    if not (0 <= major <= 0xFFFF and 0 <= minor <= 0xFF and 0 <= patch <= 0xFF):
        raise ValueError(f"version triple out of range: {major}.{minor}.{patch}")
    return (major << 16) | (minor << 8) | patch


def _iter_thin_binaries(parsed):
    """Yield each thin ``MachO.Binary`` from a ``parse()`` result, regardless
    of whether the input was a fat (Universal) Mach-O or a single-arch one.
    """
    import lief  # local import keeps the module importable when lief is absent

    if isinstance(parsed, lief.MachO.FatBinary):
        for i in range(parsed.size):
            yield parsed.at(i)
    else:
        yield parsed


def add_lc_load_dylib(target_path: str, dylib_path: str) -> None:
    """Add a new ``LC_LOAD_DYLIB`` load command pointing at ``dylib_path``
    to ``target_path`` (in place).

    Idempotent: if a ``LC_LOAD_DYLIB`` or ``LC_LOAD_WEAK_DYLIB`` whose name
    already equals ``dylib_path`` is present, this prints ``SKIP`` and
    returns without modifying the binary.

    Handles both thin Mach-O and Fat (Universal) binaries — every slice
    receives the new load command.

    Versions are pinned to 1.0.0 / 1.0.0 (current / compatibility) and the
    timestamp is 0, matching the convention used by Theos / TrollStore
    sideload pipelines.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")

    mutated = False
    for binary in _iter_thin_binaries(parsed):
        cpu = binary.header.cpu_type
        already_present = False
        for lib in binary.libraries:
            if lib.name == dylib_path:
                already_present = True
                break
        if already_present:
            print(f"  SKIP  LC_LOAD_DYLIB {dylib_path} (cpu={cpu}, already present)")
            continue

        version = _encode_macho_version(1, 0, 0)
        cmd = lief.MachO.DylibCommand.load_dylib(
            dylib_path,
            0,  # timestamp
            version,  # current_version
            version,  # compatibility_version
        )
        # ``Binary.add`` appends the command to the load-command region.
        # lief grows the __TEXT segment / load-command padding automatically
        # when it serialises back via ``write``.
        binary.add(cmd)
        mutated = True
        print(f"  ADDED LC_LOAD_DYLIB {dylib_path} (cpu={cpu})")

    if mutated:
        # ``FatBinary.write`` / ``Binary.write`` both accept a path and
        # serialise the full file back. We always write because at least
        # one slice changed.
        parsed.write(target_path)


def reserve_hook_slot(target_path: str) -> int | None:
    """Pick an 8-byte aligned slot inside the ``__DATA,__bss`` zero-fill
    region for the dylib constructor to publish a function pointer into.

    Returns the slot's **virtual address relative to the Mach-O image base**
    (``__TEXT`` segment base). For UnityFramework that base is 0, so the
    returned integer is also the absolute VA inside the Mach-O slice; the
    dylib resolves it at runtime as ``slide + return_value``.

    Returns ``None`` if no suitable ``__bss`` section can be located.

    Why this is safe:
      - ``__bss`` is a ZEROFILL section: it occupies no bytes in the file
        and dyld zeroes the whole region on load.
      - We pick the **last** 8 bytes of the section (``va + size - 8``)
        rather than the first, because compilers lay out static globals
        starting from the section base. Picking the tail minimises the
        chance of colliding with a real global that happens to be at
        offset 0 of ``__bss``.
      - The chosen address is 8-byte aligned by construction (``__bss``
        sections are page-aligned, and we offset by ``size - 8`` which is
        8-aligned as long as the section size is 8-aligned — we assert).

    For UnityFramework KIOU 1.0.1 build 11 this currently returns the VA
    near the very top of ``__DATA,__bss`` (~0x8f90cd0 region). Callers
    should re-run this whenever the target binary changes.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")

    # We pick the first slice's __bss; fat binaries with multiple slices
    # would need a per-slice slot, but UnityFramework ships arm64-only.
    binary = next(_iter_thin_binaries(parsed))

    bss = None
    for seg in binary.segments:
        if not seg.name.startswith("__DATA"):
            continue
        for sec in seg.sections:
            # Match either __bss or __common (both ZEROFILL flavour).
            if sec.name in ("__bss", "__common"):
                bss = sec
                break
        if bss is not None:
            break

    if bss is None:
        print(
            "  WARN  reserve_hook_slot: no __DATA,__bss or __DATA,__common section found"
        )
        return None

    if bss.size < 8:
        print(f"  WARN  reserve_hook_slot: {bss.name} too small ({bss.size} bytes)")
        return None

    if bss.size % 8 != 0:
        # Round down to the nearest 8B boundary for safety.
        usable = bss.size & ~0x7
    else:
        usable = bss.size

    slot_va = bss.virtual_address + usable - 8
    if slot_va % 8 != 0:
        print(f"  WARN  reserve_hook_slot: computed slot not 8B-aligned: 0x{slot_va:X}")
        return None

    print(
        f"  SLOT  __DATA,{bss.name} tail @ 0x{slot_va:X} "
        f"(section base 0x{bss.virtual_address:X}, size 0x{bss.size:X})"
    )
    return slot_va


# ===========================================================================
# Code cave region (Phase 1.5e).
#
# UnityFramework's `__TEXT,__oslogstring` ends with a multi-KB zero-fill
# inside the same r-x mapping as every other instruction. We carve cave
# payloads out of that range. Pinned against the freshly extracted
# Kiou-1.0.1 build 11 UnityFramework:
#
#   - The last non-zero byte of __oslogstring sits at file offset 0x8268023.
#   - __TEXT ends (exclusive) at file offset 0x826C000.
#   - The whole 0x8268024 .. 0x826C000 range is zero-filled and read-execute
#     mapped, so it is safe to populate with arm64 instructions and branch
#     into without any segment edits.
#
# KiouEditor uses the same range; if both tools are applied to the same
# binary the leader allocates KiouEditor first and KiouKifExporter second.
# Per-cave size is 80 bytes; five caves consume 400 bytes total, well
# below the 16348-byte budget.
# ===========================================================================

CODE_CAVE_START = 0x8268024
CODE_CAVE_END = 0x826C000  # exclusive
CODE_CAVE_SIZE = CODE_CAVE_END - CODE_CAVE_START  # 0x3FDC = 16348 bytes

# The dylib constructor publishes its hook function pointer into this
# 8-byte slot inside __DATA,__bss. `reserve_hook_slot()` derives it from
# the live binary; we hard-code it here so the cave's ADRP+LDR encoding
# is deterministic and the post-patch idempotency check works without
# re-parsing the Mach-O. If a future UnityFramework changes the __bss
# layout, re-run reserve_hook_slot() and update this constant.
KIOU_HOOK_SLOT_RVA = 0x8F90CD0


def _assert_slot_in_bss(target_path: str, slot_va: int) -> None:
    """Abort with a clear error if ``slot_va`` does not land inside a
    ``__DATA,__bss`` or ``__DATA,__common`` zero-fill section.

    The caves emit `LDR X16, [page_of(slot) + lo12]`. If the slot accidentally
    fell into ``__DATA_CONST`` or any read-only segment, the dylib
    constructor's write to publish the hook pointer would fault at runtime
    on iOS 18 (and on every prior iOS, the page would simply be RO). This
    check makes that misconfiguration a build-time error rather than a
    crash on first launch.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")
    binary = next(_iter_thin_binaries(parsed))
    for seg in binary.segments:
        if not seg.name.startswith("__DATA"):
            continue
        for sec in seg.sections:
            s_va = sec.virtual_address
            s_end = s_va + sec.size
            if s_va <= slot_va < s_end:
                if sec.name not in ("__bss", "__common"):
                    raise RuntimeError(
                        f"KIOU_HOOK_SLOT_RVA 0x{slot_va:X} lies in "
                        f"{seg.name},{sec.name} — must be __bss or __common. "
                        "Aborting before the cave is written, because the "
                        "dylib constructor would fault when publishing the "
                        "hook pointer."
                    )
                return
    raise RuntimeError(
        f"KIOU_HOOK_SLOT_RVA 0x{slot_va:X} did not land in any __DATA section. "
        "Re-run reserve_hook_slot() against the current UnityFramework and "
        "update the constant."
    )


# ===========================================================================
# Cave payload builder.
#
# Cave shape (20 insns = 80 bytes), see docs/plans/kiou_kif_exporter_binpatch.md
# sec 4.3 for the reasoning:
#
#     STP X29, X30, [SP, #-0x90]!
#     STP X19, X20, [SP, #0x10]
#     STP X21, X22, [SP, #0x20]
#     STP X0,  X1,  [SP, #0x30]   ; save args (self, ct)
#     STP X2,  X3,  [SP, #0x40]
#     STP X4,  X5,  [SP, #0x50]
#     STP X6,  X7,  [SP, #0x60]
#     MOV X29, SP
#     ADRP X16, page(SLOT)
#     LDR  X16, [X16, #lo12(SLOT)]
#     BLR  X16                    ; call hook(self, ct) via SLOT
#     LDP  X6,  X7,  [SP, #0x60]
#     LDP  X4,  X5,  [SP, #0x50]
#     LDP  X2,  X3,  [SP, #0x40]
#     LDP  X0,  X1,  [SP, #0x30]
#     LDP  X21, X22, [SP, #0x20]
#     LDP  X19, X20, [SP, #0x10]
#     LDP  X29, X30, [SP], #0x90
#     <displaced prologue insn>   ; verbatim, must be PC-independent
#     B    <orig + 4>
# ===========================================================================

CAVE_PAYLOAD_SIZE = 84  # 21 instructions (was 80; +4 for MOVZ X2, #mode_index)


def _build_match_end_cave_payload(
    orig_va: int, slot_va: int, displaced_insn: bytes, mode_index: int
) -> "callable":
    """Return a ``build_payload(cave_va) -> bytes`` closure for one mode.

    Parameters
    ----------
    orig_va : int
        VA of the OnMatchEndAsync prologue instruction that will be replaced
        with ``B <cave_va>``. We trampoline back to ``orig_va + 4`` after
        executing the displaced prologue insn locally.
    slot_va : int
        VA of the 8-byte __bss slot the dylib constructor publishes the
        hook function pointer into.
    displaced_insn : bytes
        The 4 prologue bytes we are about to overwrite. Must be PC-independent
        (STP pre-index, SUB SP, etc.) — caller has already verified this.
    mode_index : int
        Identifier for the IMatchMode concrete subclass this cave serves
        (0=AIMatchMode, 1=CPUStreamMode, 2=LocalPvPMode, 3=OnlinePvPMode,
        4=RecordReplayMode). Loaded into X2 as the third argument before
        BLR so the dylib hook can pick the correct ``_gameAdapter`` field
        offset without guessing.
    """
    if len(displaced_insn) != 4:
        raise ValueError(
            f"displaced_insn must be exactly 4 bytes; got {len(displaced_insn)}"
        )
    if not (0 <= mode_index <= 0xFFFF):
        raise ValueError(f"mode_index out of MOVZ 16-bit range: {mode_index}")

    def build(cave_va: int) -> bytes:
        out = bytearray()
        cur = cave_va

        def emit(insn: bytes) -> None:
            nonlocal cur
            out.extend(insn)
            cur += 4

        # --- prologue: save LR, callee-saved scratch, and arg registers ---
        emit(stp_pre_x(29, 30, 31, -0x90))
        emit(stp_off_x(19, 20, 31, 0x10))
        emit(stp_off_x(21, 22, 31, 0x20))
        emit(stp_off_x(0, 1, 31, 0x30))
        emit(stp_off_x(2, 3, 31, 0x40))
        emit(stp_off_x(4, 5, 31, 0x50))
        emit(stp_off_x(6, 7, 31, 0x60))
        # MOV X29, SP. arm64 has no register-to-register MOV that touches SP;
        # `MOV Xd, Xm` (ORR Xd, XZR, Xm) treats Rn=31 as XZR, not SP. The
        # canonical encoding for "X29 = SP" is `ADD X29, SP, #0`, which the
        # disassembler renders as `MOV X29, SP`.
        emit(add_x_imm(29, 31, 0))

        # --- materialize SLOT address; load the published hook pointer ---
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))

        # --- pass the mode index to the hook via X2 ---
        # The hook signature is kif_binpatch_OnMatchEndAsync(self, ct,
        # uint32_t mode_index). MOVZ Wn, #imm fits any value 0..0xFFFF
        # and zero-extends, so this is a safe one-instruction way to pin
        # the third arg to a concrete small integer.
        emit(movz_w_imm(2, mode_index))

        emit(blr_x(16))

        # --- restore ---
        emit(ldp_off_x(6, 7, 31, 0x60))
        emit(ldp_off_x(4, 5, 31, 0x50))
        emit(ldp_off_x(2, 3, 31, 0x40))
        emit(ldp_off_x(0, 1, 31, 0x30))
        emit(ldp_off_x(21, 22, 31, 0x20))
        emit(ldp_off_x(19, 20, 31, 0x10))
        emit(ldp_post_x(29, 30, 31, 0x90))

        # --- execute the displaced prologue insn verbatim ---
        emit(displaced_insn)

        # --- branch to (orig + 4) ---
        emit(b_imm(cur, orig_va + 4))

        if len(out) != CAVE_PAYLOAD_SIZE:
            raise AssertionError(
                f"cave payload wrong size: got {len(out)}, expected {CAVE_PAYLOAD_SIZE}"
            )
        return bytes(out)

    return build


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

# The five IMatchMode.OnMatchEndAsync sites. Each prologue is a single
# PC-independent arm64 instruction (STP pre-index or SUB SP), so we can
# safely relocate it verbatim into the cave. Verified bytes-on-disk against
# the clean Kiou-1.0.1 build 11 UnityFramework on 2026-06-14.
#
# The mode_index column MUST stay in sync with the KIOU_BINPATCH_MODE_*
# enum in Sources/KiouKifExporter/Internal.h. The cave loads it into X2
# (third arg) so the dylib hook can look up the right _gameAdapter
# offset without guessing.
_MATCH_END_SITES: list[tuple[int, str, int, str]] = [
    (0x59E5958, "f657bda9", 0, "AIMatchMode.OnMatchEndAsync"),
    (0x59EC818, "ff8301d1", 1, "CPUStreamMode.OnMatchEndAsync"),
    (0x59FF8F8, "f44fbea9", 2, "LocalPvPMode.OnMatchEndAsync"),
    (0x5A0139C, "ff8301d1", 3, "OnlinePvPMode.OnMatchEndAsync"),
    (0x5A2B564, "f85fbca9", 4, "RecordReplayMode.OnMatchEndAsync"),
]


CAVE_PATCHES: list = [
    (
        site,
        bytes.fromhex(prologue_hex),
        _build_match_end_cave_payload(
            site, KIOU_HOOK_SLOT_RVA, bytes.fromhex(prologue_hex), mode_index
        ),
        f"{label}: route to KIF cave",
    )
    for site, prologue_hex, mode_index, label in _MATCH_END_SITES
]


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

    # ----- safety: confirm KIOU_HOOK_SLOT_RVA still lives in __bss -----
    # We do this first, before any write, so a stale constant fails loudly
    # instead of corrupting the binary.
    if CAVE_PATCHES:
        try:
            _assert_slot_in_bss(args.target, KIOU_HOOK_SLOT_RVA)
        except RuntimeError as e:
            print(f"  FAIL  {e}", file=sys.stderr)
            return 1

    # ----- inline PATCHES (none defined yet, kept for symmetry with
    #       KiouEditor's tooling) -----
    if PATCHES or CAVE_PATCHES:
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

            # ----- cave-based patches -----
            # Allocate caves sequentially from CODE_CAVE_START in
            # CAVE_PATCHES declaration order. Allocation is deterministic
            # so re-runs land cave bytes at the exact same addresses, and
            # the "already patched" SKIP path can match both the site and
            # the cave content byte-for-byte.
            cave_cursor = CODE_CAVE_START
            for site_off, expected, build_payload, label in CAVE_PATCHES:
                if len(expected) != 4:
                    raise AssertionError(
                        f"cave-patch site must be one 4B insn: {label}"
                    )

                payload = build_payload(cave_cursor)
                if len(payload) % 4 != 0:
                    raise AssertionError(
                        f"cave payload not 4B-aligned for {label}: len={len(payload)}"
                    )
                if cave_cursor + len(payload) > CODE_CAVE_END:
                    print(
                        f"  FAIL  cave overflow for {label}: "
                        f"need 0x{len(payload):X} B at 0x{cave_cursor:X}, "
                        f"only 0x{CODE_CAVE_END - cave_cursor:X} B remain",
                        file=sys.stderr,
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

                if args.verify_only:
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

            if failures:
                print(f"\n{failures} mismatch(es) — aborting.", file=sys.stderr)
                return 1

    # ----- LC_LOAD_DYLIB insertion (Phase 1.5d) -----
    if not args.no_add_dylib and not args.verify_only:
        try:
            add_lc_load_dylib(args.target, args.dylib_name)
        except NotImplementedError as e:
            print(f"  WARN  {e}", file=sys.stderr)

    # ----- hook slot probe (Phase 1.5d) -----
    # Sanity check: confirm the runtime-discovered slot still matches the
    # baked-in constant the caves were compiled against.
    try:
        slot_rva = reserve_hook_slot(args.target)
        if slot_rva is not None:
            print(f"  INFO  KIOU_HOOK_SLOT_RVA = 0x{slot_rva:X}")
            if slot_rva != KIOU_HOOK_SLOT_RVA:
                print(
                    f"  WARN  slot VA drift: reserve_hook_slot returned "
                    f"0x{slot_rva:X}, but caves were built against "
                    f"0x{KIOU_HOOK_SLOT_RVA:X}. Re-pin the constant and "
                    "re-patch the binary.",
                    file=sys.stderr,
                )
    except NotImplementedError as e:
        print(f"  WARN  {e}", file=sys.stderr)

    print("\nVerify pass complete." if args.verify_only else "\nAll patches applied.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
