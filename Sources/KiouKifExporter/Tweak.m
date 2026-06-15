#import "Internal.h"
#import <mach-o/dyld.h>
#import <string.h>

// ===========================================================================
// KiouKifExporter — entry point.
//
// Locate UnityFramework at constructor time, then install the
// MatchMode-observation hooks. Once a match ends, Hook_MatchModeObserve's
// END_HOOK fires kif_writer_emit_for_match_end which calls
// GameController.GetKifuText and writes a .kif file to the app's Documents
// directory. That's the whole tweak.
//
// No WebSocket. No HTTP. No inject side. No retry policy beyond "if
// UnityFramework isn't loaded yet, try again 1 second later."
// ===========================================================================

static BOOL g_unityHooked = NO;

// UnityFramework base captured at install time. Exposed via Internal.h so
// Kif_Writer / Helpers can resolve il2cpp NativeFunction pointers without
// re-walking dyld.
uintptr_t g_unityBase = 0;

static void installUnityHooks(void) {
    if (g_unityHooked) return;

    uint32_t imgCount = _dyld_image_count();
    uintptr_t unityBase = 0;
    const char *unityName = NULL;
    for (uint32_t i = 0; i < imgCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            unityBase = (uintptr_t)_dyld_get_image_header(i);
            unityName = name;
            break;
        }
    }

    if (unityBase == 0) {
        // Not loaded yet — retry will call us again.
        return;
    }

    g_unityBase = unityBase;

    file_log([NSString stringWithFormat:
              @"UnityFramework base=0x%lx (%s)",
              (unsigned long)unityBase, unityName ? unityName : "?"]);

    // Make sure the output directory is ready before the first match ends.
    // If this fails, kif_writer_emit_for_match_end will retry — but doing
    // it up-front gives a clear log line if NSFileManager refuses.
    NSString *outDir = kif_ensure_output_dir();
    file_log([NSString stringWithFormat:
              @"output dir = %@", outDir ?: @"(failed)"]);

    install_MatchModeObserve_hook(unityBase);

    g_unityHooked = YES;
    file_log(@"=== KiouKifExporter: all hooks installed ===");
}

static void retryInstallHooks(void) {
    if (!g_unityHooked) installUnityHooks();

    if (!g_unityHooked) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            retryInstallHooks();
        });
    }
}

__attribute__((constructor)) static void init(void) {
    logging_init("com.neconome.shogi.kioukifexporter");
    file_log(@"=== KiouKifExporter loaded ===");
    file_log([NSString stringWithFormat:@"build commit=%s",
              KIOU_KIF_EXPORTER_COMMIT]);

    // UnityFramework is almost certainly not mapped yet at constructor time.
    installUnityHooks();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        retryInstallHooks();
    });

    file_log(@"=== KiouKifExporter constructor done ===");
}
