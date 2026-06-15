"""Golden-value tests for ``tools.encode``.

Each expected byte string in this file was produced by:

    /path/to/theos/toolchain/linux/iphone/bin/llvm-mc \\
        -triple=arm64-apple-ios -show-encoding <<< "<mnemonic>"

and is reproduced here as a Python ``bytes`` literal. Adding a new
encoder? Generate its golden value from the same llvm-mc invocation and
paste it in below.

These tests intentionally exercise BOTH the happy path (correctly
encoded instruction) and the validation path (range / alignment errors
raise ``ValueError``). The validation path matters as much as the
happy path: an encoder that silently produces a wrong instruction on
out-of-range input would corrupt a code cave without a clear failure.
"""

from __future__ import annotations

import pytest

from tools.encode import (
    _COND_CODES,
    add_x_imm,
    adrp,
    adrp_add_pair,
    adrp_ldr_x_pair,
    b_imm,
    bl_imm,
    blr_x,
    br_x,
    cmp_w_imm,
    cset_w_cond,
    ldp_off_x,
    ldp_post_x,
    ldr_w_imm,
    ldr_x_imm,
    mov_reg,
    mov_w0_imm_ret,
    movz_w_imm,
    ret_insn,
    stp_off_x,
    stp_pre_x,
    strb_w_imm,
)

# ---------------------------------------------------------------------------
# Data-processing immediates
# ---------------------------------------------------------------------------


def test_mov_w0_imm_ret_zero() -> None:
    # mov w0, #0   ; [0x00,0x00,0x80,0x52]
    # ret          ; [0xc0,0x03,0x5f,0xd6]
    assert mov_w0_imm_ret(0) == bytes.fromhex("00008052c0035fd6")


def test_mov_w0_imm_ret_max() -> None:
    # mov w0, #0xffff ; [0xe0,0xff,0x9f,0x52]
    assert mov_w0_imm_ret(0xFFFF) == bytes.fromhex("e0ff9f52c0035fd6")


def test_mov_w0_imm_ret_out_of_range() -> None:
    with pytest.raises(ValueError):
        mov_w0_imm_ret(-1)
    with pytest.raises(ValueError):
        mov_w0_imm_ret(0x10000)


def test_movz_w_imm() -> None:
    # movz w0, #0x1234 ; [0x80,0x46,0x82,0x52]
    assert movz_w_imm(0, 0x1234) == bytes.fromhex("80468252")
    # movz w5, #0xabcd ; [0xa5,0x79,0x95,0x52]
    assert movz_w_imm(5, 0xABCD) == bytes.fromhex("a5799552")


def test_movz_w_imm_range() -> None:
    with pytest.raises(ValueError):
        movz_w_imm(-1, 0)
    with pytest.raises(ValueError):
        movz_w_imm(32, 0)
    with pytest.raises(ValueError):
        movz_w_imm(0, 0x10000)


def test_add_x_imm_mov_sp() -> None:
    # add x29, sp, #0 (= MOV X29, SP) ; [0xfd,0x03,0x00,0x91]
    assert add_x_imm(29, 31, 0) == bytes.fromhex("fd030091")


def test_add_x_imm_max_imm() -> None:
    # add x0, x1, #0xfff ; [0x20,0xfc,0x3f,0x91]
    assert add_x_imm(0, 1, 0xFFF) == bytes.fromhex("20fc3f91")


def test_add_x_imm_mid() -> None:
    # add x29, x29, #0x42 ; [0xbd,0x0b,0x01,0x91]
    assert add_x_imm(29, 29, 0x42) == bytes.fromhex("bd0b0191")


def test_add_x_imm_range() -> None:
    with pytest.raises(ValueError):
        add_x_imm(0, 1, -1)
    with pytest.raises(ValueError):
        add_x_imm(0, 1, 0x1000)
    with pytest.raises(ValueError):
        add_x_imm(32, 0, 0)


def test_cmp_w_imm() -> None:
    # cmp w0, #0 ; [0x1f,0x00,0x00,0x71]
    assert cmp_w_imm(0, 0) == bytes.fromhex("1f000071")
    # cmp w15, #0xfff ; [0xff,0xfd,0x3f,0x71]
    assert cmp_w_imm(15, 0xFFF) == bytes.fromhex("fffd3f71")


def test_cmp_w_imm_range() -> None:
    with pytest.raises(ValueError):
        cmp_w_imm(0, 0x1000)
    with pytest.raises(ValueError):
        cmp_w_imm(32, 0)


def test_mov_reg_x() -> None:
    # mov x0, x1 ; [0xe0,0x03,0x01,0xaa]
    assert mov_reg(0, 1) == bytes.fromhex("e00301aa")
    # mov x29, x30 ; [0xfd,0x03,0x1e,0xaa]
    assert mov_reg(29, 30) == bytes.fromhex("fd031eaa")


def test_mov_reg_w() -> None:
    # mov w0, w1 ; [0xe0,0x03,0x01,0x2a]
    assert mov_reg(0, 1, sf=0) == bytes.fromhex("e003012a")


# ---------------------------------------------------------------------------
# Conditional select
# ---------------------------------------------------------------------------


# Mapping of cond mnemonic to the expected ``CSET W0, <cond>`` encoding.
# Generated from llvm-mc -show-encoding for ``cset w0, <cond>``.
_CSET_W0_GOLDEN = {
    "EQ": "e0179f1a",
    "NE": "e0079f1a",
    "CS": "e0379f1a",
    "CC": "e0279f1a",
    "MI": "e0579f1a",
    "PL": "e0479f1a",
    "VS": "e0779f1a",
    "VC": "e0679f1a",
    "HI": "e0979f1a",
    "LS": "e0879f1a",
    "GE": "e0b79f1a",
    "LT": "e0a79f1a",
    "GT": "e0d79f1a",
    "LE": "e0c79f1a",
}


@pytest.mark.parametrize("cond,hexlit", list(_CSET_W0_GOLDEN.items()))
def test_cset_w0_each_cond(cond: str, hexlit: str) -> None:
    assert cset_w_cond(0, cond) == bytes.fromhex(hexlit)


def test_cset_w15_eq() -> None:
    # cset w15, eq ; [0xef,0x17,0x9f,0x1a]
    assert cset_w_cond(15, "EQ") == bytes.fromhex("ef179f1a")


def test_cset_unknown_cond() -> None:
    with pytest.raises(ValueError):
        cset_w_cond(0, "ZZ")


def test_cset_al_nv_accepted() -> None:
    # AL/NV are accepted by the encoder (the table includes them); we just
    # check they don't raise and produce 4 bytes. They're not normally used
    # for CSET, but the table parity matters for completeness.
    assert "AL" in _COND_CODES
    assert "NV" in _COND_CODES
    assert len(cset_w_cond(0, "AL")) == 4
    assert len(cset_w_cond(0, "NV")) == 4


def test_cset_reg_range() -> None:
    with pytest.raises(ValueError):
        cset_w_cond(32, "EQ")


# ---------------------------------------------------------------------------
# Loads / stores
# ---------------------------------------------------------------------------


def test_ldr_w_imm() -> None:
    # ldr w0, [x1]          ; [0x20,0x00,0x40,0xb9]
    assert ldr_w_imm(0, 1, 0) == bytes.fromhex("200040b9")
    # ldr w0, [x1, #4]      ; [0x20,0x04,0x40,0xb9]
    assert ldr_w_imm(0, 1, 4) == bytes.fromhex("200440b9")
    # ldr w15, [x16, #0xffc]; [0x0f,0xfe,0x4f,0xb9]
    assert ldr_w_imm(15, 16, 0xFFC) == bytes.fromhex("0ffe4fb9")


def test_ldr_w_imm_range() -> None:
    with pytest.raises(ValueError):
        ldr_w_imm(0, 1, -4)
    with pytest.raises(ValueError):
        ldr_w_imm(0, 1, 1)  # not 4-aligned
    with pytest.raises(ValueError):
        ldr_w_imm(0, 1, 0x4000)  # out of imm12*4 (max is 0xFFF*4 = 0x3FFC)


def test_ldr_x_imm() -> None:
    # ldr x0, [x1]           ; [0x20,0x00,0x40,0xf9]
    assert ldr_x_imm(0, 1, 0) == bytes.fromhex("200040f9")
    # ldr x0, [x1, #8]       ; [0x20,0x04,0x40,0xf9]
    assert ldr_x_imm(0, 1, 8) == bytes.fromhex("200440f9")
    # ldr x15, [x16, #0x7ff8]; [0x0f,0xfe,0x7f,0xf9]
    assert ldr_x_imm(15, 16, 0x7FF8) == bytes.fromhex("0ffe7ff9")


def test_ldr_x_imm_range() -> None:
    with pytest.raises(ValueError):
        ldr_x_imm(0, 1, -8)
    with pytest.raises(ValueError):
        ldr_x_imm(0, 1, 4)  # not 8-aligned
    with pytest.raises(ValueError):
        ldr_x_imm(0, 1, 0x8000)  # out of imm12*8


def test_strb_w_imm() -> None:
    # strb w0, [x1]         ; [0x20,0x00,0x00,0x39]
    assert strb_w_imm(0, 1, 0) == bytes.fromhex("20000039")
    # strb w0, [x1, #1]     ; [0x20,0x04,0x00,0x39]
    assert strb_w_imm(0, 1, 1) == bytes.fromhex("20040039")
    # strb w15, [x16, #0xfff] ; [0x0f,0xfe,0x3f,0x39]
    assert strb_w_imm(15, 16, 0xFFF) == bytes.fromhex("0ffe3f39")


def test_strb_w_imm_range() -> None:
    with pytest.raises(ValueError):
        strb_w_imm(0, 1, -1)
    with pytest.raises(ValueError):
        strb_w_imm(0, 1, 0x1000)


# ---------------------------------------------------------------------------
# Pair loads / stores
# ---------------------------------------------------------------------------


def test_stp_pre_x() -> None:
    # stp x0, x1, [sp, #-16]!     ; [0xe0,0x07,0xbf,0xa9]
    assert stp_pre_x(0, 1, 31, -16) == bytes.fromhex("e007bfa9")
    # stp x29, x30, [sp, #-0x90]! ; [0xfd,0x7b,0xb7,0xa9]
    assert stp_pre_x(29, 30, 31, -0x90) == bytes.fromhex("fd7bb7a9")


def test_stp_off_x() -> None:
    # stp x0, x1, [sp]            ; [0xe0,0x07,0x00,0xa9]
    assert stp_off_x(0, 1, 31, 0) == bytes.fromhex("e00700a9")
    # stp x29, x30, [sp, #-512]   ; [0xfd,0x7b,0x20,0xa9]
    assert stp_off_x(29, 30, 31, -512) == bytes.fromhex("fd7b20a9")
    # stp x29, x30, [sp, #504]    ; [0xfd,0xfb,0x1f,0xa9]
    assert stp_off_x(29, 30, 31, 504) == bytes.fromhex("fdfb1fa9")
    # stp x19, x20, [sp, #0x10]   ; [0xf3,0x53,0x01,0xa9]
    assert stp_off_x(19, 20, 31, 0x10) == bytes.fromhex("f35301a9")


def test_stp_range() -> None:
    with pytest.raises(ValueError):
        stp_off_x(0, 1, 31, 4)  # not 8-aligned
    with pytest.raises(ValueError):
        stp_off_x(0, 1, 31, -520)
    with pytest.raises(ValueError):
        stp_off_x(0, 1, 31, 512)
    with pytest.raises(ValueError):
        stp_pre_x(0, 1, 31, 1)


def test_ldp_off_x() -> None:
    # ldp x0, x1, [sp]          ; [0xe0,0x07,0x40,0xa9]
    assert ldp_off_x(0, 1, 31, 0) == bytes.fromhex("e00740a9")
    # ldp x0, x1, [sp, #-512]   ; [0xe0,0x07,0x60,0xa9]
    assert ldp_off_x(0, 1, 31, -512) == bytes.fromhex("e00760a9")
    # ldp x0, x1, [sp, #504]    ; [0xe0,0x87,0x5f,0xa9]
    assert ldp_off_x(0, 1, 31, 504) == bytes.fromhex("e0875fa9")


def test_ldp_post_x() -> None:
    # ldp x29, x30, [sp], #0x90 ; [0xfd,0x7b,0xc9,0xa8]
    assert ldp_post_x(29, 30, 31, 0x90) == bytes.fromhex("fd7bc9a8")
    # ldp x0, x1, [sp], #16     ; [0xe0,0x07,0xc1,0xa8]
    assert ldp_post_x(0, 1, 31, 16) == bytes.fromhex("e007c1a8")


# ---------------------------------------------------------------------------
# Branches
# ---------------------------------------------------------------------------


def test_b_imm_zero_delta() -> None:
    # b #0 (delta = 0) ; [0x00,0x00,0x00,0x14]
    assert b_imm(0x1000, 0x1000) == bytes.fromhex("00000014")


def test_b_imm_forward_4() -> None:
    # b #4 (delta = 1 insn) ; [0x01,0x00,0x00,0x14]
    assert b_imm(0x1000, 0x1004) == bytes.fromhex("01000014")


def test_b_imm_backward_4() -> None:
    # b #-4 (delta = -1) ; [0xff,0xff,0xff,0x17]
    assert b_imm(0x1004, 0x1000) == bytes.fromhex("ffffff17")


def test_b_imm_forward_256() -> None:
    # b #0x100 ; [0x40,0x00,0x00,0x14]
    assert b_imm(0x1000, 0x1100) == bytes.fromhex("40000014")


def test_b_imm_backward_256() -> None:
    # b #-0x100 ; [0xc0,0xff,0xff,0x17]
    assert b_imm(0x1100, 0x1000) == bytes.fromhex("c0ffff17")


def test_b_imm_max_forward() -> None:
    # b #0x7FFFFFC (largest forward jump = (1<<25)-1 insns) ; [0xff,0xff,0xff,0x15]
    assert b_imm(0x0, 0x7FFFFFC) == bytes.fromhex("ffffff15")


def test_b_imm_max_backward() -> None:
    # b #-0x8000000 (largest backward = -(1<<25) insns) ; [0x00,0x00,0x00,0x16]
    assert b_imm(0x8000000, 0x0) == bytes.fromhex("00000016")


def test_b_imm_alignment() -> None:
    with pytest.raises(ValueError):
        b_imm(0x1001, 0x2000)
    with pytest.raises(ValueError):
        b_imm(0x1000, 0x2001)


def test_b_imm_out_of_range() -> None:
    # Forward by (1<<25) * 4 = 0x8000000 bytes is one past the end.
    with pytest.raises(ValueError):
        b_imm(0x0, 0x8000000)
    with pytest.raises(ValueError):
        b_imm(0x8000004, 0x0)


def test_bl_imm() -> None:
    # bl #0 ; [0x00,0x00,0x00,0x94]
    assert bl_imm(0x1000, 0x1000) == bytes.fromhex("00000094")
    # bl #4 ; [0x01,0x00,0x00,0x94]
    assert bl_imm(0x1000, 0x1004) == bytes.fromhex("01000094")
    # bl #-4 ; [0xff,0xff,0xff,0x97]
    assert bl_imm(0x1004, 0x1000) == bytes.fromhex("ffffff97")
    # bl #0x100 ; [0x40,0x00,0x00,0x94]
    assert bl_imm(0x1000, 0x1100) == bytes.fromhex("40000094")


def test_bl_imm_alignment() -> None:
    with pytest.raises(ValueError):
        bl_imm(0x1001, 0x2000)
    with pytest.raises(ValueError):
        bl_imm(0x1000, 0x2002)


def test_br_x() -> None:
    # br x0  ; [0x00,0x00,0x1f,0xd6]
    assert br_x(0) == bytes.fromhex("00001fd6")
    # br x16 ; [0x00,0x02,0x1f,0xd6]
    assert br_x(16) == bytes.fromhex("00021fd6")


def test_br_x_range() -> None:
    with pytest.raises(ValueError):
        br_x(32)


def test_blr_x() -> None:
    # blr x0  ; [0x00,0x00,0x3f,0xd6]
    assert blr_x(0) == bytes.fromhex("00003fd6")
    # blr x16 ; [0x00,0x02,0x3f,0xd6]
    assert blr_x(16) == bytes.fromhex("00023fd6")


def test_ret_insn() -> None:
    # ret ; [0xc0,0x03,0x5f,0xd6]
    assert ret_insn() == bytes.fromhex("c0035fd6")


# ---------------------------------------------------------------------------
# Page-relative addressing
# ---------------------------------------------------------------------------


def test_adrp_same_page() -> None:
    # adrp x0, #0 ; [0x00,0x00,0x00,0x90]
    assert adrp(0, 0x1000, 0x1000) == bytes.fromhex("00000090")


def test_adrp_next_page() -> None:
    # adrp x0, #0x1000 ; [0x00,0x00,0x00,0xb0]
    # ADRP encodes the page delta; src page 0 -> dst page 1.
    assert adrp(0, 0x0, 0x1000) == bytes.fromhex("000000b0")


def test_adrp_previous_page() -> None:
    # adrp x0, #-0x1000 ; [0xe0,0xff,0xff,0xf0]
    # delta_pages = -1 -> imm21 = 0x1FFFFF, immlo=3, immhi=0x7FFFF
    assert adrp(0, 0x1000, 0x0) == bytes.fromhex("e0fffff0")


def test_adrp_low_bits_ignored() -> None:
    # ADRP only cares about the page; low 12 bits of dst should not matter.
    assert adrp(0, 0x0, 0x1FFF) == adrp(0, 0x0, 0x1000)


def test_adrp_reg() -> None:
    # adrp x16, #0 ; [0x10,0x00,0x00,0x90]
    assert adrp(16, 0x1000, 0x1000) == bytes.fromhex("10000090")


def test_adrp_max_forward() -> None:
    # adrp x0, #0x1FFFF000 ; [0xe0,0xff,0x0f,0xf0]
    # delta_pages = 0x1FFFF (max positive in 21-bit signed)
    assert adrp(0, 0x0, 0x1FFFF000) == bytes.fromhex("e0ff0ff0")


def test_adrp_max_backward() -> None:
    # adrp x0, #-0x100000000 ; [0x00,0x00,0x80,0x90]
    # delta_pages = -(1<<20)
    assert adrp(0, 0x100000000, 0x0) == bytes.fromhex("00008090")


def test_adrp_out_of_range() -> None:
    # +1 page beyond max
    with pytest.raises(ValueError):
        adrp(0, 0x0, 0x100000000)
    # -1 page beyond min
    with pytest.raises(ValueError):
        adrp(0, 0x100001000, 0x0)


def test_adrp_reg_range() -> None:
    with pytest.raises(ValueError):
        adrp(32, 0x1000, 0x1000)


def test_adrp_add_pair_composes() -> None:
    # ADRP X0, page; ADD X0, X0, #lo12 — for src_va=0x1000, target=0x1234:
    #   ADRP X0, #0    -> 0x00000090  (same page)
    #   ADD  X0, X0, #0x234 -> add_x_imm(0, 0, 0x234)
    out = adrp_add_pair(0x1000, 0, 0x1234)
    assert len(out) == 8
    assert out[:4] == adrp(0, 0x1000, 0x1234)
    assert out[4:] == add_x_imm(0, 0, 0x234)


def test_adrp_ldr_x_pair_composes() -> None:
    # ADRP X16, page; LDR X16, [X16, #lo12] — for src_va=0x1000, ptr=0x2008:
    out = adrp_ldr_x_pair(0x1000, 16, 0x2008)
    assert len(out) == 8
    assert out[:4] == adrp(16, 0x1000, 0x2008)
    assert out[4:] == ldr_x_imm(16, 16, 0x008)


def test_adrp_ldr_x_pair_requires_8_alignment() -> None:
    with pytest.raises(ValueError):
        adrp_ldr_x_pair(0x1000, 16, 0x2004)
