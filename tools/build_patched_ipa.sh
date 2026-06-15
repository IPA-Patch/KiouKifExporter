#!/usr/bin/env bash
# Build a patched KIOU IPA suitable for the iOS 18 sideloaded /
# TrollStored install path.
#
# Workflow:
#   1. Extract a clean KIOU.ipa into a working directory.
#   2. Run tools/patch_unity.py against UnityFramework (adds LC_LOAD_DYLIB,
#      rewrites the five OnMatchEndAsync prologues to a cave).
#   3. Run tools/patch_info_plist.py against Info.plist (adds the
#      UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace keys).
#   4. Copy packages/binpatch/KiouKifExporter.dylib next to the patched
#      UnityFramework so dyld can resolve @executable_path/Frameworks/
#      KiouKifExporter.dylib.
#   5. Zip the bundle as packages/ipa/KiouKifExporter-binpatch-<ver>.ipa.
#
# Re-running with the same input IPA is idempotent — every step is
# careful to no-op when the patch is already applied.
#
# Usage:
#   tools/build_patched_ipa.sh <clean-kiou.ipa> [output.ipa]
#
# Example:
#   tools/build_patched_ipa.sh /home/vscode/app/assets/Kiou-1.0.1.ipa
#
# Output defaults to packages/ipa/KiouKifExporter-binpatch.ipa.

set -euo pipefail

usage() {
    echo "Usage: $0 <clean-kiou.ipa> [output.ipa]" >&2
    echo >&2
    echo "  clean-kiou.ipa : decrypted KIOU.ipa straight out of the App Store" >&2
    echo "                   (this script DOES NOT distribute the IPA itself)" >&2
    echo "  output.ipa     : optional; defaults to packages/ipa/KiouKifExporter-binpatch.ipa" >&2
    exit 64
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    usage
fi

INPUT_IPA="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT_IPA="${2:-$PROJECT_DIR/packages/ipa/KiouKifExporter-binpatch.ipa}"

DYLIB_SRC="$PROJECT_DIR/packages/binpatch/KiouKifExporter.dylib"
WORK_DIR="$PROJECT_DIR/.theos/ipa_build"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [ ! -f "$INPUT_IPA" ]; then
    echo "error: clean IPA not found: $INPUT_IPA" >&2
    exit 1
fi
if [ ! -f "$DYLIB_SRC" ]; then
    echo "error: binpatch dylib not found: $DYLIB_SRC" >&2
    echo "       run \`make binpatch\` first." >&2
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

# ---------------------------------------------------------------------------
# 1. Clean workspace + extract
# ---------------------------------------------------------------------------
echo "==> staging: $WORK_DIR"
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"

echo "==> extracting $INPUT_IPA"
unzip -q "$INPUT_IPA" -d "$WORK_DIR"

# Locate KIOU.app — the standard layout is Payload/KIOU.app/, but be
# defensive in case the IPA was zipped with extra wrappers.
APP_DIR="$(find "$WORK_DIR/Payload" -maxdepth 1 -mindepth 1 -name "*.app" -type d | head -n 1)"
if [ -z "$APP_DIR" ]; then
    echo "error: no .app bundle found inside Payload/" >&2
    exit 1
fi
APP_NAME="$(basename "$APP_DIR")"
echo "==> found bundle: $APP_NAME"

UNITY_BIN="$APP_DIR/Frameworks/UnityFramework.framework/UnityFramework"
INFO_PLIST="$APP_DIR/Info.plist"

if [ ! -f "$UNITY_BIN" ]; then
    echo "error: UnityFramework Mach-O missing at $UNITY_BIN" >&2
    exit 1
fi
if [ ! -f "$INFO_PLIST" ]; then
    echo "error: Info.plist missing at $INFO_PLIST" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. patch UnityFramework
# ---------------------------------------------------------------------------
echo "==> patching UnityFramework"
python3 "$SCRIPT_DIR/patch_unity.py" "$UNITY_BIN"

echo "==> verifying LC_LOAD_DYLIB"
python3 "$SCRIPT_DIR/verify_lc_load.py" "$UNITY_BIN" >/dev/null

# ---------------------------------------------------------------------------
# 3. patch Info.plist
# ---------------------------------------------------------------------------
echo "==> patching Info.plist"
python3 "$SCRIPT_DIR/patch_info_plist.py" "$INFO_PLIST"

# ---------------------------------------------------------------------------
# 4. inject dylib
# ---------------------------------------------------------------------------
DYLIB_DST="$APP_DIR/Frameworks/KiouKifExporter.dylib"
echo "==> installing dylib -> Frameworks/KiouKifExporter.dylib"
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
echo "  - TrollStore       : AirDrop \"$OUTPUT_IPA\" to the device and open it."
echo "  - Sideloadly       : drag-and-drop \"$OUTPUT_IPA\", sign with your Apple ID."
echo "  - AltStore         : the same, through AltServer."
echo
echo "Once installed, KIF files land in"
echo "  <KIOU sandbox>/Documents/KiouKifExporter/{ISO8601}_{mode}_{startpos}.kif"
echo "and the dylib's diagnostic log is at"
echo "  <KIOU sandbox>/Documents/kioukifexporter.log"
echo "Both are visible through Files.app under \"On My iPhone -> KIOU\"."
