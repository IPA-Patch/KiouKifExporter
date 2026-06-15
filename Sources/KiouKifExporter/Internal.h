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
