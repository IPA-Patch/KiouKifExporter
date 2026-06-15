TARGET := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES = KIOU
ARCHS = arm64
THEOS_PACKAGE_SCHEME = rootless
THEOS_DEVICE_IP ?= 192.168.0.49

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KiouKifExporter

KiouKifExporter_FILES = $(shell find Sources/KiouKifExporter -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Shared logging implementation lives in ./_shared/. il2cpp / hook-engine
# headers are inline-only so they don't need to be listed here.
KiouKifExporter_FILES += _shared/kiou_logging.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
KIOU_KIF_EXPORTER_COMMIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

KiouKifExporter_CFLAGS = -fobjc-arc -Wno-unused-function -DKIOU_KIF_EXPORTER_COMMIT=\"$(KIOU_KIF_EXPORTER_COMMIT)\" -I_shared
KiouKifExporter_FRAMEWORKS = Foundation

# ---------------------------------------------------------------------------
# Hook engine selection — mirrors KiouUsiProxy/Makefile.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate).
#                            Useful only for engineering convenience on a
#                            jailbroken device — production users target
#                            the JAILED=1 build below.
#   JAILED=1               : Dobby, statically linked from the KiouEditor
#                            vendor tree so we don't duplicate the .a.
#
# vendor/dobby ships in-tree (vendored, not a symlink) so the repo is
# self-contained. _shared/kiou_hookengine.h picks between MSHookFunction
# and DobbyHook at compile time.
# ---------------------------------------------------------------------------
# Phase 1.5 binary-patch distribution implies the jailed link shape:
# the dylib gets injected via LC_LOAD_DYLIB into a statically-patched
# UnityFramework on iOS 18, so it must NOT depend on libsubstrate. The
# hookengine shim still resolves to Dobby (statically linked from the
# vendor tree) — even though the binpatch codepath never actually invokes
# DobbyHook at runtime, keeping the link shape identical to `jailed::`
# means the existing hookengine include + the Hook_*.m TU compile cleanly
# and the dylib has zero external hook-engine dependency.
ifeq ($(BINPATCH),1)
    JAILED := 1
    KiouKifExporter_CFLAGS  += -DKIOU_BINPATCH=1
    # On iOS 18 / non-jailbreak the sandbox tmp/ is invisible from the
    # host's perspective (no SSH, no Filza). Push the file log into
    # Documents/ instead so operators can read it through Files.app once
    # the patched bundle has UIFileSharingEnabled set.
    KiouKifExporter_CFLAGS  += -DKIOU_LOG_TO_DOCUMENTS=1
endif

ifeq ($(JAILED),1)
    KiouKifExporter_CFLAGS  += -DKIOU_JAILED=1 -Ivendor/dobby/include
    KiouKifExporter_LDFLAGS  = -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
else
    KiouKifExporter_LDFLAGS  = -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/KiouKifExporter.dylib"
	install.exec "sleep 1; (open com.neconome.shogi 2>/dev/null || uiopen com.neconome.shogi:// 2>/dev/null || echo 'no launcher tool (uiopen/open); start KIOU manually')"

# jailed distribution: rebuild with Dobby statically linked, copy into
# packages/jailed/ for Sideloadly injection.
jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouKifExporter.dylib packages/jailed/KiouKifExporter.dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/KiouKifExporter.dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/KiouKifExporter.dylib 2>/dev/null \
	  || otool -L packages/jailed/KiouKifExporter.dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# binpatch distribution: same link shape as `jailed::` (Dobby statically
# linked, no libsubstrate) but with -DKIOU_BINPATCH=1 so the constructor
# publishes the hook pointer into UnityFramework's reserved __DATA slot
# instead of trying to MSHookFunction/DobbyHook into __TEXT. This is the
# only build mode that survives iOS 18's Code Signing Monitor. Drops the
# artifact into packages/binpatch/ for the patched-IPA pipeline.
binpatch::
	$(MAKE) BINPATCH=1 clean
	$(MAKE) BINPATCH=1 all
	$(ECHO_NOTHING)mkdir -p packages/binpatch$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/KiouKifExporter.dylib packages/binpatch/KiouKifExporter.dylib$(ECHO_END)
	@echo "binpatch dylib -> packages/binpatch/KiouKifExporter.dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/binpatch/KiouKifExporter.dylib 2>/dev/null \
	  || otool -L packages/binpatch/KiouKifExporter.dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# Full patched-IPA pipeline (Phase 1.5 distribution unit).
#
# Builds the binpatch dylib (if missing) and assembles a TrollStore /
# Sideloadly-ready IPA. The user supplies a decrypted clean KIOU IPA via
# KIOU_CLEAN_IPA; tools/build_patched_ipa.sh is target-agnostic and
# driven by the KIOU-specific tools/recipes/kioukifexporter.py recipe.
#
# This target NEVER redistributes a clean KIOU IPA — supply your own.
KIOU_CLEAN_IPA ?= /home/vscode/app/assets/Kiou-1.0.1.ipa
KIOU_IPA_RECIPE    := recipes.kioukifexporter
KIOU_IPA_FRAMEWORK := UnityFramework
KIOU_IPA_DYLIB     := $(PWD)/packages/binpatch/KiouKifExporter.dylib

ipa:: binpatch
	@echo "==> assembling patched IPA from $(KIOU_CLEAN_IPA)"
	@if [ ! -f "$(KIOU_CLEAN_IPA)" ]; then \
	  echo "error: clean KIOU IPA missing at $(KIOU_CLEAN_IPA)"; \
	  echo "       override with: make ipa KIOU_CLEAN_IPA=/path/to/clean.ipa"; \
	  exit 1; \
	fi
	@./shared/tools/build_patched_ipa.sh \
	  --recipe    "$(KIOU_IPA_RECIPE)" \
	  --framework "$(KIOU_IPA_FRAMEWORK)" \
	  --dylib     "$(KIOU_IPA_DYLIB)" \
	  --input     "$(KIOU_CLEAN_IPA)"
