#import "Internal.h"

// ===========================================================================
// Hook_MatchModeObserve — capture every IMatchMode lifecycle entry to know
// when a match ends and to keep a live GameController pointer warm.
//
// Trimmed from KiouUsiProxy's same-named file: only the lifecycle hooks
// remain (InitializeAsync, OnPlayerMoveAsync, OnMatchEndAsync). We don't
// have an inject side, a USI engine, or a WS server, so the rich state
// machinery of the parent isn't needed here.
//
// What we still want:
//
//   * InitializeAsync: latch `g_adapterCache` from the cfg arg so we can
//     reach the GameController (via Adapter -> +0x10) as early as possible.
//     If we miss this, OnPlayerMoveAsync will fill it in instead.
//
//   * OnPlayerMoveAsync: every move flows through one of these per-mode
//     entry points. We don't change behavior — we just refresh the
//     `g_gameCtrlCache` opportunistically. (KiouUsiProxy uses these for
//     route picking; KifExporter uses them as a backup GameController
//     latch in case InitializeAsync's adapter arg was NULL.)
//
//   * OnMatchEndAsync: THE entry point. The moment this fires we call
//     kif_writer_emit_for_match_end on the cached GameController. The
//     write is synchronous (KIF text is a few KB at most) so we don't
//     dispatch off — by the time the original OnMatchEndAsync runs, the
//     file is already on disk.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11). Same source of truth as KiouUsiProxy.
// ---------------------------------------------------------------------------
#define RVA_AI_INIT            0x59E4E0C
#define RVA_CPUSTREAM_INIT     0x59E7B48
#define RVA_LOCAL_INIT         0x59FF7B0
#define RVA_ONLINE_INIT        0x5A00E90
#define RVA_RECORDREPLAY_INIT  0x5A2ADD0

#define RVA_AI_OPM             0x59E5268
#define RVA_CPUSTREAM_OPM      0x59E886C
#define RVA_LOCAL_OPM          0x59FF87C
#define RVA_ONLINE_OPM         0x5A012D8
#define RVA_RECORDREPLAY_OPM   0x5A2B3EC

#define RVA_AI_END             0x59E5958
#define RVA_CPUSTREAM_END      0x59EC818
#define RVA_LOCAL_END          0x59FF8F8
#define RVA_ONLINE_END         0x5A0139C
#define RVA_RECORDREPLAY_END   0x5A2B564

// ShogiGameAdapter -> Project.ShogiCore.GameController field offset.
#define ADAPTER_OFF_GAME_CONTROLLER  0x10

// ---------------------------------------------------------------------------
// Per-mode self caches + the GameController cache. Definitions go here, the
// declarations live in Internal.h.
// ---------------------------------------------------------------------------
void *volatile g_gameCtrlCache         = NULL;
void *volatile g_aiMatchModeCache      = NULL;
void *volatile g_cpuStreamModeCache    = NULL;
void *volatile g_onlineModeCache       = NULL;
void *volatile g_localPvPModeCache     = NULL;
void *volatile g_recordReplayModeCache = NULL;

// ---------------------------------------------------------------------------
// Function pointer types. UniTask return convention is the same as
// KiouUsiProxy — see Internal.h for the gory detail.
// ---------------------------------------------------------------------------
typedef UniTaskRet (*InitializeAsync_t)(void *self, void *cfg, void *stateStore,
                                       void *gameAdapter, void *ct);
typedef UniTaskRet (*OnPlayerMoveAsync_t)(void *self, uint32_t mv, void *ct);
typedef UniTaskRet (*OnMatchEndAsync_t)(void *self, void *ct);

// ---------------------------------------------------------------------------
// Original (untrampolined) function pointers.
// ---------------------------------------------------------------------------
static InitializeAsync_t orig_AI_Init        = NULL;
static InitializeAsync_t orig_CPUStream_Init = NULL;
static InitializeAsync_t orig_Local_Init     = NULL;
static InitializeAsync_t orig_Online_Init    = NULL;
static InitializeAsync_t orig_Replay_Init    = NULL;

static OnPlayerMoveAsync_t orig_AI_OPM        = NULL;
static OnPlayerMoveAsync_t orig_CPUStream_OPM = NULL;
static OnPlayerMoveAsync_t orig_Local_OPM     = NULL;
static OnPlayerMoveAsync_t orig_Online_OPM    = NULL;
static OnPlayerMoveAsync_t orig_Replay_OPM    = NULL;

static OnMatchEndAsync_t orig_AI_End        = NULL;
static OnMatchEndAsync_t orig_CPUStream_End = NULL;
static OnMatchEndAsync_t orig_Local_End     = NULL;
static OnMatchEndAsync_t orig_Online_End    = NULL;
static OnMatchEndAsync_t orig_Replay_End    = NULL;

// First-touch logging counters so the move hook doesn't spam the log file
// every move. Log the first three calls per mode and every 30th after.
static uint32_t g_aiSeen           = 0;
static uint32_t g_cpuStreamSeen    = 0;
static uint32_t g_localPvPSeen     = 0;
static uint32_t g_onlinePMSeen     = 0;
static uint32_t g_recordReplaySeen = 0;

static inline BOOL shouldLog(uint32_t n) {
    return n <= 3 || (n % 30) == 0;
}

// ---------------------------------------------------------------------------
// InitializeAsync hooks. We capture self into the per-mode cache, latch the
// GameController off the adapter arg, then chain to the original.
//
// adapter arg is at position 3 (zero-indexed) of InitializeAsync — see
// dump.cs IMatchMode signature.
// ---------------------------------------------------------------------------
#define DEFINE_INIT_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, ORIG_VAR)                    \
    static UniTaskRet hook_##MODE_LOWER##_Init(void *self, void *cfg,                  \
                                               void *store, void *adapter,             \
                                               void *ct) {                             \
        if ((CACHE_VAR) != self) (CACHE_VAR) = self;                                   \
        if (adapter) {                                                                 \
            void *gc = readPtr(adapter, ADAPTER_OFF_GAME_CONTROLLER);                  \
            if (gc && g_gameCtrlCache != gc) g_gameCtrlCache = gc;                     \
        }                                                                              \
        file_log([NSString stringWithFormat:                                           \
                  @"[MMODE] " MODE_TAG " Init self=%p adapter=%p gameCtrl=%p",         \
                  self, adapter, g_gameCtrlCache]);                                    \
        if (ORIG_VAR) return (ORIG_VAR)(self, cfg, store, adapter, ct);                \
        return (UniTaskRet){ NULL, NULL };                                             \
    }

DEFINE_INIT_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,      orig_AI_Init)
DEFINE_INIT_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,    orig_CPUStream_Init)
DEFINE_INIT_HOOK(local,     "LocalPvPMode",     g_localPvPModeCache,     orig_Local_Init)
DEFINE_INIT_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,       orig_Online_Init)
DEFINE_INIT_HOOK(replay,    "RecordReplayMode", g_recordReplayModeCache, orig_Replay_Init)

#undef DEFINE_INIT_HOOK

// ---------------------------------------------------------------------------
// OnPlayerMoveAsync hooks. These exist purely to keep g_gameCtrlCache warm
// in case InitializeAsync's adapter was NULL (the open-seat modes — LocalPvP
// and RecordReplay — sometimes hand adapter=NULL). We don't read the move
// or read SFEN; KIF text is fetched on-demand at match end.
// ---------------------------------------------------------------------------
#define DEFINE_OPM_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, SEEN_VAR, ORIG_VAR)            \
    static UniTaskRet hook_##MODE_LOWER##_OPM(void *self, uint32_t mv, void *ct) {     \
        if ((CACHE_VAR) != self) (CACHE_VAR) = self;                                   \
        uint32_t n = ++(SEEN_VAR);                                                     \
        if (shouldLog(n)) {                                                            \
            file_log([NSString stringWithFormat:                                       \
                      @"[MMODE] " MODE_TAG " OPM call#%u self=%p move=0x%x",           \
                      n, self, (unsigned)mv]);                                         \
        }                                                                              \
        if (ORIG_VAR) return (ORIG_VAR)(self, mv, ct);                                 \
        return (UniTaskRet){ NULL, NULL };                                             \
    }

DEFINE_OPM_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,
                g_aiSeen,           orig_AI_OPM)
DEFINE_OPM_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,
                g_cpuStreamSeen,    orig_CPUStream_OPM)
DEFINE_OPM_HOOK(local,     "LocalPvPMode",     g_localPvPModeCache,
                g_localPvPSeen,     orig_Local_OPM)
DEFINE_OPM_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,
                g_onlinePMSeen,     orig_Online_OPM)
DEFINE_OPM_HOOK(replay,    "RecordReplayMode", g_recordReplayModeCache,
                g_recordReplaySeen, orig_Replay_OPM)

#undef DEFINE_OPM_HOOK

// ---------------------------------------------------------------------------
// OnMatchEndAsync hooks. Run BEFORE the original so the GameController is
// still alive — once the original returns the cache may be torn down
// asynchronously and PositionHistory becomes unreadable. The KIF text is
// fetched synchronously from kif_writer_emit_for_match_end; the write is
// in the order of microseconds for a normal match so blocking the hook is
// fine.
//
// We do NOT clear g_gameCtrlCache here — the next match's InitializeAsync
// will overwrite it, and it's cheap to leave stale.
// ---------------------------------------------------------------------------
#define DEFINE_END_HOOK(MODE_LOWER, MODE_TAG, CACHE_VAR, ORIG_VAR)                     \
    static UniTaskRet hook_##MODE_LOWER##_End(void *self, void *ct) {                  \
        file_log([NSString stringWithFormat:                                           \
                  @"[MMODE] " MODE_TAG " End self=%p gameCtrl=%p",                     \
                  self, g_gameCtrlCache]);                                             \
        /* Emit the KIF *before* chaining — the cached GameController may */           \
        /* be torn down by the time the original returns. */                           \
        NSString *path = kif_writer_emit_for_match_end(g_gameCtrlCache,                \
                                                       MODE_TAG);                       \
        if (path) {                                                                    \
            file_log([NSString stringWithFormat:                                       \
                      @"[KIF] " MODE_TAG " emitted -> %@", path]);                     \
        }                                                                              \
        (CACHE_VAR) = NULL;                                                            \
        if (ORIG_VAR) return (ORIG_VAR)(self, ct);                                     \
        return (UniTaskRet){ NULL, NULL };                                             \
    }

DEFINE_END_HOOK(ai,        "AIMatchMode",      g_aiMatchModeCache,      orig_AI_End)
DEFINE_END_HOOK(cpustream, "CPUStreamMode",    g_cpuStreamModeCache,    orig_CPUStream_End)
DEFINE_END_HOOK(local,     "LocalPvPMode",     g_localPvPModeCache,     orig_Local_End)
DEFINE_END_HOOK(online,    "OnlinePvPMode",    g_onlineModeCache,       orig_Online_End)
DEFINE_END_HOOK(replay,    "RecordReplayMode", g_recordReplayModeCache, orig_Replay_End)

#undef DEFINE_END_HOOK

// ---------------------------------------------------------------------------
// Installer. Wires up all 15 hooks (5 modes * { Init, OPM, End }).
// ---------------------------------------------------------------------------
void install_MatchModeObserve_hook(uintptr_t unityBase) {
    struct { const char *tag; const char *what; uintptr_t rva;
             void *hook; void **origSlot; } entries[] = {
        // InitializeAsync — primary cache population + adapter -> gameCtrl latch.
        { "AIMatchMode",      "InitializeAsync", RVA_AI_INIT,
          (void *)hook_ai_Init,        (void **)&orig_AI_Init },
        { "CPUStreamMode",    "InitializeAsync", RVA_CPUSTREAM_INIT,
          (void *)hook_cpustream_Init, (void **)&orig_CPUStream_Init },
        { "LocalPvPMode",     "InitializeAsync", RVA_LOCAL_INIT,
          (void *)hook_local_Init,     (void **)&orig_Local_Init },
        { "OnlinePvPMode",    "InitializeAsync", RVA_ONLINE_INIT,
          (void *)hook_online_Init,    (void **)&orig_Online_Init },
        { "RecordReplayMode", "InitializeAsync", RVA_RECORDREPLAY_INIT,
          (void *)hook_replay_Init,    (void **)&orig_Replay_Init },

        // OnPlayerMoveAsync — backup cache refresh, in case adapter was NULL.
        { "AIMatchMode",      "OnPlayerMoveAsync", RVA_AI_OPM,
          (void *)hook_ai_OPM,        (void **)&orig_AI_OPM },
        { "CPUStreamMode",    "OnPlayerMoveAsync", RVA_CPUSTREAM_OPM,
          (void *)hook_cpustream_OPM, (void **)&orig_CPUStream_OPM },
        { "LocalPvPMode",     "OnPlayerMoveAsync", RVA_LOCAL_OPM,
          (void *)hook_local_OPM,     (void **)&orig_Local_OPM },
        { "OnlinePvPMode",    "OnPlayerMoveAsync", RVA_ONLINE_OPM,
          (void *)hook_online_OPM,    (void **)&orig_Online_OPM },
        { "RecordReplayMode", "OnPlayerMoveAsync", RVA_RECORDREPLAY_OPM,
          (void *)hook_replay_OPM,    (void **)&orig_Replay_OPM },

        // OnMatchEndAsync — the KIF emission point.
        { "AIMatchMode",      "OnMatchEndAsync", RVA_AI_END,
          (void *)hook_ai_End,        (void **)&orig_AI_End },
        { "CPUStreamMode",    "OnMatchEndAsync", RVA_CPUSTREAM_END,
          (void *)hook_cpustream_End, (void **)&orig_CPUStream_End },
        { "LocalPvPMode",     "OnMatchEndAsync", RVA_LOCAL_END,
          (void *)hook_local_End,     (void **)&orig_Local_End },
        { "OnlinePvPMode",    "OnMatchEndAsync", RVA_ONLINE_END,
          (void *)hook_online_End,    (void **)&orig_Online_End },
        { "RecordReplayMode", "OnMatchEndAsync", RVA_RECORDREPLAY_END,
          (void *)hook_replay_End,    (void **)&orig_Replay_End },
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        uintptr_t addr = unityBase + entries[i].rva;
        MSHookFunction((void *)addr, entries[i].hook, entries[i].origSlot);
        file_log([NSString stringWithFormat:
                  @"[MMODE] hooked %s.%s @0x%lx (base+0x%lx)",
                  entries[i].tag, entries[i].what,
                  (unsigned long)addr, (unsigned long)entries[i].rva]);
    }
}
