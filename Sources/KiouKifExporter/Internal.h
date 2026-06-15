#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

#import "il2cpp.h"
#import "hookengine.h"
#import "logging.h"

// ===========================================================================
// Internal.h — KiouKifExporter-private declarations.
//
// KiouKifExporter is the "save the KIF, do nothing else" sibling of
// KiouUsiProxy. The flow is:
//
//   1. Hook each IMatchMode's InitializeAsync and OnPlayerMoveAsync to latch
//      the live GameController. (Cached on g_gameCtrlCache.)
//   2. Hook each IMatchMode's OnMatchEndAsync. When it fires, we
//      synchronously call Project.ShogiCore.GameController.GetKifuText on
//      the cached self and write the returned NSString to
//      ~/Documents/KiouKifExporter/<ISO8601>_<mode>_<startpos>.kif.
//   3. That's it. No WebSocket, no HTTP, no inject side.
//
// Read-only contract for IL2CPP HEAP: this tweak does NOT mutate live
// il2cpp objects. The shared header il2cpp.h (IPA-Patch/Common) is
// intentionally read-only.
//
// EXCEPTION: KIFWriteOptions. The KIF export path allocates its OWN
// KIFWriteOptions instance via a raw zero buffer (Helpers.m) and then
// fills five string/value fields directly. Those write helpers
// (il2cpp_str_new + the field map below) live here, in the consumer
// tweak's Internal.h, because they are *only* safe against private
// buffers we created — not against live il2cpp objects on the heap.
// Do not lift them into IPA-Patch/Common without that contract attached.
// ===========================================================================

#ifndef KIOU_KIF_EXPORTER_COMMIT
#define KIOU_KIF_EXPORTER_COMMIT "unknown"
#endif

// ---------------------------------------------------------------------------
// KIOU_HOOK_SLOT_RVA — RVA (relative to UnityFramework's mach_header) of the
// 8-byte slot in __DATA,__bss that patch_unity.py reserves for us. Our
// constructor writes &hook_OnMatchEndAsync into this slot. The cave
// emitted by patch_unity.py loads the slot and BLR's whatever pointer is
// there.
//
// Pinned by `tools/patch_unity.py reserve_hook_slot()` against KIOU 1.0.1
// build 11's UnityFramework: 0x8F90CD0 is the tail of __DATA,__bss
// (section va=0x8E76B80, size=0x11A158, so last 8 bytes = 0x8F90CD0). The
// section's whole zero-fill is uninitialized at load time, and dyld
// guarantees __bss pages stay accessible. Re-run reserve_hook_slot() if you
// re-derive against a new UnityFramework build — Phase 1.5e wires that into
// the build pipeline.
// ---------------------------------------------------------------------------
#ifndef KIOU_HOOK_SLOT_RVA
#define KIOU_HOOK_SLOT_RVA 0x8F90CD0
#endif

// ---------------------------------------------------------------------------
// IMatchMode mode index + `_gameAdapter` field offsets (KIOU 1.0.1 build 11).
//
// The cave that patch_unity.py emits hands us a small integer in X2 (the
// third arg slot) identifying which concrete IMatchMode subclass we were
// invoked for. We use it to index a per-mode dispatch table that gives us
// the right `_gameAdapter` field offset on `self`, then read
// `self -> _gameAdapter -> _gameController` to recover the live
// GameController.
//
// Reverse-engineered from dump.cs by the reverse-engineer agent for Phase
// 1.5b. Offsets DIFFER per concrete mode — heuristic resolution (try every
// candidate offset until a valid pointer chain falls out) was tried first
// and crashed in production: at least one mode has a sibling field at one
// of the other modes' adapter offsets, and `ptrLooksValid` lets the wrong
// candidate through. With the cave passing the mode index in X2 there is
// no ambiguity to resolve.
//
// Reference (dump.cs lines from Task A):
//   AIMatchMode      _gameAdapter @ 0x48  (L1419818)
//   CPUStreamMode    _gameAdapter @ 0x50  (L1420397)
//   LocalPvPMode     _gameAdapter @ 0x18  (L1420718)
//   OnlinePvPMode    _gameAdapter @ 0x30  (L1421566)
//   RecordReplayMode _gameAdapter @ 0x18  (L1422104)
//
// **IMPORTANT**: the numeric ordering below MUST stay in sync with
// `_MATCH_END_SITES` in tools/patch_unity.py. The patcher embeds these
// indices as MOVZ X2,#imm in the cave; changing them in only one place
// silently routes the wrong adapter offset on the device.
// ---------------------------------------------------------------------------
typedef enum {
    KIOU_BINPATCH_MODE_AIMATCH      = 0,
    KIOU_BINPATCH_MODE_CPUSTREAM    = 1,
    KIOU_BINPATCH_MODE_LOCALPVP     = 2,
    KIOU_BINPATCH_MODE_ONLINEPVP    = 3,
    KIOU_BINPATCH_MODE_RECORDREPLAY = 4,
    KIOU_BINPATCH_MODE_COUNT        = 5,
} KiouBinpatchMode;

static const uintptr_t kKiouBinpatchAdapterOffsets[KIOU_BINPATCH_MODE_COUNT] = {
    [KIOU_BINPATCH_MODE_AIMATCH]      = 0x48,
    [KIOU_BINPATCH_MODE_CPUSTREAM]    = 0x50,
    [KIOU_BINPATCH_MODE_LOCALPVP]     = 0x18,
    [KIOU_BINPATCH_MODE_ONLINEPVP]    = 0x30,
    [KIOU_BINPATCH_MODE_RECORDREPLAY] = 0x18,
};

static const char *const kKiouBinpatchModeNames[KIOU_BINPATCH_MODE_COUNT] = {
    [KIOU_BINPATCH_MODE_AIMATCH]      = "AIMatchMode",
    [KIOU_BINPATCH_MODE_CPUSTREAM]    = "CPUStreamMode",
    [KIOU_BINPATCH_MODE_LOCALPVP]     = "LocalPvPMode",
    [KIOU_BINPATCH_MODE_ONLINEPVP]    = "OnlinePvPMode",
    [KIOU_BINPATCH_MODE_RECORDREPLAY] = "RecordReplayMode",
};

// ShogiGameAdapter -> Project.ShogiCore.GameController field offset
// (dump.cs L1417785 — confirmed against KiouUsiProxy production usage).
#define KIOU_BINPATCH_ADAPTER_OFF_GAMECTRL 0x10

// ---------------------------------------------------------------------------
// Per-module hook installers. Tweak.m calls each one once UnityFramework has
// shown up; each installer guards itself if invoked twice.
// ---------------------------------------------------------------------------
void install_MatchModeObserve_hook(uintptr_t unityBase);

// UnityFramework base address captured at install time. Exposed so the
// match-end KIF writer path can resolve static il2cpp methods from inside
// a dispatch block that doesn't carry the installer's unityBase on the
// stack.
extern uintptr_t g_unityBase;

// ---------------------------------------------------------------------------
// Live GameController instance, captured from IMatchMode hooks. NULL when
// no match is in progress. Read by Kif_Writer.m to call GetKifuText on the
// right receiver.
//
// `volatile` because the writer runs from whichever thread Unity happens
// to be on, and the reader (match-end path) typically runs from the same
// hook but defensively assumes a different thread.
// ---------------------------------------------------------------------------
extern void *volatile g_gameCtrlCache;        // Project.ShogiCore.GameController*

// Live MatchConfig captured by Hook_MatchModeObserve.m::DEFINE_INIT_HOOK
// (Tweak path) so the match-end KIF writer can read BlackPlayer/WhitePlayer/
// TimeControl off it. The Patched path does NOT use this cache — it pulls
// MatchConfig out of the IMatchMode instance directly when the concrete
// subclass holds it as a field (only OnlinePvPMode does on KIOU 1.0.1
// build 11; the other four pass cfg through InitializeAsync but never
// latch it, so for those modes MatchConfig is NULL and player-name /
// time-rule fields stay empty by design).
extern void *volatile g_matchConfigCache;     // Project.Game.Logic.MatchConfig*

// MatchMode self caches captured by Hook_MatchModeObserve.m. Populated from
// InitializeAsync (early) and confirmed by each OnPlayerMoveAsync hit.
// Cleared from OnMatchEndAsync. KifExporter doesn't actually need these
// (we only call GetKifuText, no per-mode logic), but Hook_MatchModeObserve
// is a near-verbatim port of KiouUsiProxy's, so the caches stay for log
// readability and to keep the diff against the parent minimal.
extern void *volatile g_aiMatchModeCache;     // Project.Game.Logic.AIMatchMode*
extern void *volatile g_cpuStreamModeCache;   // Project.Game.Logic.CPUStreamMode*
extern void *volatile g_onlineModeCache;      // Project.Game.Logic.OnlinePvPMode*
extern void *volatile g_localPvPModeCache;    // Project.Game.Logic.LocalPvPMode*
extern void *volatile g_recordReplayModeCache;// Project.Game.Logic.RecordReplayMode*

// UniTask is a 16-byte struct (IUniTaskSource* + short token, padded). On
// arm64 AAPCS it's returned in the {x0, x1} register pair. Hook trampolines
// that wrap an il2cpp method returning UniTask MUST also return a 16-byte
// struct, otherwise the trampoline writes garbage into x1 and the caller's
// `await` reads through a nonsense pointer the very next instruction.
typedef struct { void *r0; void *r1; } UniTaskRet;

// ---------------------------------------------------------------------------
// Kif_Writer.m — the only thing this tweak is for.
//
// Called from Hook_MatchModeObserve.m::END_HOOK once the match has ended.
// Reads the KIF text off the cached GameController (or the `self` we just
// observed — both work, we use whichever is non-NULL), assembles a
// filename, and writes a UTF-8 KIF file under Documents/KiouKifExporter/.
//
// matchModeTag is a static C string we control:
//   "AIMatchMode" | "CPUStreamMode" | "OnlinePvPMode" | "LocalPvPMode"
//   | "RecordReplayMode" | "unknown"
// Used as the {mode} segment of the filename.
//
// Returns the absolute path of the file we wrote (autoreleased), or nil
// on any failure. Failures are logged but do not throw.
// ---------------------------------------------------------------------------
// matchConfig may be NULL — fields that need it (player names, time rule)
// are simply left empty in that case. See g_matchConfigCache in this header
// for which modes populate it.
NSString *kif_writer_emit_for_match_end(void *gameCtrl,
                                        void *matchConfig,
                                        const char *matchModeTag);

// ---------------------------------------------------------------------------
// hook_OnMatchEndAsync — the Patched-build entry point for OnMatchEndAsync.
//
// Mirrors the Tweak build's `hook_xxx_End` family (Hook_MatchModeObserve.m),
// except that under the Patched build all five concrete IMatchMode subclasses
// funnel through this one symbol — the cave passes `mode_index` so we can
// still discriminate.
//
// Phase 1.5 ships UnityFramework pre-patched: each IMatchMode's
// OnMatchEndAsync prologue is rewritten with `B <cave>`, and the cave (a
// short asm stub appended to the framework by patch_unity.py) loads a
// function pointer out of UnityFramework's reserved __bss slot
// (KIOU_HOOK_SLOT_RVA) and BLR's it. That pointer is exactly this symbol.
//
// Argument convention:
//   x0 = self          (the IMatchMode instance — same as the original il2cpp method)
//   x1 = ct            (CancellationToken)
//   x2 = mode_index    (uint32_t, one of KIOU_BINPATCH_MODE_* — injected by
//                       the cave via MOVZ X2,#imm so we know which concrete
//                       _gameAdapter offset to use without guessing)
//
// The cave saves caller-saved registers and the original args around the
// call, runs the displaced prologue instruction, then jumps back to
// `orig + 4`. So the return value we hand back here is effectively dead —
// the cave overwrites it with whatever the real OnMatchEndAsync produces.
// We still return a zeroed UniTaskRet for shape correctness.
//
// Declared `extern` so the constructor in Tweak.m can take its address
// without a forward-declared static.
// ---------------------------------------------------------------------------
extern UniTaskRet hook_OnMatchEndAsync(void *self, void *ct,
                                       uint32_t mode_index);

// ---------------------------------------------------------------------------
// Helpers.m — small utilities shared across files.
// ---------------------------------------------------------------------------

// "20260614T234500" — UTC, ISO 8601 basic profile, second precision. Used
// as the filename prefix. No subsecond / no separators so the result is
// safe inside a POSIX filename and sorts lexicographically.
NSString *kif_iso8601_basic_utc_now(void);

// Sanitize an arbitrary NSString into a safe filename segment. Strips path
// separators and non-printables, replaces whitespace with underscores, and
// truncates to `maxChars`. Returns @"unknown" for nil / empty.
NSString *kif_sanitize_filename_segment(NSString *s, NSUInteger maxChars);

// Make sure ~/Documents/KiouKifExporter/ exists. Returns the absolute path
// of that directory, or nil if NSFileManager refused to create it.
NSString *kif_ensure_output_dir(void);

// ---------------------------------------------------------------------------
// Run the full GetUSIText → ParseUSI → KIFWriteOptions..ctor →
// kif_fill_write_options → KIFWriter.Write pipeline and return the
// resulting KIF 2.0 string. Returns nil on any failure.
//
// `matchConfig` and `matchModeTag` flow straight through to
// kif_fill_write_options — see Helpers.m for the per-field semantics.
// matchConfig may be NULL; matchModeTag may be NULL (then "unknown"
// shows up in MatchTitle).
// ---------------------------------------------------------------------------
NSString *kifTextFromGameController(void *gameCtrl,
                                    void *matchConfig,
                                    const char *matchModeTag);

// Read the first segment of the start position from GameController for use
// as the {startpos} filename slot. Picks one of:
//   "startpos"     — initial position
//   "sfen-<hash>"  — handicap / custom starting SFEN (hashed to keep names short)
//   "unknown"      — couldn't read anything
// Implementation in Helpers.m.
NSString *kif_describe_startpos(void *gameCtrl);

// ---------------------------------------------------------------------------
// KIFWriteOptions field-fill helpers.
//
// kifTextFromGameController() in Helpers.m walks a private zero-init buffer
// that .ctor() has touched (no klass header). Setters would still work but
// would do a full il2cpp write-barrier round-trip; since the buffer is
// not on the il2cpp heap and `KIFWriter.Write` only reads through non-
// virtual auto-property getters, direct field stores are equivalent and
// cheaper. We use them.
//
// Field map (KIOU 1.0.1 build 11, see KIFWriteOptions in dump.cs):
//   0x10  string             BlackPlayerName
//   0x18  string             WhitePlayerName
//   0x20  Nullable<DateTime> StartDateTime  (16 bytes: bool hasValue +
//                                            padding + DateTime _dateData)
//   0x30  string             MatchTitle
//   0x38  string             TimeRuleLabel
//   0x40  IReadOnlyList<long> ThinkingTimesMicros — left NULL intentionally
//   0x48  string             EndingLabel
#define KIFOPTS_OFF_BLACK_PLAYER_NAME 0x10
#define KIFOPTS_OFF_WHITE_PLAYER_NAME 0x18
#define KIFOPTS_OFF_START_DATETIME    0x20
#define KIFOPTS_OFF_MATCH_TITLE       0x30
#define KIFOPTS_OFF_TIME_RULE_LABEL   0x38
#define KIFOPTS_OFF_ENDING_LABEL      0x48

// Allocate (or look up the cached pointer for) an il2cpp System.String*
// for the given UTF-8 C string. Returns NULL if `il2cpp_string_new` is
// unresolvable via dlsym or if `utf8` is NULL/empty. The returned pointer
// is owned by the il2cpp runtime; do NOT free it. We never retain the
// pointer past the synchronous KIFWriter.Write call so a GC sweep won't
// invalidate it under us.
void *il2cpp_str_new(const char *utf8);

// Fill the five string/value KIFWriteOptions fields on `opts` (a buffer
// produced by KIFWriteOptions..ctor() — see Helpers.m). Reads everything
// it needs out of `matchConfig` (may be NULL — then BlackPlayerName /
// WhitePlayerName / TimeRuleLabel are left untouched) and `gameCtrl`
// (used for the EndingLabel — WinReason enum at GameController +0x30).
// `matchModeTag` is the static C string used to build MatchTitle.
//
// Never throws — every internal failure falls back to leaving the
// specific field unset.
void kif_fill_write_options(void *opts,
                            void *matchConfig,
                            void *gameCtrl,
                            const char *matchModeTag);
