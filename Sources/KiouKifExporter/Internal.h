#pragma once

#import <Foundation/Foundation.h>
#import <stdint.h>
#import <stdbool.h>

#import "kiou_il2cpp.h"
#import "kiou_hookengine.h"
#import "kiou_logging.h"

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
// Read-only contract: this tweak does NOT mutate il2cpp memory. The shared
// header kiou_il2cpp.h is intentionally read-only, and we do not add any
// write helpers here. If a future phase needs to fill KIFWriteOptions
// fields for time-stamped KIF output, those write helpers go in this header
// behind an explicit opt-in.
// ===========================================================================

#ifndef KIOU_KIF_EXPORTER_COMMIT
#define KIOU_KIF_EXPORTER_COMMIT "unknown"
#endif

// ---------------------------------------------------------------------------
// KIOU_HOOK_SLOT_RVA — RVA (relative to UnityFramework's mach_header) of the
// 8-byte slot in __DATA,__bss that patch_unity.py reserves for us. Our
// constructor writes &kif_binpatch_OnMatchEndAsync into this slot. The cave
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
NSString *kif_writer_emit_for_match_end(void *gameCtrl, const char *matchModeTag);

// ---------------------------------------------------------------------------
// kif_binpatch_OnMatchEndAsync — binpatch-mode entry point.
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
extern UniTaskRet kif_binpatch_OnMatchEndAsync(void *self, void *ct,
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
// Read the full game-record text via GameController.GetKifuText. Returns
// nil on any failure. Implementation in Helpers.m (resolves the
// NativeFunction once and caches the pointer).
// ---------------------------------------------------------------------------
NSString *kifTextFromGameController(void *gameCtrl);

// Read the first segment of the start position from GameController for use
// as the {startpos} filename slot. Picks one of:
//   "startpos"     — initial position
//   "sfen-<hash>"  — handicap / custom starting SFEN (hashed to keep names short)
//   "unknown"      — couldn't read anything
// Implementation in Helpers.m.
NSString *kif_describe_startpos(void *gameCtrl);
