"""Recipe for KiouKifExporter — Phase 1.5 binpatch.

Patches UnityFramework so that every ``IMatchMode.OnMatchEndAsync``
entry calls into ``KiouKifExporter.dylib`` for KIF auto-export, and the
dylib is loaded automatically via ``LC_LOAD_DYLIB``.

How the patch chain works (see ``docs/plans/kiou_kif_exporter_binpatch.md``
for the full design):

  1. Add an ``LC_LOAD_DYLIB`` pointing at
     ``@executable_path/Frameworks/KiouKifExporter.dylib`` so dyld
     auto-loads the export hook on app launch.
  2. Reserve an 8-byte slot in ``__bss`` (the SLOT) that the dylib
     constructor fills with its hook function pointer. Writing to
     ``__DATA`` does not trigger CSM on iOS 18.
  3. For every ``IMatchMode.OnMatchEndAsync`` entry (5 modes), replace
     the prologue's first 4 bytes with ``B <cave>``.
  4. The cave preserves caller registers, calls the hook through the
     SLOT, restores registers, executes the displaced prologue
     instruction, and branches to ``orig + 4``.

This recipe is consumed by ``tools.patch_macho`` together with the
generic primitives in ``tools.encode``, ``tools.machoops``, and
``tools.caves``.
"""

from __future__ import annotations

from tools.encode import (
    add_x_imm,
    adrp,
    b_imm,
    blr_x,
    ldp_off_x,
    ldp_post_x,
    ldr_x_imm,
    movz_w_imm,
    stp_off_x,
    stp_pre_x,
)


# ---------------------------------------------------------------------------
# Target identification
# ---------------------------------------------------------------------------

TARGET_BASENAME = "UnityFramework"
DYLIB_PATH = "@executable_path/Frameworks/KiouKifExporter.dylib"


# ---------------------------------------------------------------------------
# Code-cave region.
#
# UnityFramework's ``__TEXT,__oslogstring`` ends with a multi-KB zero-fill
# inside the same r-x mapping as every other instruction. Cave payloads
# are carved out of that range. Pinned against the freshly extracted
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
# Per-cave size is 84 bytes; five caves consume 420 bytes total, well
# below the 16348-byte budget.
# ---------------------------------------------------------------------------

CAVE_REGION = (0x8268024, 0x826C000)  # (start, end exclusive)


# ---------------------------------------------------------------------------
# Hook slot.
#
# The dylib constructor publishes its hook function pointer into this
# 8-byte slot inside __DATA,__bss. ``reserve_hook_slot()`` derives it
# from the live binary; we hard-code it here so the cave's ADRP+LDR
# encoding is deterministic and the post-patch idempotency check works
# without re-parsing the Mach-O. If a future UnityFramework changes the
# __bss layout, re-run reserve_hook_slot() and update this constant.
# ---------------------------------------------------------------------------

HOOK_SLOT_RVA = 0x8F90CD0


# ---------------------------------------------------------------------------
# Cave payload builder.
#
# Cave shape (21 insns = 84 bytes), see
# docs/plans/kiou_kif_exporter_binpatch.md sec 4.3:
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
#     MOVZ W2, #mode_index        ; pass the mode index as the third arg
#     BLR  X16                    ; call hook(self, ct, mode_index) via SLOT
#     LDP  X6,  X7,  [SP, #0x60]
#     LDP  X4,  X5,  [SP, #0x50]
#     LDP  X2,  X3,  [SP, #0x40]
#     LDP  X0,  X1,  [SP, #0x30]
#     LDP  X21, X22, [SP, #0x20]
#     LDP  X19, X20, [SP, #0x10]
#     LDP  X29, X30, [SP], #0x90
#     <displaced prologue insn>   ; verbatim, must be PC-independent
#     B    <orig + 4>
# ---------------------------------------------------------------------------

CAVE_PAYLOAD_SIZE = 84  # 21 instructions


def _build_match_end_cave_payload(
    orig_va: int, slot_va: int, displaced_insn: bytes, mode_index: int
):
    """Return a ``build_payload(cave_va) -> bytes`` closure for one mode.

    Parameters
    ----------
    orig_va : int
        VA of the OnMatchEndAsync prologue instruction that will be
        replaced with ``B <cave_va>``. The cave trampolines back to
        ``orig_va + 4`` after executing the displaced prologue insn
        locally.
    slot_va : int
        VA of the 8-byte __bss slot the dylib constructor publishes the
        hook function pointer into.
    displaced_insn : bytes
        The 4 prologue bytes about to be overwritten. Must be
        PC-independent (STP pre-index, SUB SP, etc.).
    mode_index : int
        Identifier for the IMatchMode concrete subclass this cave
        serves. Loaded into X2 (third arg) before BLR so the dylib hook
        can pick the correct ``_gameAdapter`` field offset without
        guessing.
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
        # MOV X29, SP. arm64 has no register-to-register MOV that touches
        # SP; `MOV Xd, Xm` (ORR Xd, XZR, Xm) treats Rn=31 as XZR, not SP.
        # The canonical encoding for "X29 = SP" is `ADD X29, SP, #0`,
        # which the disassembler renders as `MOV X29, SP`.
        emit(add_x_imm(29, 31, 0))

        # --- materialize SLOT address; load the published hook pointer ---
        emit(adrp(16, cur, slot_va))
        emit(ldr_x_imm(16, 16, slot_va & 0xFFF))

        # --- pass the mode index to the hook via X2 ---
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


# ---------------------------------------------------------------------------
# PATCHES — inline single-instruction replacements.
#
# Phase 1 (KIF auto-export) does not need any inline patches — the only
# behaviour change is hook installation, which is handled by CAVE_PATCHES.
# ---------------------------------------------------------------------------

PATCHES: list = []


# ---------------------------------------------------------------------------
# CAVE_PATCHES — each entry redirects a 4-byte site instruction to a cave.
#
# The five IMatchMode.OnMatchEndAsync sites. Each prologue is a single
# PC-independent arm64 instruction (STP pre-index or SUB SP), so we can
# safely relocate it verbatim into the cave. Verified bytes-on-disk
# against the clean Kiou-1.0.1 build 11 UnityFramework on 2026-06-14.
#
# The mode_index column MUST stay in sync with the KIOU_BINPATCH_MODE_*
# enum in Sources/KiouKifExporter/Internal.h. The cave loads it into X2
# (third arg) so the dylib hook can look up the right _gameAdapter
# offset without guessing.
# ---------------------------------------------------------------------------

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
            site, HOOK_SLOT_RVA, bytes.fromhex(prologue_hex), mode_index
        ),
        f"{label}: route to KIF cave",
    )
    for site, prologue_hex, mode_index, label in _MATCH_END_SITES
]


# ---------------------------------------------------------------------------
# Info.plist additions for sandbox-Documents visibility through Files.app.
#
# The patched IPA pipeline reads this dict and writes each key into the
# bundle's Info.plist. Setting both flags is what makes "On My iPhone ->
# <app>" expose the sandbox so the operator can read KIF files and the
# diagnostic log from Files.app.
# ---------------------------------------------------------------------------

PLIST_KEYS: dict = {
    "UIFileSharingEnabled": True,
    "LSSupportsOpeningDocumentsInPlace": True,
}
