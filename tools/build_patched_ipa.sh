#!/usr/bin/env bash
# Build a patched IPA suitable for the iOS 18 sideloaded / TrollStored
# install path (where iOS 18's Code Signing Monitor blocks any runtime
# inline hook into __TEXT).
#
# The script is a generic four-step pipeline driven by a recipe:
#
#   1. Extract the input IPA into a working directory.
#   2. Run `python3 -m tools.patch_macho --recipe <name>` against the
#      framework binary the recipe targets (binary patches + cave
#      payloads + LC_LOAD_DYLIB insertion).
#   3. Run `python3 -m tools.patch_plist --recipe <name>` against
#      Info.plist (so the recipe can flip UIFileSharingEnabled etc.).
#   4. Drop the recipe's dylib next to the patched framework so dyld
#      can resolve `@executable_path/Frameworks/<name>.dylib`, and
#      re-zip the bundle.
#
# Re-running with the same input IPA is idempotent — every step no-ops
# when its patch is already applied.
#
# Usage:
#   tools/build_patched_ipa.sh \
#     --recipe <recipe-name> \
#     --framework <Mach-O basename, e.g. UnityFramework> \
#     --dylib <path/to/Payload.dylib> \
#     --input <clean.ipa> \
#     [--output <out.ipa>]
#
# The script never distributes the input IPA itself — the operator
# supplies one.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: build_patched_ipa.sh --recipe NAME --framework BASENAME --dylib PATH --input IPA [--output IPA]

  --recipe NAME      tools.recipes.<NAME> Python module to apply.
  --framework BASE   Filename of the Mach-O inside Payload/*.app/Frameworks
                     to patch (e.g. UnityFramework).
  --dylib PATH       Path to the payload dylib to drop next to the framework.
                     Its basename must match the recipe's DYLIB_PATH leaf.
  --input IPA        Path to the clean .ipa (decrypted; this script does
                     NOT distribute the IPA itself).
  --output IPA       Optional; defaults to packages/ipa/<basename-of-dylib>.ipa.
EOF
    exit 64
}

RECIPE=""
FRAMEWORK=""
DYLIB_SRC=""
INPUT_IPA=""
OUTPUT_IPA=""

while [ $# -gt 0 ]; do
    case "$1" in
        --recipe)    RECIPE="$2"; shift 2;;
        --framework) FRAMEWORK="$2"; shift 2;;
        --dylib)     DYLIB_SRC="$2"; shift 2;;
        --input)     INPUT_IPA="$2"; shift 2;;
        --output)    OUTPUT_IPA="$2"; shift 2;;
        -h|--help)   usage;;
        *)           echo "error: unknown argument: $1" >&2; usage;;
    esac
done

if [ -z "$RECIPE" ] || [ -z "$FRAMEWORK" ] || [ -z "$DYLIB_SRC" ] || [ -z "$INPUT_IPA" ]; then
    echo "error: --recipe, --framework, --dylib, --input are all required" >&2
    usage
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DYLIB_BASENAME="$(basename "$DYLIB_SRC")"
DYLIB_STEM="${DYLIB_BASENAME%.dylib}"
OUTPUT_IPA="${OUTPUT_IPA:-$PROJECT_DIR/packages/ipa/${DYLIB_STEM}-binpatch.ipa}"
WORK_DIR="$PROJECT_DIR/.theos/ipa_build"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ ! -f "$INPUT_IPA" ]; then
    echo "error: input IPA not found: $INPUT_IPA" >&2
    exit 1
fi
if [ ! -f "$DYLIB_SRC" ]; then
    echo "error: payload dylib not found: $DYLIB_SRC" >&2
    exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
    echo "error: unzip not on PATH" >&2
    exit 1
fi
if ! command -v zip >/dev/null 2>&1; then
    echo "error: zip not on PATH" >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 not on PATH" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Clean workspace + extract
# ---------------------------------------------------------------------------
echo "==> staging: $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "==> extracting $INPUT_IPA"
unzip -q "$INPUT_IPA" -d "$WORK_DIR"

# Locate the .app — the standard layout is Payload/<name>.app/, but be
# defensive in case the IPA was zipped with extra wrappers.
APP_DIR="$(find "$WORK_DIR/Payload" -maxdepth 1 -mindepth 1 -name "*.app" -type d | head -n 1)"
if [ -z "$APP_DIR" ]; then
    echo "error: no .app bundle found inside Payload/" >&2
    exit 1
fi
APP_NAME="$(basename "$APP_DIR")"
echo "==> found bundle: $APP_NAME"

FRAMEWORK_BIN="$APP_DIR/Frameworks/${FRAMEWORK}.framework/${FRAMEWORK}"
INFO_PLIST="$APP_DIR/Info.plist"

if [ ! -f "$FRAMEWORK_BIN" ]; then
    echo "error: framework Mach-O missing at $FRAMEWORK_BIN" >&2
    exit 1
fi
if [ ! -f "$INFO_PLIST" ]; then
    echo "error: Info.plist missing at $INFO_PLIST" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. patch framework
# ---------------------------------------------------------------------------
echo "==> patching $FRAMEWORK (recipe: $RECIPE)"
(cd "$PROJECT_DIR" && python3 -m tools.patch_macho --recipe "$RECIPE" "$FRAMEWORK_BIN")

echo "==> verifying LC_LOAD_DYLIB (recipe: $RECIPE)"
(cd "$PROJECT_DIR" && python3 -m tools.verify_lc_load --recipe "$RECIPE" "$FRAMEWORK_BIN" >/dev/null)

# ---------------------------------------------------------------------------
# 3. patch Info.plist
# ---------------------------------------------------------------------------
echo "==> patching Info.plist (recipe: $RECIPE)"
(cd "$PROJECT_DIR" && python3 -m tools.patch_plist --recipe "$RECIPE" "$INFO_PLIST")

# ---------------------------------------------------------------------------
# 4. inject dylib
# ---------------------------------------------------------------------------
DYLIB_DST="$APP_DIR/Frameworks/${DYLIB_BASENAME}"
echo "==> installing dylib -> Frameworks/${DYLIB_BASENAME}"
cp "$DYLIB_SRC" "$DYLIB_DST"
chmod 0755 "$DYLIB_DST"

# ---------------------------------------------------------------------------
# 5. zip into IPA
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT_IPA")"
echo "==> repacking into $OUTPUT_IPA"
# zip from inside WORK_DIR so the archive root is Payload/, matching the
# canonical IPA layout. -X strips extra metadata that some installers
# choke on; -r recurses into the bundle.
(cd "$WORK_DIR" && zip -qrX "$OUTPUT_IPA" Payload)

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "==> done"
ls -la "$OUTPUT_IPA"
echo
echo "Next steps:"
echo "  - TrollStore : AirDrop \"$OUTPUT_IPA\" to the device and open it."
echo "  - Sideloadly : drag-and-drop \"$OUTPUT_IPA\", sign with your Apple ID."
echo "  - AltStore   : the same, through AltServer."
