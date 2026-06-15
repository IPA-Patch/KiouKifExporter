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
