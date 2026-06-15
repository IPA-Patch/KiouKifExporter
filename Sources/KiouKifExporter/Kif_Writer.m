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
                                        const char *matchModeTag) {
    // 1. Get the KIF text.
    NSString *kif = kifTextFromGameController(gameCtrl);
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
