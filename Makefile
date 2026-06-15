# ===========================================================================
# IPA-Patch tweak Makefile.
#
# Targets:
#   make            — JB rootless .deb (MSHookFunction via libsubstrate)
#   make package    — same, packaged
#   make jailed     — Dobby-static .dylib for Sideloadly injection (iOS 15-17)
#   make binpatch   — Dobby-static .dylib for the statically-patched IPA path
#                     (iOS 18 sideload; the only mode that survives CSM).
#   make ipa        — patched IPA assembled from $(DECRYPTED_IPA)
#
# Layout: every project-specific value lives in the PROJECT VARIABLES
# block below. Adapting this Makefile to a sibling tweak should be that
# one block + the recipe + the source dir; the build rules below stay
# verbatim.
# ===========================================================================

# ---------------------------------------------------------------------------
# PROJECT VARIABLES — only block that needs editing per tweak.
# ---------------------------------------------------------------------------
TWEAK_NAME               := KiouKifExporter
TWEAK_SOURCES_DIR        := Sources/$(TWEAK_NAME)

# Process killed at install-time and bundle id used to relaunch the host app.
TARGET_PROCESS           := KIOU
TARGET_BUNDLE_ID         := com.neconome.shogi

# Decrypted IPA the binpatch pipeline consumes. App Store IPAs ship
# FairPlay-encrypted; you need a frida-ios-dump-style decrypted copy.
# The patcher never redistributes it; the operator drops one under
# assets/. Override on the command line:
#   make ipa DECRYPTED_IPA=/path/to/decrypted.ipa
DECRYPTED_IPA            ?= $(CURDIR)/assets/Kiou-1.0.1.ipa
# Python recipe module driving the static patcher (must be importable from
# the project root with `recipes/` on PYTHONPATH).
IPA_RECIPE               := recipes.kioukifexporter
# Mach-O basename inside the IPA that recipes/ targets.
IPA_FRAMEWORK            := UnityFramework

# Preprocessor macro that carries the short HEAD commit into the dylib
# (referenced from C as a string literal). Rename freely; just keep the
# matching `#ifndef … #define …` in the tweak's Internal.h aligned.
BUILD_COMMIT_DEFINE      := KIOU_KIF_EXPORTER_COMMIT

# ---------------------------------------------------------------------------
# Theos boilerplate.
# ---------------------------------------------------------------------------
TARGET                   := iphone:clang:16.5:15.0
INSTALL_TARGET_PROCESSES := $(TARGET_PROCESS)
ARCHS                    := arm64
THEOS_PACKAGE_SCHEME     := rootless
THEOS_DEVICE_IP          ?= 192.168.0.49

include $(THEOS)/makefiles/common.mk

# Theos derives every per-tweak variable from $(TWEAK_NAME) — the
# variable's exact case must match the tweak name. Going through
# $(TWEAK_NAME)_FOO keeps that constraint in one place and stops the
# build file from sprouting a "KiouKifExporter_" CamelCase prefix next
# to the project's own UPPER_SNAKE_CASE macros.
$(TWEAK_NAME)_FILES      := $(shell find $(TWEAK_SOURCES_DIR) -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp')
# Common runtime — git submodule at Sources/Common. il2cpp.h /
# hookengine.h are header-only; logging.m and binpatch.m are the only
# translation units to compile. binpatch.m exports two read-only
# helpers (image lookup + B<cave> decode); KifExporter only calls the
# former (from Tweak.m), but the latter costs nothing to link and the
# next hook addition gets the trampoline plumbing for free.
$(TWEAK_NAME)_FILES      += Sources/Common/logging.m
$(TWEAK_NAME)_FILES      += Sources/Common/binpatch.m

# Build-time git short HEAD (7 chars). No -dirty suffix for now.
BUILD_COMMIT             ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null || echo unknown)

$(TWEAK_NAME)_CFLAGS     := -fobjc-arc -Wno-unused-function \
                            -D$(BUILD_COMMIT_DEFINE)=\"$(BUILD_COMMIT)\" \
                            -ISources/Common -I$(TWEAK_SOURCES_DIR)
$(TWEAK_NAME)_FRAMEWORKS := Foundation

# ---------------------------------------------------------------------------
# Hook engine / distribution selection.
#
#   default (JB / rootless): MobileSubstrate (MSHookFunction in libsubstrate).
#   JAILED=1               : Dobby, statically linked from vendor/dobby/lib/
#                            libdobby.a so the dylib has no external
#                            hook-engine dependency. Useful on jailbroken
#                            iOS 15-17; on iOS 18 the runtime mprotect/memcpy
#                            inline rewrite is killed by Code Signing Monitor
#                            (see docs/binpatch.md), so iOS 18 sideload
#                            targets must go through BINPATCH=1 instead.
#   BINPATCH=1             : Statically-patched $(IPA_FRAMEWORK) distribution.
#                            The Mach-O is rewritten ahead of time so each
#                            hook site BL's into a __TEXT cave that calls
#                            the dylib through a __DATA hook-slot table;
#                            the dylib only ever writes to __DATA so CSM
#                            stays happy. Implies JAILED=1 (no libsubstrate
#                            dependency) and routes the file log into
#                            Documents/ so operators can read it via
#                            Files.app.
#
# Sources/Common/hookengine.h's shim picks the matching API at compile
# time. Even though the binpatch codepath never invokes DobbyHook at
# runtime, keeping the link shape identical to `jailed::` means the
# existing hookengine include + Hook_*.m TUs compile cleanly and the
# dylib has zero external hook-engine dependency.
# ---------------------------------------------------------------------------
ifeq ($(BINPATCH),1)
    JAILED                   := 1
    $(TWEAK_NAME)_CFLAGS     += -DIPA_BINPATCH=1 -DIPA_LOG_TO_DOCUMENTS=1
endif

ifeq ($(JAILED),1)
    $(TWEAK_NAME)_CFLAGS     += -DIPA_JAILED=1 -Ivendor/dobby/include
    # Dobby is C++; pull in libc++ for __cxa_guard_*, __cxa_pure_virtual, etc.
    $(TWEAK_NAME)_LDFLAGS    := -Lvendor/dobby/lib -ldobby -lc++ -lc++abi
else
    $(TWEAK_NAME)_LDFLAGS    := -lsubstrate
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "chmod 755 /var/jb/Library/MobileSubstrate/DynamicLibraries/$(TWEAK_NAME).dylib"
	# INSTALL_TARGET_PROCESSES killed the app; relaunch via whichever launcher tool is present.
	install.exec "sleep 1; (open $(TARGET_BUNDLE_ID) 2>/dev/null || uiopen $(TARGET_BUNDLE_ID):// 2>/dev/null || echo 'no launcher tool (uiopen/open); start $(TARGET_PROCESS) manually')"

# jailed distribution: rebuild with Dobby statically linked, then copy the
# resulting .dylib into packages/jailed/ for Sideloadly injection.
# Verifies the final binary has no libsubstrate/libdobby external dep.
jailed::
	$(MAKE) JAILED=1 clean
	$(MAKE) JAILED=1 all
	$(ECHO_NOTHING)mkdir -p packages/jailed$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/jailed/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "jailed dylib -> packages/jailed/$(TWEAK_NAME).dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/jailed/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# ---------------------------------------------------------------------------
# binpatch distribution: same link shape as `jailed::` (Dobby statically
# linked, no libsubstrate dependency) but with -DIPA_BINPATCH=1 so the
# constructor publishes hook function pointers into the patched binary's
# reserved __DATA slot table instead of trying to inline-rewrite __TEXT.
# This is the only build mode that survives iOS 18's Code Signing Monitor
# on a sideloaded IPA. Drops the artifact into packages/binpatch/.
# ---------------------------------------------------------------------------
binpatch::
	$(MAKE) BINPATCH=1 clean
	$(MAKE) BINPATCH=1 all
	$(ECHO_NOTHING)mkdir -p packages/binpatch$(ECHO_END)
	$(ECHO_NOTHING)cp $(THEOS_OBJ_DIR)/$(TWEAK_NAME).dylib packages/binpatch/$(TWEAK_NAME).dylib$(ECHO_END)
	@echo "binpatch dylib -> packages/binpatch/$(TWEAK_NAME).dylib"
	@echo "--- otool -L (must NOT list libsubstrate or libdobby) ---"
	@$(THEOS)/toolchain/linux/iphone/bin/otool -L packages/binpatch/$(TWEAK_NAME).dylib 2>/dev/null \
	  || otool -L packages/binpatch/$(TWEAK_NAME).dylib 2>/dev/null \
	  || echo "(otool unavailable on host; inspect the dylib on a Mac/iOS device)"

# ---------------------------------------------------------------------------
# Full patched-IPA pipeline.
#
# Builds the binpatch dylib (if missing) and assembles a TrollStore /
# Sideloadly / AltStore / Apple Developer Program-ready IPA from the
# decrypted IPA supplied by the operator via DECRYPTED_IPA. The patcher
# itself is the target-agnostic shared/tools/build_patched_ipa.sh driven
# by the tweak-specific recipe ($(IPA_RECIPE)).
#
# This target NEVER ships a decrypted target IPA — supply your own
# (see docs/porting.md for the dump procedure).
# ---------------------------------------------------------------------------
IPA_DYLIB                := $(CURDIR)/packages/binpatch/$(TWEAK_NAME).dylib

ipa:: binpatch
	@echo "==> assembling patched IPA from $(DECRYPTED_IPA)"
	@if [ ! -f "$(DECRYPTED_IPA)" ]; then \
	  echo "error: decrypted IPA missing at $(DECRYPTED_IPA)"; \
	  echo "       override with: make ipa DECRYPTED_IPA=/path/to/decrypted.ipa"; \
	  exit 1; \
	fi
	@./shared/tools/build_patched_ipa.sh \
	  --recipe    "$(IPA_RECIPE)" \
	  --framework "$(IPA_FRAMEWORK)" \
	  --dylib     "$(IPA_DYLIB)" \
	  --input     "$(DECRYPTED_IPA)"
