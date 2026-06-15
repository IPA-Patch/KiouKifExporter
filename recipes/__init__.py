"""Per-target patch recipes.

A recipe is a Python module exposing the following module-level names
that ``tools.patch_macho`` discovers and applies:

  - ``TARGET_BASENAME``   : str, the Mach-O filename this recipe targets
                            (used as a sanity check, e.g. ``UnityFramework``).
  - ``DYLIB_PATH``        : str, the @executable_path/... dylib path
                            inserted via ``LC_LOAD_DYLIB``.
  - ``HOOK_SLOT_RVA``     : int, the 8-byte __DATA,__bss slot the dylib
                            constructor publishes the hook function pointer
                            into. Validated against the live binary at
                            patch time; mismatches abort.
  - ``CAVE_REGION``       : ``(start, end)`` file-offset tuple for the
                            r-x zero-fill range cave payloads are carved
                            from.
  - ``PATCHES``           : list of inline single-instruction
                            replacements; usually empty.
  - ``CAVE_PATCHES``      : list of ``(site_off, expected, build_payload,
                            label)`` cave-routed redirects.

See ``tools.recipes.kioukifexporter`` for a worked example.
"""
