#import "Internal.h"

// ===========================================================================
// Kif_Writer.m — the entire reason this tweak exists.
//
// Called from Hook_MatchModeObserve.m::END_HOOK once OnMatchEndAsync fires.
// Reads the KIF text off the live GameController and writes it as a UTF-8
// .kif file under Documents/KiouKifExporter/.
//
// Filename format:
//
//   {ISO8601_UTC}_{mode}_{startpos}.kif
//
//   ISO8601_UTC : "20260614T234500"
//   mode        : "AIMatchMode" | "CPUStreamMode" | "OnlinePvPMode"
//                 | "LocalPvPMode" | "RecordReplayMode" | "unknown"
//   startpos    : "startpos" | "sfen-<8 hex>" | "unknown"
//
// All segments are sanitized so the result is always a safe POSIX
// filename (no spaces, no slashes, ASCII only).
// ===========================================================================

NSString *kif_writer_emit_for_match_end(void *gameCtrl,
                                        void *matchConfig,
                                        void *stateStore,
                                        const char *matchModeTag) {
    // 1. Get the KIF text. matchConfig / stateStore may be NULL — in
    //    that case player names and time-rule label come out blank,
    //    which is acceptable.
    NSString *kif = kifTextFromGameController(gameCtrl,
                                              matchConfig,
                                              stateStore,
                                              matchModeTag);
    if (kif.length == 0) {
        file_log([NSString stringWithFormat:
                  @"[KIF] emit skipped: GetKifuText returned empty "
                  @"(gameCtrl=%p mode=%s)",
                  gameCtrl, matchModeTag ? matchModeTag : "unknown"]);
        return nil;
    }

    // 2. Make sure the output directory exists.
    NSString *outDir = kif_ensure_output_dir();
    if (!outDir) {
        file_log(@"[KIF] emit failed: output dir unavailable");
        return nil;
    }

    // 3. Build the filename.
    NSString *ts = kif_iso8601_basic_utc_now();
    NSString *modeSeg = kif_sanitize_filename_segment(
        matchModeTag ? @(matchModeTag) : @"unknown", 32);
    NSString *startposSeg = kif_describe_startpos(gameCtrl);

    NSString *filename = [NSString stringWithFormat:@"%@_%@_%@.kif",
                          ts, modeSeg, startposSeg];
    NSString *path = [outDir stringByAppendingPathComponent:filename];

    // 4. Write atomically. KIF is a text format — UTF-8 with BOM-less
    //    output is what every Japanese kifu viewer (PiyoShogi, Shogi
    //    Browser Q, KifuCloud, …) accepts.
    NSError *err = nil;
    BOOL ok = [kif writeToFile:path
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:&err];
    if (!ok) {
        file_log([NSString stringWithFormat:
                  @"[KIF] write failed: path=%@ err=%@", path, err]);
        return nil;
    }

    file_log([NSString stringWithFormat:
              @"[KIF] wrote %lu bytes -> %@",
              (unsigned long)[kif lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
              path]);
    return path;
}

// ===========================================================================
// hook_OnMatchEndAsync — the Patched-build entry point for OnMatchEndAsync.
//
// Mirrors the Tweak build's `hook_xxx_End` family (Hook_MatchModeObserve.m),
// except that under the Patched build all five concrete IMatchMode subclasses
// funnel through this one symbol — the cave passes `mode_index` so we can
// still discriminate.
//
// Called from the cave that patch_unity.py emits into UnityFramework. The
// cave loads our address from the __DATA slot (KIOU_HOOK_SLOT_RVA) and
// BLR's us BEFORE re-running the displaced prologue + jumping to
// `orig + 4`. Therefore:
//   * the live GameController is still alive (nothing has been torn down
//     yet for this match-end)
//   * our return value is dead — the cave overwrites x0/x1 with the
//     original method's result a few instructions later
//
// Always exported (not behind #ifdef IPA_BINPATCH) so that the substrate
// / jailed builds keep a single, stable symbol table. The function is
// trivially cheap when never reached.
// ===========================================================================
// Resolve the live GameController for the IMatchMode instance `self`,
// using the cave-supplied `mode_index` to look up the right
// `_gameAdapter` field offset directly. No heuristic, no fallback offset
// scan — those were the source of the production SIGBUS at
// `readPtr(unknownField + 0x10)` on iOS 18.7.7 (CPUStreamMode hit
// LocalPvPMode's 0x18 candidate first and walked into an invalid sibling
// pointer).
//
// Logs the chain (self / adapter / gameCtrl / positionHistory) on failure
// so the BINPATCH log shows exactly where the walk gave up.
static void *hook_resolveGameController(void *self,
                                        uint32_t mode_index) {
    if (mode_index >= KIOU_BINPATCH_MODE_COUNT) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] mode_index=%u out of range (count=%d)",
                  mode_index, KIOU_BINPATCH_MODE_COUNT]);
        return NULL;
    }
    if (!ptrLooksValid(self)) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] resolve: self=%p does not look valid", self]);
        return NULL;
    }
    uintptr_t adapterOff = kKiouBinpatchAdapterOffsets[mode_index];
    void *adapter = readPtr(self, adapterOff);
    if (!adapter) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] resolve: self=%p mode=%s adapterOff=0x%lx "
                  @"-> adapter=NULL",
                  self, kKiouBinpatchModeNames[mode_index],
                  (unsigned long)adapterOff]);
        return NULL;
    }
    void *gameCtrl = readPtr(adapter, KIOU_BINPATCH_ADAPTER_OFF_GAMECTRL);
    if (!gameCtrl) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] resolve: self=%p adapter=%p -> gameCtrl=NULL",
                  self, adapter]);
        return NULL;
    }
    return gameCtrl;
}

// OnlinePvPMode field offsets (dump.cs L1421556+):
//   _stateStore   @ 0x28  (GameStateStore*) — where the real friend-match
//                                            player names eventually land
//   _matchConfig  @ 0x38  (MatchConfig*)    — locked-in initial values;
//                                            BlackPlayer / WhitePlayer
//                                            stay at "プレイヤー" for
//                                            the whole match
//
// On the other four IMatchMode subclasses _matchConfig is NOT a field —
// they get cfg through InitializeAsync and throw it away — and
// _stateStore lives at a different per-mode offset. For now we only
// recover both for OnlinePvPMode (the mode where placeholders matter);
// the rest pass NULL and fall back to the Tweak-side caches (which is
// what matters during A/B development on a JB device anyway).
#define ONLINEPVPMODE_OFF_STATE_STORE_PATCHED  0x28
#define ONLINEPVPMODE_OFF_MATCHCONFIG          0x38

UniTaskRet hook_OnMatchEndAsync(void *self, void *ct,
                                uint32_t mode_index) {
    (void)ct;

    // mode_index is the cave-injected MOVZ X2,#imm that picks one of
    // KIOU_BINPATCH_MODE_*. Sanity-clip it so a future cave bug doesn't
    // turn into a stack overrun reading kKiouBinpatchAdapterOffsets[N].
    const char *modeName = (mode_index < KIOU_BINPATCH_MODE_COUNT)
        ? kKiouBinpatchModeNames[mode_index]
        : "Unknown";

    void *gameCtrl = hook_resolveGameController(self, mode_index);

    // Fallback: only useful when both the jailed runtime-hook build and
    // the binpatch build happen to be loaded into the same process for an
    // A/B sanity check; the jailed build's InitializeAsync hook populates
    // g_gameCtrlCache and we can borrow it. Production binpatch installs
    // do not have the cache populated.
    if (!gameCtrl) gameCtrl = g_gameCtrlCache;

    if (!gameCtrl) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] OnMatchEndAsync mode=%s self=%p ct=%p: "
                  @"GameController unresolved. Skipping KIF emission.",
                  modeName, self, ct]);
        return (UniTaskRet){ NULL, NULL };
    }

    // MatchConfig / GameStateStore discovery: only OnlinePvPMode keeps
    // either as a field on `self`. For every other mode we'd be reading
    // sibling fields at +0x28 / +0x38 — leave them NULL. As a courtesy
    // let the Tweak side share its caches if both builds happen to be
    // loaded (same A/B story as g_gameCtrlCache above).
    void *matchConfig = NULL;
    void *stateStore = NULL;
    if (mode_index == KIOU_BINPATCH_MODE_ONLINEPVP && ptrLooksValid(self)) {
        matchConfig = readPtr(self, ONLINEPVPMODE_OFF_MATCHCONFIG);
        stateStore  = readPtr(self, ONLINEPVPMODE_OFF_STATE_STORE_PATCHED);
    }
    if (!matchConfig) matchConfig = g_matchConfigCache;
    if (!stateStore)  stateStore  = g_stateStoreCache;

    file_log([NSString stringWithFormat:
              @"[BINPATCH] OnMatchEndAsync mode=%s self=%p ct=%p "
              @"gameCtrl=%p matchConfig=%p stateStore=%p — emitting KIF",
              modeName, self, ct, gameCtrl, matchConfig, stateStore]);

    NSString *path = kif_writer_emit_for_match_end(gameCtrl, matchConfig,
                                                    stateStore, modeName);
    if (path) {
        file_log([NSString stringWithFormat:
                  @"[BINPATCH] %s emitted -> %@", modeName, path]);
    }

    // Return value is irrelevant — the cave throws it away before
    // returning to the il2cpp caller. Zero it out for shape correctness.
    return (UniTaskRet){ NULL, NULL };
}
