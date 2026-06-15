#import "Internal.h"
#import "binpatch.h"

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

#ifdef IPA_BINPATCH
// ---------------------------------------------------------------------------
// publish_binpatch_hook — IPA_BINPATCH=1 entry-publication helper.
//
// In binpatch mode we don't install any runtime hooks (Dobby / MSHook are
// fatal under iOS 18's Code Signing Monitor — see
// docs/plans/kiou_kif_exporter_binpatch.md). Instead, UnityFramework has
// already been statically patched so that each OnMatchEndAsync prologue
// branches into a cave that loads a function pointer out of a reserved
// 8-byte slot in __DATA,__bss at unityBase + KIOU_HOOK_SLOT_RVA. We just
// have to put our hook function's address there.
//
// __DATA writes don't trip CSM (the kernel only validates __TEXT page
// hashes), so this is the safe primitive for iOS 18 untethered.
// ---------------------------------------------------------------------------
static void publish_binpatch_hook(uintptr_t unityBase) {
    g_unityBase = unityBase;

    void **slot = (void **)(unityBase + (uintptr_t)KIOU_HOOK_SLOT_RVA);
    *slot = (void *)&hook_OnMatchEndAsync;

    file_log([NSString stringWithFormat:
              @"[BINPATCH] published &hook_OnMatchEndAsync=%p "
              @"-> slot=%p (unityBase=0x%lx + rva=0x%lx)",
              (void *)&hook_OnMatchEndAsync, (void *)slot,
              (unsigned long)unityBase,
              (unsigned long)KIOU_HOOK_SLOT_RVA]);
}
#endif

static void installUnityHooks(void) {
    if (g_unityHooked) return;

    // Locate UnityFramework via IPA-Patch/Common's generic dyld walker.
    // Returns 0 until UnityFramework is mapped — installUnityHooks is
    // called from a retry loop that takes care of the wait.
    uintptr_t unityBase = ipa_binpatch_find_image("UnityFramework");
    if (unityBase == 0) {
        return;
    }

    g_unityBase = unityBase;

    file_log([NSString stringWithFormat:
              @"UnityFramework base=0x%lx",
              (unsigned long)unityBase]);

    // Make sure the output directory is ready before the first match ends.
    // If this fails, kif_writer_emit_for_match_end will retry — but doing
    // it up-front gives a clear log line if NSFileManager refuses.
    NSString *outDir = kif_ensure_output_dir();
    file_log([NSString stringWithFormat:
              @"output dir = %@", outDir ?: @"(failed)"]);

#ifndef IPA_BINPATCH
    // Runtime-hook install path (Phase 1 / jailbroken builds). Uses
    // MSHookFunction or Dobby under the hood — both rely on mprotect +
    // memcpy into __TEXT, which iOS 18 CSM kills on contact. That's
    // exactly why the IPA_BINPATCH path below exists.
    install_MatchModeObserve_hook(unityBase);
#else
    // iOS 18 binpatch path: UnityFramework's prologues are already
    // rewritten to branch into a cave; we only publish our hook function
    // pointer into the __DATA slot the patched cave reads from.
    publish_binpatch_hook(unityBase);
#endif

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
