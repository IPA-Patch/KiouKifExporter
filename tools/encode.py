"""arm64 instruction encoders.

These functions encode a single arm64 instruction into 4 little-endian
bytes (a few helpers emit instruction pairs). They are intentionally
narrow: each encoder maps one ARMv8 mnemonic to one 32-bit insn so the
caller has byte-level control over what ends up in a code cave, a
prologue redirect, or any other in-place patch.

Design notes:
  - All position-dependent encoders (``b_imm``, ``bl_imm``, ``adrp``)
    require the caller to pass the instruction's source virtual address.
    This makes accidental delta-from-0 bugs impossible to introduce.
  - Register-number arguments are integers 0..31. Encoding "SP" vs "XZR"
    is handled by the choice of opcode: ``MOV Xd, SP`` is ``ADD Xd, SP,
    #0``, while ``MOV Xd, Xm`` is ``ORR Xd, XZR, Xm`` — pick the helper
    whose name matches the intent.
  - Range errors raise ``ValueError`` at build time so a bad cave fails
    loudly instead of producing a binary that crashes on first launch.

Golden values for every encoder live in ``tests/test_encode.py``,
cross-checked against ``llvm-mc -triple=arm64-apple-ios -show-encoding``.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Data-processing immediates
# ---------------------------------------------------------------------------


def mov_w0_imm_ret(imm: int) -> bytes:
    """Encode ``MOV W0, #imm`` (MOVZ, LSL #0) followed by ``RET``.

    8 bytes total. Handy for replacing a leaf-function body with a
    constant-returning stub.
    """
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    movz = 0x52800000 | (imm << 5) | 0  # Rd = W0
    ret = 0xD65F03C0
    return movz.to_bytes(4, "little") + ret.to_bytes(4, "little")


def movz_w_imm(rd: int, imm: int) -> bytes:
    """Encode ``MOVZ Wd, #imm, LSL #0`` (4 bytes)."""
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if not (0 <= imm <= 0xFFFF):
        raise ValueError(f"imm out of MOVZ 16-bit range: {imm}")
    insn = 0x52800000 | (imm << 5) | rd
    return insn.to_bytes(4, "little")


def add_x_imm(rd: int, rn: int, imm: int) -> bytes:
    """Encode ``ADD Xd, Xn, #imm`` (sf=1, 12-bit unsigned imm, no shift).

    Also the canonical encoding for ``MOV Xd, SP`` (use ``rn=31, imm=0``);
    arm64's register-to-register MOV alias does not reach the stack
    pointer because Rn=31 means XZR there.
    """
    if not (0 <= rd < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"ADD imm out of imm12 range: {imm}")
    insn = 0x91000000 | (imm << 10) | (rn << 5) | rd
    return insn.to_bytes(4, "little")


def cmp_w_imm(rn: int, imm: int) -> bytes:
    """Encode ``CMP Wn, #imm`` (alias for ``SUBS WZR, Wn, #imm``).

    4 bytes; ``imm`` in [0, 4095].
    """
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    if not (0 <= imm <= 0xFFF):
        raise ValueError(f"CMP imm out of imm12 range: {imm}")
    insn = 0x7100001F | (imm << 10) | (rn << 5)
    return insn.to_bytes(4, "little")


def mov_reg(rd: int, rm: int, sf: int = 1) -> bytes:
    """Encode ``MOV Xd, Xm`` (alias for ``ORR Xd, XZR, Xm``).

    ``sf=1`` for 64-bit (default), ``sf=0`` for 32-bit ``MOV Wd, Wm``.
    """
    if not (0 <= rd < 32 and 0 <= rm < 32):
        raise ValueError("register out of range")
    insn = (sf << 31) | 0x2A0003E0 | (rm << 16) | rd
    return insn.to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Conditional select
# ---------------------------------------------------------------------------


_COND_CODES = {
    "EQ": 0,
    "NE": 1,
    "CS": 2,
    "CC": 3,
    "MI": 4,
    "PL": 5,
    "VS": 6,
    "VC": 7,
    "HI": 8,
    "LS": 9,
    "GE": 10,
    "LT": 11,
    "GT": 12,
    "LE": 13,
    "AL": 14,
    "NV": 15,
}


def cset_w_cond(rd: int, cond: str) -> bytes:
    """Encode ``CSET Wd, <cond>`` (alias for ``CSINC Wd, WZR, WZR, !cond``).

    4 bytes. ``cond`` is one of the standard arm64 condition mnemonics
    (``EQ``, ``NE``, ``CS``, ``CC``, ``MI``, ``PL``, ``VS``, ``VC``,
    ``HI``, ``LS``, ``GE``, ``LT``, ``GT``, ``LE``). ``AL`` and ``NV``
    are accepted but produce a degenerate CSET (the assembler-level
    inversion makes them encode as if their opposite was requested).
    """
    if not (0 <= rd < 32):
        raise ValueError(f"Rd out of range: {rd}")
    if cond not in _COND_CODES:
        raise ValueError(f"unknown condition: {cond}")
    c = _COND_CODES[cond] ^ 1  # CSET inverts
    insn = 0x1A9F07E0 | (c << 12) | rd
    return insn.to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Loads / stores
# ---------------------------------------------------------------------------


def ldr_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode ``LDR Wt, [Xn, #off]`` (4 bytes).

    ``off`` is a byte offset and must be 4-byte aligned, in
    ``[0, 0xFFF * 4]``.
    """
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if off < 0 or off % 4 != 0 or off > 0xFFF * 4:
        raise ValueError(f"LDR W off out of imm12*4 range: {off}")
    imm12 = off // 4
    insn = 0xB9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def ldr_x_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode ``LDR Xt, [Xn, #off]`` (64-bit).

    ``off`` is a byte offset and must be 8-byte aligned, in
    ``[0, 0xFFF * 8]``.
    """
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off < 0 or off % 8 != 0 or off > 0xFFF * 8:
        raise ValueError(f"LDR X off out of imm12*8 range: {off}")
    imm12 = off // 8
    insn = 0xF9400000 | (imm12 << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


def strb_w_imm(rt: int, rn: int, off: int) -> bytes:
    """Encode ``STRB Wt, [Xn, #off]`` (4 bytes).

    ``off`` is a byte offset in ``[0, 4095]``.
    """
    if not (0 <= rt < 32 and 0 <= rn < 32):
        raise ValueError(f"register out of range: rt={rt} rn={rn}")
    if not (0 <= off <= 0xFFF):
        raise ValueError(f"STRB off out of imm12 range: {off}")
    insn = 0x39000000 | (off << 10) | (rn << 5) | rt
    return insn.to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Pair loads / stores (STP / LDP)
# ---------------------------------------------------------------------------


def stp_pre_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode ``STP Xt1, Xt2, [Xn, #off]!`` (pre-index, 64-bit pair).

    ``off`` in ``[-512, 504]``, 8-byte aligned. ``rn=31`` is SP.
    """
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9800000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def stp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode ``STP Xt1, Xt2, [Xn, #off]`` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"STP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9000000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_off_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode ``LDP Xt1, Xt2, [Xn, #off]`` (signed offset, no writeback)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA9400000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


def ldp_post_x(rt1: int, rt2: int, rn: int, off: int) -> bytes:
    """Encode ``LDP Xt1, Xt2, [Xn], #off`` (post-index)."""
    if not (0 <= rt1 < 32 and 0 <= rt2 < 32 and 0 <= rn < 32):
        raise ValueError("register out of range")
    if off % 8 != 0 or not (-512 <= off <= 504):
        raise ValueError(f"LDP off out of range: {off}")
    imm7 = (off // 8) & 0x7F
    insn = 0xA8C00000 | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt1
    return insn.to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Branches
# ---------------------------------------------------------------------------


def b_imm(src: int, dst: int) -> bytes:
    """Encode ``B <dst>`` placed at ``src`` (4 bytes).

    Both VAs must be 4-byte aligned and within ``+/-128 MiB`` of each
    other (the imm26 range).
    """
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"B requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"B out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x14000000 | imm26
    return insn.to_bytes(4, "little")


def bl_imm(src: int, dst: int) -> bytes:
    """Encode ``BL <dst>`` placed at ``src`` (4 bytes).

    Same range constraints as :func:`b_imm`; the only difference is the
    link-register write.
    """
    if src % 4 != 0 or dst % 4 != 0:
        raise ValueError(f"BL requires 4B alignment: src=0x{src:X} dst=0x{dst:X}")
    delta = (dst - src) // 4
    if not (-(1 << 25) <= delta < (1 << 25)):
        raise ValueError(f"BL out of range: src=0x{src:X} dst=0x{dst:X} delta={delta}")
    imm26 = delta & 0x3FFFFFF
    insn = 0x94000000 | imm26
    return insn.to_bytes(4, "little")


def br_x(rn: int) -> bytes:
    """Encode ``BR Xn`` (indirect jump). 4 bytes."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    insn = 0xD61F0000 | (rn << 5)
    return insn.to_bytes(4, "little")


def blr_x(rn: int) -> bytes:
    """Encode ``BLR Xn`` (indirect call). 4 bytes."""
    if not (0 <= rn < 32):
        raise ValueError(f"Rn out of range: {rn}")
    insn = 0xD63F0000 | (rn << 5)
    return insn.to_bytes(4, "little")


def ret_insn() -> bytes:
    """Encode ``RET`` (4 bytes)."""
    return (0xD65F03C0).to_bytes(4, "little")


# ---------------------------------------------------------------------------
# Page-relative addressing
# ---------------------------------------------------------------------------


def adrp(rd: int, src_va: int, dst_va: int) -> bytes:
    """Encode ``ADRP Xd, page_of(dst)``.

    ``src_va`` is the address this instruction lives at; ``dst_va`` is
    the target. Returns 4 bytes. The encoded immediate represents the
    page-difference, so the result is page-aligned regardless of
    ``dst_va``'s low 12 bits.
    """
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


def adrp_add_pair(src_va: int, rd: int, target_va: int) -> bytes:
    """Emit ``ADRP Xd, page; ADD Xd, Xd, #lo12`` (8 bytes total).

    Materializes ``target_va`` in ``Xd``. Use when you need the address
    itself (e.g. as an argument); use :func:`adrp_ldr_x_pair` when you
    need the 8-byte value stored there.
    """
    out = bytearray()
    out += adrp(rd, src_va, target_va)
    lo12 = target_va & 0xFFF
    out += add_x_imm(rd, rd, lo12)
    return bytes(out)


def adrp_ldr_x_pair(src_va: int, rd_tmp: int, ptr_va: int) -> bytes:
    """Emit ``ADRP Xd, page; LDR Xd, [Xd, #lo12]`` (8 bytes total).

    Loads the 8-byte value stored at ``ptr_va`` into ``Xd``. Used for
    classref / selref / GOT entries. ``ptr_va`` must be 8-byte aligned.
    """
    if ptr_va % 8 != 0:
        raise ValueError(f"ptr_va not 8-aligned: 0x{ptr_va:X}")
    out = bytearray()
    out += adrp(rd_tmp, src_va, ptr_va)
    lo12 = ptr_va & 0xFFF
    out += ldr_x_imm(rd_tmp, rd_tmp, lo12)
    return bytes(out)
