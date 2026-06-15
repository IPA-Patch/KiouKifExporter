"""Target-agnostic Mach-O operations used by the patch driver.

These functions take only generic positional inputs (a path, a dylib
name, a section name) and have no knowledge of any particular target
binary. Per-target constants (cave region, slot VA, hook sites) live in
``tools.recipes``.
"""

from __future__ import annotations


# ---------------------------------------------------------------------------
# Versioning helpers
# ---------------------------------------------------------------------------


def encode_macho_version(major: int, minor: int, patch: int) -> int:
    """Encode a ``(major, minor, patch)`` triple into the Mach-O 32-bit
    dylib version format ``xxxx.yy.zz`` (``(major << 16) | (minor << 8) | patch``)."""
    if not (0 <= major <= 0xFFFF and 0 <= minor <= 0xFF and 0 <= patch <= 0xFF):
        raise ValueError(f"version triple out of range: {major}.{minor}.{patch}")
    return (major << 16) | (minor << 8) | patch


# ---------------------------------------------------------------------------
# Iteration helpers
# ---------------------------------------------------------------------------


def iter_thin_binaries(parsed):
    """Yield each thin ``MachO.Binary`` from a ``lief.MachO.parse()`` result,
    regardless of whether the input was a Fat (Universal) Mach-O or a
    single-arch one.
    """
    import lief  # deferred so the module imports without lief installed

    if isinstance(parsed, lief.MachO.FatBinary):
        for i in range(parsed.size):
            yield parsed.at(i)
    else:
        yield parsed


# ---------------------------------------------------------------------------
# Load-command insertion
# ---------------------------------------------------------------------------


def add_lc_load_dylib(target_path: str, dylib_path: str) -> None:
    """Add a new ``LC_LOAD_DYLIB`` load command pointing at ``dylib_path``
    to ``target_path`` (in place).

    Idempotent: if a ``LC_LOAD_DYLIB`` or ``LC_LOAD_WEAK_DYLIB`` whose
    name already equals ``dylib_path`` is present, this prints ``SKIP``
    and returns without modifying the binary.

    Handles both thin Mach-O and Fat (Universal) binaries — every slice
    receives the new load command.

    Versions are pinned to 1.0.0 / 1.0.0 (current / compatibility) and
    the timestamp is 0, matching the convention used by Theos /
    TrollStore sideload pipelines.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")

    mutated = False
    for binary in iter_thin_binaries(parsed):
        cpu = binary.header.cpu_type
        already_present = any(lib.name == dylib_path for lib in binary.libraries)
        if already_present:
            print(f"  SKIP  LC_LOAD_DYLIB {dylib_path} (cpu={cpu}, already present)")
            continue

        version = encode_macho_version(1, 0, 0)
        cmd = lief.MachO.DylibCommand.load_dylib(
            dylib_path,
            0,  # timestamp
            version,  # current_version
            version,  # compatibility_version
        )
        # Binary.add appends the command to the load-command region. lief
        # grows the __TEXT segment / load-command padding automatically
        # when it serialises back via write().
        binary.add(cmd)
        mutated = True
        print(f"  ADDED LC_LOAD_DYLIB {dylib_path} (cpu={cpu})")

    if mutated:
        parsed.write(target_path)


# ---------------------------------------------------------------------------
# __bss slot discovery and validation
# ---------------------------------------------------------------------------


def reserve_hook_slot(target_path: str) -> int | None:
    """Pick an 8-byte aligned slot inside the first ``__DATA,__bss`` (or
    ``__DATA,__common``) zero-fill section of the binary's first slice
    for a dylib constructor to publish a function pointer into.

    Returns the slot's virtual address relative to the Mach-O image base
    (``__TEXT`` segment base). When the image base is 0, the returned
    integer is also the absolute VA inside the Mach-O slice; the dylib
    resolves it at runtime as ``slide + return_value``.

    Returns ``None`` if no suitable zero-fill section can be located.

    Why this is safe:
      - ``__bss`` is a ZEROFILL section: it occupies no bytes in the
        file and dyld zeroes the whole region on load.
      - We pick the last 8 bytes of the section (``va + size - 8``)
        rather than the first, because compilers lay out static globals
        starting from the section base. Picking the tail minimises the
        chance of colliding with a real global that happens to be at
        offset 0 of ``__bss``.
      - The chosen address is 8-byte aligned by construction.

    Fat binaries with multiple slices would need a per-slice slot; this
    helper returns the slot of the first slice only. Callers that care
    about that should iterate slices themselves.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")

    binary = next(iter_thin_binaries(parsed))

    bss = None
    for seg in binary.segments:
        if not seg.name.startswith("__DATA"):
            continue
        for sec in seg.sections:
            if sec.name in ("__bss", "__common"):
                bss = sec
                break
        if bss is not None:
            break

    if bss is None:
        print("  WARN  reserve_hook_slot: no __DATA,__bss or __DATA,__common section found")
        return None

    if bss.size < 8:
        print(f"  WARN  reserve_hook_slot: {bss.name} too small ({bss.size} bytes)")
        return None

    usable = bss.size & ~0x7  # round down to 8-byte boundary
    slot_va = bss.virtual_address + usable - 8
    if slot_va % 8 != 0:
        print(f"  WARN  reserve_hook_slot: computed slot not 8B-aligned: 0x{slot_va:X}")
        return None

    print(
        f"  SLOT  __DATA,{bss.name} tail @ 0x{slot_va:X} "
        f"(section base 0x{bss.virtual_address:X}, size 0x{bss.size:X})"
    )
    return slot_va


def assert_slot_in_bss(target_path: str, slot_va: int) -> None:
    """Abort with a clear error if ``slot_va`` does not land inside a
    ``__DATA,__bss`` or ``__DATA,__common`` zero-fill section.

    Caves emit ``LDR X16, [page_of(slot) + lo12]``. If the slot
    accidentally fell into ``__DATA_CONST`` or any read-only segment,
    the dylib constructor's write to publish the hook pointer would
    fault at runtime on iOS 18 (and on every prior iOS, the page would
    simply be RO). This check makes that misconfiguration a build-time
    error rather than a crash on first launch.
    """
    import lief

    parsed = lief.MachO.parse(target_path)
    if parsed is None:
        raise RuntimeError(f"lief.MachO.parse returned None for {target_path}")
    binary = next(iter_thin_binaries(parsed))
    for seg in binary.segments:
        if not seg.name.startswith("__DATA"):
            continue
        for sec in seg.sections:
            s_va = sec.virtual_address
            s_end = s_va + sec.size
            if s_va <= slot_va < s_end:
                if sec.name not in ("__bss", "__common"):
                    raise RuntimeError(
                        f"hook slot 0x{slot_va:X} lies in "
                        f"{seg.name},{sec.name} — must be __bss or __common. "
                        "Aborting before the cave is written, because the "
                        "dylib constructor would fault when publishing the "
                        "hook pointer."
                    )
                return
    raise RuntimeError(
        f"hook slot 0x{slot_va:X} did not land in any __DATA section. "
        "Re-run reserve_hook_slot() against the current binary and update "
        "the recipe."
    )
