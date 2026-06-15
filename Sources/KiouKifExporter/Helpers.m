#import "Internal.h"

#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

// ===========================================================================
// kif_trace_log — KIF_TRACE-gated wrapper around file_log.
//
// Diagnostic logging inside kif_fill_write_options (the KIFWriteOptions
// fill path) is verbose enough that we don't want it in release builds.
// Pass `-DKIF_TRACE=1` to the compiler (Makefile honors `TRACE=1`) when
// you need to see every pointer the fill walks and every slot it writes.
//
// Implemented as a do-while macro so it's a statement that compiles to
// nothing in release builds.
// ===========================================================================
#if defined(KIF_TRACE) && KIF_TRACE
  #define kif_trace_log(fmt, ...)                                          \
      file_log([NSString stringWithFormat:(fmt), ##__VA_ARGS__])
#else
  #define kif_trace_log(fmt, ...) do { (void)(fmt); } while (0)
#endif

// ===========================================================================
// Helpers.m — small utilities for the KIF export path.
//
//   * kif_iso8601_basic_utc_now           — filename timestamp
//   * kif_sanitize_filename_segment       — make user-supplied strings safe
//   * kif_ensure_output_dir               — create Documents/KiouKifExporter/
//   * kifTextFromGameController           — full KIF 2.0 via KIFWriter.Write
//   * kif_describe_startpos               — pick "startpos"/"sfen-<hash>"/"unknown"
//
// kifTextFromGameController is the bridge into il2cpp — everything else is
// pure Foundation.
//
// Background: GameController.GetKifuText (RVA 0x5D43D10) returns an in-app
// SUMMARY ("001 ☗ ☗３八飛 … まで、☖後手の勝ち（詰み）"), NOT the standard
// KIF 2.0 that desktop kifu viewers expect. We instead run the canonical
// pipeline KIOU uses internally:
//
//     GetUSIText(self)                       → "position startpos moves ..."
//          ↓
//     USIParser.ParseUSI(usiString)          → RecordManager*
//          ↓
//     [NSMutableData dataWithLength:KIFWRITEOPTIONS_SIZE]
//                                            → opts*  (raw zeroed buffer)
//          ↓
//     KIFWriteOptions..ctor() on opts        → fields stay zero (the ctor itself
//                                              just runs the il2cpp init; it sets
//                                              no field to a non-zero value)
//          ↓
//     kif_fill_write_options(opts, ...)      → best-effort write of:
//                                                StartDateTime  (unconditional)
//                                                MatchTitle     (unconditional)
//                                                EndingLabel    (from GameController.Reason)
//                                                BlackPlayerName / WhitePlayerName
//                                                               (from stateStore RP /
//                                                                MatchConfig fallback —
//                                                                NULL on partial failure)
//                                                TimeRuleLabel  (from MatchConfig — skipped
//                                                                when no MatchConfig)
//          ↓
//     KIFWriter.Write(record, opts)          → standard KIF 2.0 string
//
// Verified on-device with packages/frida/hook_kiou_kifwriter_probe.js — the
// raw-allocated KIFWriteOptions buffer is accepted because KIFWriter.Write
// only reads through non-virtual auto-property getters. No il2cpp_object_new
// or class-from-name plumbing required. The only field intentionally never
// touched by the fill is ThinkingTimesMicros (per-move clock, queued for v0.4).
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11). Same source of truth as KiouUsiProxy.
// ---------------------------------------------------------------------------
#define RVA_GAMECTRL_GET_USI_TEXT   0x5D44074  // string GameController.GetUSIText(this)
#define RVA_POSITION_TO_SFEN        0x5D44374  // string Position.ToSFEN(this)
#define RVA_USIPARSER_PARSE_USI     0x5D572B4  // static RecordManager USIParser.ParseUSI(string)
#define RVA_KIFWRITEOPTIONS_CTOR    0x5D53960  // void KIFWriteOptions..ctor(this)
#define RVA_KIFWRITER_WRITE         0x5D53968  // static string KIFWriter.Write(RecordManager, KIFWriteOptions)

// KIFWriteOptions instance size needed for the raw-buffer trick. See the
// KIFOPTS_OFF_* constants in Internal.h for the field map. Last field
// (EndingLabel) sits at 0x48, ends at 0x50; we pad to 0x60 for headroom.
#define KIFWRITEOPTIONS_SIZE        0x60

// Project.ShogiCore.GameController -> private WinReason <Reason>k__BackingField at +0x30
// (dump.cs L1484318). The enum is a 4-byte int.
#define GC_OFF_WIN_REASON           0x30

// Project.Game.Logic.MatchConfig field offsets (dump.cs L1418061+).
#define MC_OFF_BLACK_PLAYER         0x18  // PlayerInfo*
#define MC_OFF_WHITE_PLAYER         0x20  // PlayerInfo*
#define MC_OFF_TIME_CONTROL         0x28  // TimeControlConfig*

// Project.Game.Logic.PlayerInfo -> Name at +0x18 (dump.cs L1419145+).
#define PI_OFF_NAME                 0x18

// Project.Game.Logic.GameStateStore field offsets (dump.cs L1422268+).
// _blackPlayerInfo / _whitePlayerInfo are ReactiveProperty<PlayerInfo>*.
// During friend matches MatchConfig.Black/WhitePlayer.Name stays the
// "プレイヤー" placeholder until peer-info arrives; the GameStateStore
// reactive properties get updated then, so they carry the real names by
// the time OnMatchEndAsync fires.
#define GSS_OFF_BLACK_PLAYER_INFO   0x50  // ReactiveProperty<PlayerInfo>*
#define GSS_OFF_WHITE_PLAYER_INFO   0x58  // ReactiveProperty<PlayerInfo>*

// Each IMatchMode subclass stores its GameStateStore at a per-mode
// offset. We currently only walk this for OnlinePvPMode (the only mode
// where MatchConfig is initialized to placeholders and the real names
// arrive over the wire).
#define ONLINEPVPMODE_OFF_STATE_STORE  0x28  // GameStateStore*

// ReactiveProperty<T> currentValue offset. dump.cs lists every generic
// instantiation as "offset 0x0", so this had to be probed at runtime —
// captured from live OnlinePvPMode friend matches on KIOU 1.0.1 build 11
// against the actual ReactiveProperty<PlayerInfo> instances in
// GameStateStore. (The probe at PR-time tried 0x10..0x38; only +0x20
// resolved to a PlayerInfo whose Name was not the "プレイヤー"
// placeholder.)
#define RP_OFF_CURRENT_VALUE        0x20  // T currentValue

// Project.Game.Logic.TimeControlConfig (dump.cs L1419538+).
#define TC_OFF_TIME_SECONDS         0x10  // float
#define TC_OFF_BYOYOMI              0x14  // float
#define TC_OFF_INCREMENT            0x18  // float

// System.DateTime kind flag (see DateTime struct in dump.cs L37391+).
//   _dateData = ticks | (kind << 62)
//   kind == 0b01 => Utc
#define DOTNET_DATETIME_KIND_UTC    0x4000000000000000ULL
// Ticks at 1970-01-01 00:00:00 UTC (UnixEpochTicks).
#define DOTNET_DATETIME_UNIX_EPOCH_TICKS 621355968000000000LL
// 1 second = 10,000,000 ticks.
#define DOTNET_DATETIME_TICKS_PER_SECOND 10000000LL

// GameController -> List<Position> _positionHistory at +0x10.
// List<T>        -> T[] _items at +0x10, int32 _size at +0x18.
// T[]            -> first element at +0x20, refs 8-byte spaced.
#define GC_OFF_POSITION_HISTORY     0x10
#define LIST_OFF_ITEMS              0x10
#define LIST_OFF_SIZE               0x18
#define ARRAY_OFF_ELEMS             0x20

typedef void *(*GameCtrl_GetUSIText_t)(void *gameCtrl);
typedef void *(*USIParser_ParseUSI_t)(void *usiString);
typedef void  (*KIFWriteOptions_Ctor_t)(void *opts);
typedef void *(*KIFWriter_Write_t)(void *record, void *opts);
typedef void *(*Position_ToSFEN_t)(void *position);

static GameCtrl_GetUSIText_t   g_GetUSIText      = NULL;
static USIParser_ParseUSI_t    g_ParseUSI        = NULL;
static KIFWriteOptions_Ctor_t  g_KIFOpts_Ctor    = NULL;
static KIFWriter_Write_t       g_KIFWriter_Write = NULL;
static Position_ToSFEN_t       g_PositionToSFEN  = NULL;

// Resolve the il2cpp NativeFunction pointers we use. Idempotent and cheap;
// safe to call once per export call.
static void resolveIl2cppFunctions(void) {
    if (g_unityBase == 0) return;
    if (!g_GetUSIText) {
        g_GetUSIText = (GameCtrl_GetUSIText_t)
            (void *)(g_unityBase + RVA_GAMECTRL_GET_USI_TEXT);
    }
    if (!g_ParseUSI) {
        g_ParseUSI = (USIParser_ParseUSI_t)
            (void *)(g_unityBase + RVA_USIPARSER_PARSE_USI);
    }
    if (!g_KIFOpts_Ctor) {
        g_KIFOpts_Ctor = (KIFWriteOptions_Ctor_t)
            (void *)(g_unityBase + RVA_KIFWRITEOPTIONS_CTOR);
    }
    if (!g_KIFWriter_Write) {
        g_KIFWriter_Write = (KIFWriter_Write_t)
            (void *)(g_unityBase + RVA_KIFWRITER_WRITE);
    }
    if (!g_PositionToSFEN) {
        g_PositionToSFEN = (Position_ToSFEN_t)
            (void *)(g_unityBase + RVA_POSITION_TO_SFEN);
    }
}

// ---------------------------------------------------------------------------
// kifTextFromGameController
//
// Run the full GetUSIText → ParseUSI → KIFWriteOptions..ctor →
// kif_fill_write_options → KIFWriter.Write pipeline and return the
// resulting KIF 2.0 string. Returns nil on any failure (NULL receiver,
// USI text empty, ParseUSI gave back NULL, KIFWriter.Write threw, …).
//
// `matchConfig` / `stateStore` may be NULL; the corresponding KIF
// slots stay empty in that case (StartDateTime, MatchTitle and
// EndingLabel still get filled regardless).
//
// MethodInfo* trailing arg is NULL throughout — il2cpp tolerates this for
// instance accessors and static methods in KIOU. Confirmed by Frida probe
// (packages/frida/hook_kiou_kifwriter_probe.js).
// ---------------------------------------------------------------------------
NSString *kifTextFromGameController(void *gameCtrl,
                                    void *matchConfig,
                                    void *stateStore,
                                    const char *matchModeTag) {
    resolveIl2cppFunctions();
    if (!g_GetUSIText || !g_ParseUSI || !g_KIFOpts_Ctor || !g_KIFWriter_Write) {
        return nil;
    }
    if (!ptrLooksValid(gameCtrl)) return nil;

    // Step 1: GetUSIText(self) → "position startpos moves 2g2f 1c1d ..."
    void *usiStrPtr = NULL;
    @try {
        usiStrPtr = g_GetUSIText(gameCtrl);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[KIF] GetUSIText threw: %@", e]);
        return nil;
    }
    if (!ptrLooksValid(usiStrPtr)) {
        file_log(@"[KIF] GetUSIText returned null il2cpp string");
        return nil;
    }

    // Step 2: USIParser.ParseUSI(usiStr) → RecordManager*
    void *recordPtr = NULL;
    @try {
        recordPtr = g_ParseUSI(usiStrPtr);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[KIF] ParseUSI threw: %@", e]);
        return nil;
    }
    if (!ptrLooksValid(recordPtr)) {
        file_log(@"[KIF] ParseUSI returned null RecordManager");
        return nil;
    }

    // Step 3: KIFWriteOptions instance via raw-buffer trick.
    //
    // We don't have il2cpp_object_new wired up, but the Frida probe
    // confirmed that KIFWriter.Write only reads through non-virtual auto-
    // property getters — so we can hand it a zero-initialized buffer that
    // .ctor() has run on. The il2cpp object header (klass + monitor) at
    // 0x00..0x0F stays NULL; nothing in KIFWriter.Write dereferences it.
    //
    // We use NSMutableData (over a raw malloc) so ARC cleans up
    // automatically when this function returns — and even if KIFWriter
    // somehow stashed a reference to the options object, the autoreleased
    // NSData keeps the storage alive through the autorelease pool drain.
    NSMutableData *optsBuf = [NSMutableData dataWithLength:KIFWRITEOPTIONS_SIZE];
    void *opts = optsBuf.mutableBytes;
    @try {
        g_KIFOpts_Ctor(opts);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[KIF] KIFWriteOptions.ctor threw: %@", e]);
        return nil;
    }

    // Step 3.5: fill the user-visible KIFWriteOptions fields. Safe to call
    // unconditionally — internal failures fall back to leaving the
    // specific field unset, which matches the pre-Phase-3 behavior.
    kif_fill_write_options(opts, matchConfig, stateStore, gameCtrl, matchModeTag);

    // Step 4: KIFWriter.Write(record, opts) → KIF 2.0 string
    void *kifStrPtr = NULL;
    @try {
        kifStrPtr = g_KIFWriter_Write(recordPtr, opts);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[KIF] KIFWriter.Write threw: %@", e]);
        return nil;
    }
    if (!ptrLooksValid(kifStrPtr)) {
        file_log(@"[KIF] KIFWriter.Write returned null");
        return nil;
    }

    return il2cppStringToNSString(kifStrPtr);
}

// ---------------------------------------------------------------------------
// kif_describe_startpos
//
// Look at the GameController's PositionHistory[0] — that's the starting
// position the match was set up from. Convert to SFEN; if it equals the
// standard initial SFEN, return "startpos". Otherwise hash the SFEN and
// return "sfen-<8 hex>" so the filename stays short.
// ---------------------------------------------------------------------------
NSString *kif_describe_startpos(void *gameCtrl) {
    resolveIl2cppFunctions();
    if (!g_PositionToSFEN) return @"unknown";
    if (!ptrLooksValid(gameCtrl)) return @"unknown";

    void *list = readPtr(gameCtrl, GC_OFF_POSITION_HISTORY);
    if (!list) return @"unknown";
    void *items = readPtr(list, LIST_OFF_ITEMS);
    int32_t size = readI32(list, LIST_OFF_SIZE);
    if (size <= 0 || size > 4096 || !ptrLooksValid(items)) return @"unknown";

    void *posPtr = readPtr(items, ARRAY_OFF_ELEMS + 0 * 8);
    if (!posPtr) return @"unknown";

    NSString *sfen = nil;
    @try {
        void *strPtr = g_PositionToSFEN(posPtr);
        sfen = il2cppStringToNSString(strPtr);
    } @catch (NSException *e) {
        return @"unknown";
    }
    if (sfen.length == 0) return @"unknown";

    // Standard initial SFEN — strip the move counter (last token) before
    // comparing since some Position writers include it and some don't.
    static NSString *const kInitialSfenPrefix =
        @"lnsgkgsnl/1r5b1/ppppppppp/9/9/9/PPPPPPPPP/1B5R1/LNSGKGSNL b -";
    if ([sfen hasPrefix:kInitialSfenPrefix]) return @"startpos";

    // Non-standard start — hash to keep filenames short.
    NSData *data = [sfen dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"sfen-%02x%02x%02x%02x",
            digest[0], digest[1], digest[2], digest[3]];
}

// ---------------------------------------------------------------------------
// kif_iso8601_basic_utc_now
//
// Format the current wall clock as "YYYYMMDDTHHMMSS" (UTC). No separators
// other than the ISO 'T' so the result is safe to drop into a POSIX
// filename and sorts lexicographically.
// ---------------------------------------------------------------------------
NSString *kif_iso8601_basic_utc_now(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];
        fmt.dateFormat = @"yyyyMMdd'T'HHmmss";
    });
    return [fmt stringFromDate:[NSDate date]];
}

// ---------------------------------------------------------------------------
// kif_sanitize_filename_segment
//
// Keep [A-Za-z0-9_.-], replace anything else with '_'. Truncate to
// `maxChars` code units (NSString length, which is fine — we're already
// only writing ASCII at this point). Falls back to @"unknown" for empty.
// ---------------------------------------------------------------------------
NSString *kif_sanitize_filename_segment(NSString *s, NSUInteger maxChars) {
    if (s.length == 0) return @"unknown";
    NSMutableString *out = [NSMutableString stringWithCapacity:s.length];
    NSCharacterSet *safe = [NSCharacterSet characterSetWithCharactersInString:
        @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-"];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < 128 && [safe characterIsMember:c]) {
            [out appendFormat:@"%C", c];
        } else {
            [out appendString:@"_"];
        }
    }
    if (out.length == 0) return @"unknown";
    if (out.length > maxChars) {
        return [out substringToIndex:maxChars];
    }
    return [out copy];
}

// ---------------------------------------------------------------------------
// il2cpp_str_new
//
// dlsym the runtime's il2cpp_string_new export the first time we need it
// and cache the function pointer. Returns NULL on:
//   - dlsym failure (extremely unlikely — UnityFramework is loaded by the
//     time Hook_MatchModeObserve.m runs, and il2cpp_string_new is a
//     stable export)
//   - utf8 == NULL or empty (KIFWriter.Write treats null fields as
//     "not present" which is what we want anyway)
//
// The returned il2cpp string is owned by the il2cpp runtime. See the
// Internal.h declaration of il2cpp_str_new for the GC lifetime caveat —
// the string is NOT rooted, and we rely on the conservative Boehm GC
// scanning the live stacks during the synchronous KIFWriter.Write to
// keep it alive. That's an implementation assumption, not a contract.
// ---------------------------------------------------------------------------
typedef void *(*il2cpp_string_new_t)(const char *str);

void *il2cpp_str_new(const char *utf8) {
    if (!utf8 || !*utf8) return NULL;
    static il2cpp_string_new_t fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (il2cpp_string_new_t)dlsym(RTLD_DEFAULT, "il2cpp_string_new");
        if (!fn) {
            file_log(@"[KIF] dlsym(il2cpp_string_new) returned NULL — "
                     @"string KIFWriteOptions fields will be left empty");
        }
    });
    if (!fn) return NULL;
    void *result = NULL;
    @try {
        result = fn(utf8);
    } @catch (NSException *e) {
        file_log([NSString stringWithFormat:
                  @"[KIF] il2cpp_string_new threw: %@", e]);
        return NULL;
    }
    return result;
}

// ---------------------------------------------------------------------------
// kif_winreason_label
//
// Translate WinReason enum value -> short Japanese label string suitable for
// the KIF EndingLabel column. Mirrors the wording KIOU uses in its own KIF
// summary text (GameController.GetKifuText: "詰み" / "千日手" / "持将棋" /
// "入玉宣言"). For WinReason.None we return nil (= leave the field empty,
// matches the in-app behavior when no terminal result is set).
//
// WinReason values (dump.cs L1484293):
//   0 None            -> nil
//   1 Checkmate       -> "詰み"
//   2 PerpetualCheck  -> "連続王手の千日手"
//   3 EnteringKing    -> "入玉宣言"
//   4 Stalemate       -> "ステイルメイト"
// ---------------------------------------------------------------------------
static NSString *kif_winreason_label(int32_t reason) {
    switch (reason) {
        case 0: return nil;
        case 1: return @"詰み";
        case 2: return @"連続王手の千日手";
        case 3: return @"入玉宣言";
        case 4: return @"ステイルメイト";
        default:
            return [NSString stringWithFormat:@"WinReason(%d)", (int)reason];
    }
}

// ---------------------------------------------------------------------------
// kif_build_time_rule_label
//
// Format TimeControlConfig fields as a short, KIF-friendly time rule label:
//
//   持時間 / 秒読み / フィッシャー の有無で書き分け
//
//   時間+秒読み のみ           : "10分 秒読み30秒"
//   時間+フィッシャー (秒)     : "10分 フィッシャー5秒"
//   時間+秒読み+フィッシャー   : "10分 秒読み30秒 フィッシャー5秒"
//   秒読みのみ                  : "秒読み30秒"
//   全部ゼロ (KIOU の "無制限") : "無制限"
//
// `tc` is a TimeControlConfig*; may be NULL — returns nil so caller skips
// the assignment.
// ---------------------------------------------------------------------------
static NSString *kif_build_time_rule_label(void *tc) {
    if (!ptrLooksValid(tc)) return nil;
    // Read three floats. ARC doesn't help us here — these are raw memcpy's.
    float timeSec = 0.0f, byoyomi = 0.0f, increment = 0.0f;
    memcpy(&timeSec,   (char *)tc + TC_OFF_TIME_SECONDS, sizeof(float));
    memcpy(&byoyomi,   (char *)tc + TC_OFF_BYOYOMI,      sizeof(float));
    memcpy(&increment, (char *)tc + TC_OFF_INCREMENT,    sizeof(float));

    if (timeSec <= 0.0f && byoyomi <= 0.0f && increment <= 0.0f) {
        return @"無制限";
    }
    NSMutableString *out = [NSMutableString string];
    if (timeSec > 0.0f) {
        int minutes = (int)(timeSec / 60.0f);
        int seconds = (int)timeSec - minutes * 60;
        if (seconds > 0) {
            [out appendFormat:@"%d分%d秒", minutes, seconds];
        } else {
            [out appendFormat:@"%d分", minutes];
        }
    }
    if (byoyomi > 0.0f) {
        if (out.length > 0) [out appendString:@" "];
        [out appendFormat:@"秒読み%d秒", (int)byoyomi];
    }
    if (increment > 0.0f) {
        if (out.length > 0) [out appendString:@" "];
        [out appendFormat:@"フィッシャー%d秒", (int)increment];
    }
    return out.length > 0 ? [out copy] : nil;
}

// ---------------------------------------------------------------------------
// kif_fill_write_options
//
// Write the five user-visible KIFWriteOptions fields directly into `opts`.
// `opts` MUST be a buffer that g_KIFOpts_Ctor() has already run on.
//
// We deliberately use direct field stores (not the C# setters):
//   * the buffer is not on the il2cpp managed heap (no klass header), so
//     a GC barrier is meaningless against it
//   * KIFWriter.Write reads exclusively through non-virtual auto-property
//     getters that just load the backing field — verified by the Frida
//     probe (packages/frida/hook_kiou_kifwriter_probe.js)
//   * direct stores avoid the AAPCS dance for the 16-byte Nullable<DateTime>
//     value-type setter (would be x1+x2 register pair)
//
// Field-by-field semantics:
//   BlackPlayerName / WhitePlayerName  : borrowed il2cpp string from
//       MatchConfig -> PlayerInfo -> Name. Skipped if matchConfig is NULL,
//       or if Name is NULL/empty.
//   StartDateTime  : Nullable<DateTime>(UnixEpoch + ticksFromWallClock),
//       Kind=Utc. Always written.
//   MatchTitle     : "{mode} @ {iso8601}" — synthesized via il2cpp_string_new.
//   TimeRuleLabel  : kif_build_time_rule_label(tc) via il2cpp_string_new.
//   EndingLabel    : kif_winreason_label(reason) via il2cpp_string_new.
//
// On any partial failure (dlsym(il2cpp_string_new) absent, MatchConfig
// NULL, etc.) we leave that specific field alone and KIFWriter.Write
// emits a blank slot for it — same as before this phase.
//
// KNOWN GC LIFETIME LIMITATION
// ----------------------------
// `opts` is not a managed object (klass header is NULL — see
// Helpers.m's raw-buffer trick). il2cpp's GC therefore does not
// treat the il2cpp string pointers we store at offsets 0x10 / 0x18 /
// 0x30 / 0x38 / 0x48 as roots. The strings remain live across
// KIFWriter.Write only because Unity's Boehm conservative GC scans
// the running threads' stacks for pointer-shaped values, and the
// call is short enough (microseconds) that a GC pass during it is
// extremely unlikely. This is acceptable for the current synchronous
// path but is NOT a contract. If a future change makes the call
// asynchronous, threaded, or moves it onto a path that allocates
// aggressively, switch to either:
//   - allocating a real managed KIFWriteOptions via il2cpp_object_new
//     (the fields become GC-traced), or
//   - rooting each string with il2cpp_gchandle_new for the duration
//     of KIFWriter.Write and releasing the handles afterwards.
// ---------------------------------------------------------------------------
void kif_fill_write_options(void *opts,
                            void *matchConfig,
                            void *stateStore,
                            void *gameCtrl,
                            const char *matchModeTag) {
    if (!opts) {
        kif_trace_log(@"[FILL] opts=NULL — skipping fill entirely");
        return;
    }

    kif_trace_log(@"[FILL] enter opts=%p matchConfig=%p stateStore=%p "
                  @"gameCtrl=%p mode=%s",
                  opts, matchConfig, stateStore, gameCtrl,
                  matchModeTag ? matchModeTag : "(null)");

    char *base = (char *)opts;

    // ----- StartDateTime: always written (does not depend on matchConfig)
    //
    // Encode the current wall clock as .NET ticks since 0001-01-01 and OR
    // in the UTC kind flag. Nullable<DateTime> layout is:
    //   { bool hasValue @+0; uint8 pad[7]; ulong _dateData @+8; }
    //   total 16 bytes.
    NSTimeInterval epochSeconds = [[NSDate date] timeIntervalSince1970];
    int64_t ticks =
        DOTNET_DATETIME_UNIX_EPOCH_TICKS +
        (int64_t)(epochSeconds * (double)DOTNET_DATETIME_TICKS_PER_SECOND);
    uint64_t dateData =
        ((uint64_t)ticks) | DOTNET_DATETIME_KIND_UTC;
    char *sdt = base + KIFOPTS_OFF_START_DATETIME;
    memset(sdt, 0, 16);             // clear padding
    *(uint8_t *)(sdt + 0) = 1;      // hasValue = true
    memcpy(sdt + 8, &dateData, sizeof(uint64_t));
    kif_trace_log(@"[FILL] StartDateTime ticks=%lld dateData=0x%016llx",
                  (long long)ticks, (unsigned long long)dateData);

    // ----- BlackPlayerName / WhitePlayerName
    //
    // Source order (first match wins, per slot):
    //   1. GameStateStore.<Black|White>PlayerInfo.currentValue.Name
    //      — populated once peer info arrives during a friend / online
    //      match. THIS is where the real names live.
    //   2. MatchConfig.<Black|White>Player.Name
    //      — for AI / local matches, MatchConfig carries the names from
    //      the start. For OnlinePvPMode friend matches it stays at the
    //      "プレイヤー" placeholder for the whole lifetime, so falling
    //      back to it gives a blank-looking KIF; we still take it when
    //      stateStore is missing so AI/local don't regress.
    void *blackNameStr = NULL;
    void *whiteNameStr = NULL;

    if (ptrLooksValid(stateStore)) {
        void *blackRP =
            readPtr(stateStore, GSS_OFF_BLACK_PLAYER_INFO);
        void *whiteRP =
            readPtr(stateStore, GSS_OFF_WHITE_PLAYER_INFO);
        kif_trace_log(@"[FILL] gss=%p +0x%x blackRP=%p +0x%x whiteRP=%p",
                      stateStore,
                      GSS_OFF_BLACK_PLAYER_INFO, blackRP,
                      GSS_OFF_WHITE_PLAYER_INFO, whiteRP);
        if (ptrLooksValid(blackRP)) {
            void *blackPI = readPtr(blackRP, RP_OFF_CURRENT_VALUE);
            if (ptrLooksValid(blackPI)) {
                blackNameStr = readPtr(blackPI, PI_OFF_NAME);
                kif_trace_log(@"[FILL] blackRP +0x%x -> PI=%p +0x%x "
                              @"-> Name=%p (preview=%@)",
                              RP_OFF_CURRENT_VALUE, blackPI, PI_OFF_NAME,
                              blackNameStr,
                              il2cppStringToNSString(blackNameStr)
                                  ?: @"(null/not-il2cpp-str)");
            }
        }
        if (ptrLooksValid(whiteRP)) {
            void *whitePI = readPtr(whiteRP, RP_OFF_CURRENT_VALUE);
            if (ptrLooksValid(whitePI)) {
                whiteNameStr = readPtr(whitePI, PI_OFF_NAME);
                kif_trace_log(@"[FILL] whiteRP +0x%x -> PI=%p +0x%x "
                              @"-> Name=%p (preview=%@)",
                              RP_OFF_CURRENT_VALUE, whitePI, PI_OFF_NAME,
                              whiteNameStr,
                              il2cppStringToNSString(whiteNameStr)
                                  ?: @"(null/not-il2cpp-str)");
            }
        }
    }

    // Fallback to MatchConfig if the GameStateStore path didn't yield a
    // pointer. (AI / local match modes still rely on this path.)
    if (!ptrLooksValid(blackNameStr) && ptrLooksValid(matchConfig)) {
        void *black = readPtr(matchConfig, MC_OFF_BLACK_PLAYER);
        if (ptrLooksValid(black)) {
            blackNameStr = readPtr(black, PI_OFF_NAME);
            kif_trace_log(@"[FILL] fallback cfg+0x%x BlackPlayer=%p "
                          @"+0x%x Name=%p (preview=%@)",
                          MC_OFF_BLACK_PLAYER, black, PI_OFF_NAME,
                          blackNameStr,
                          il2cppStringToNSString(blackNameStr)
                              ?: @"(null/not-il2cpp-str)");
        }
    }
    if (!ptrLooksValid(whiteNameStr) && ptrLooksValid(matchConfig)) {
        void *white = readPtr(matchConfig, MC_OFF_WHITE_PLAYER);
        if (ptrLooksValid(white)) {
            whiteNameStr = readPtr(white, PI_OFF_NAME);
            kif_trace_log(@"[FILL] fallback cfg+0x%x WhitePlayer=%p "
                          @"+0x%x Name=%p (preview=%@)",
                          MC_OFF_WHITE_PLAYER, white, PI_OFF_NAME,
                          whiteNameStr,
                          il2cppStringToNSString(whiteNameStr)
                              ?: @"(null/not-il2cpp-str)");
        }
    }

    if (ptrLooksValid(blackNameStr)) {
        memcpy(base + KIFOPTS_OFF_BLACK_PLAYER_NAME,
               &blackNameStr, sizeof(void *));
        kif_trace_log(@"[FILL] wrote BlackPlayerName=%p @opts+0x%x",
                      blackNameStr, KIFOPTS_OFF_BLACK_PLAYER_NAME);
    }
    if (ptrLooksValid(whiteNameStr)) {
        memcpy(base + KIFOPTS_OFF_WHITE_PLAYER_NAME,
               &whiteNameStr, sizeof(void *));
        kif_trace_log(@"[FILL] wrote WhitePlayerName=%p @opts+0x%x",
                      whiteNameStr, KIFOPTS_OFF_WHITE_PLAYER_NAME);
    }

    // ----- MatchTitle: "{mode} @ {iso8601}" via il2cpp_string_new.
    {
        NSString *iso = kif_iso8601_basic_utc_now();
        NSString *title = [NSString stringWithFormat:@"%s @ %@",
                           matchModeTag ? matchModeTag : "unknown", iso];
        void *titleStr =
            il2cpp_str_new(title.UTF8String);
        kif_trace_log(@"[FILL] MatchTitle il2cpp_string_new(\"%@\") = %p",
                      title, titleStr);
        if (titleStr) {
            memcpy(base + KIFOPTS_OFF_MATCH_TITLE,
                   &titleStr, sizeof(void *));
        }
    }

    // ----- TimeRuleLabel: format from MatchConfig.TimeControl (skip if no cfg).
    if (ptrLooksValid(matchConfig)) {
        void *tc = readPtr(matchConfig, MC_OFF_TIME_CONTROL);
        NSString *label = kif_build_time_rule_label(tc);
        kif_trace_log(@"[FILL] cfg=%p +0x%x TimeControl=%p label=%@",
                      matchConfig, MC_OFF_TIME_CONTROL, tc,
                      label ?: @"(nil)");
        if (label) {
            void *labelStr = il2cpp_str_new(label.UTF8String);
            if (labelStr) {
                memcpy(base + KIFOPTS_OFF_TIME_RULE_LABEL,
                       &labelStr, sizeof(void *));
            }
        }
    }

    // ----- EndingLabel: from GameController.<Reason>k__BackingField (WinReason).
    if (ptrLooksValid(gameCtrl)) {
        int32_t reason = readI32(gameCtrl, GC_OFF_WIN_REASON);
        NSString *label = kif_winreason_label(reason);
        kif_trace_log(@"[FILL] gc=%p +0x%x WinReason=%d label=%@",
                      gameCtrl, GC_OFF_WIN_REASON, (int)reason,
                      label ?: @"(nil — none/unset)");
        if (label) {
            void *labelStr = il2cpp_str_new(label.UTF8String);
            if (labelStr) {
                memcpy(base + KIFOPTS_OFF_ENDING_LABEL,
                       &labelStr, sizeof(void *));
            }
        }
    } else {
        kif_trace_log(@"[FILL] gameCtrl=%p invalid — EndingLabel left empty",
                      gameCtrl);
    }

    // Final dump: show every slot we tried to fill, as 8-byte hex.
    kif_trace_log(@"[FILL] FINAL opts dump:\n"
                  @"        +0x10 (Black) = 0x%016llx\n"
                  @"        +0x18 (White) = 0x%016llx\n"
                  @"        +0x20 (StartDT lo) = 0x%016llx\n"
                  @"        +0x28 (StartDT hi) = 0x%016llx\n"
                  @"        +0x30 (Title) = 0x%016llx\n"
                  @"        +0x38 (TimeRule) = 0x%016llx\n"
                  @"        +0x48 (Ending) = 0x%016llx",
                  *(unsigned long long *)(base + 0x10),
                  *(unsigned long long *)(base + 0x18),
                  *(unsigned long long *)(base + 0x20),
                  *(unsigned long long *)(base + 0x28),
                  *(unsigned long long *)(base + 0x30),
                  *(unsigned long long *)(base + 0x38),
                  *(unsigned long long *)(base + 0x48));
}

// ---------------------------------------------------------------------------
// kif_ensure_output_dir
//
// Returns the absolute path of ~/Documents/KiouKifExporter/, creating it if
// necessary. NSDocumentDirectory resolves to the running app's sandbox
// Documents path — which is the directory the Files app exposes once the
// app's Info.plist has UIFileSharingEnabled (= the bundle has been signed
// by Sideloadly with "Enable File Sharing" or shipped with the key set).
// On jailbreak builds this is /var/mobile/Containers/Data/Application/
// <UUID>/Documents/KiouKifExporter — visible to Filza either way.
//
// Returns nil if NSFileManager refuses to create the directory.
// ---------------------------------------------------------------------------
NSString *kif_ensure_output_dir(void) {
    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                            NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    NSString *docs = paths[0];
    NSString *out = [docs stringByAppendingPathComponent:@"KiouKifExporter"];

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:out isDirectory:&isDir] && isDir) {
        return out;
    }

    NSError *err = nil;
    BOOL ok = [fm createDirectoryAtPath:out
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:&err];
    if (!ok) {
        file_log([NSString stringWithFormat:
                  @"[KIF] mkdir failed at %@: %@", out, err]);
        return nil;
    }
    return out;
}
