#import "Internal.h"

#import <CommonCrypto/CommonDigest.h>

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
//     KIFWriteOptions..ctor() on raw buffer  → opts*  (all fields null-init)
//          ↓
//     KIFWriter.Write(record, opts)          → standard KIF 2.0 string
//
// Verified on-device with packages/frida/hook_kiou_kifwriter_probe.js — the
// raw-allocated KIFWriteOptions buffer is accepted because KIFWriter.Write
// only reads through non-virtual auto-property getters. No il2cpp_object_new
// or class-from-name plumbing required.
// ===========================================================================

// ---------------------------------------------------------------------------
// RVAs (KIOU 1.0.1 build 11). Same source of truth as KiouUsiProxy.
// ---------------------------------------------------------------------------
#define RVA_GAMECTRL_GET_USI_TEXT   0x5D44074  // string GameController.GetUSIText(this)
#define RVA_POSITION_TO_SFEN        0x5D44374  // string Position.ToSFEN(this)
#define RVA_USIPARSER_PARSE_USI     0x5D572B4  // static RecordManager USIParser.ParseUSI(string)
#define RVA_KIFWRITEOPTIONS_CTOR    0x5D53960  // void KIFWriteOptions..ctor(this)
#define RVA_KIFWRITER_WRITE         0x5D53968  // static string KIFWriter.Write(RecordManager, KIFWriteOptions)

// KIFWriteOptions instance size needed for the raw-buffer trick. The field
// map (from dump.cs) is:
//   0x00 il2cpp object header (klass + monitor, 16 bytes — we leave it zero)
//   0x10 BlackPlayerName    : string
//   0x18 WhitePlayerName    : string
//   0x20 StartDateTime      : Nullable<DateTime> (16 bytes)
//   0x30 MatchTitle         : string
//   0x38 TimeRuleLabel      : string
//   0x40 ThinkingTimesMicros: IReadOnlyList<long>
//   0x48 EndingLabel        : string
// Last field ends at 0x50. We pad to 0x60 for a little headroom.
#define KIFWRITEOPTIONS_SIZE        0x60

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
// Run the full GetUSIText → ParseUSI → KIFWriteOptions..ctor → KIFWriter.Write
// pipeline and return the resulting KIF 2.0 string. Returns nil on any
// failure (NULL receiver, USI text empty, ParseUSI gave back NULL,
// KIFWriter.Write threw, …).
//
// MethodInfo* trailing arg is NULL throughout — il2cpp tolerates this for
// instance accessors and static methods in KIOU. Confirmed by Frida probe
// (packages/frida/hook_kiou_kifwriter_probe.js).
// ---------------------------------------------------------------------------
NSString *kifTextFromGameController(void *gameCtrl) {
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
