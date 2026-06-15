"""Static binary-patch tooling.

Target-agnostic primitives for assembling a patched iOS .ipa: arm64
instruction encoding, Mach-O load-command insertion, code-cave routing,
and Info.plist editing. Per-target recipes (which sites to redirect,
which dylib to inject, which plist keys to flip) live in
``tools.recipes`` so this package can be reused unchanged across
projects.
"""
