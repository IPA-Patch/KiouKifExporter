#import "kiou_logging.h"
#import <os/log.h>

// ===========================================================================
// kiou_logging.m — implementation backing kiou_logging.h.
//
// Three destinations on every file_log():
//   * NSLog              — Console.app, always on
//   * os_log             — unified logging, subsystem-scoped
//   * g_logSandbox file  — NSTemporaryDirectory()/<tag>.log, append-only
//
// `<tag>` is the short tag derived from the subsystem (last dot segment),
// e.g. "kioukifexporter".log. Resolves under the host app's sandbox:
//   /var/mobile/Containers/Data/Application/<UUID>/tmp/<tag>.log
//
// The sandbox file write is best-effort and silently swallows exceptions
// so a flaky filesystem can't take down the host process.
// ===========================================================================

static os_log_t  g_log        = NULL;
static NSString *g_logSandbox = nil;
static NSString *g_tag        = @"kiou";

static void file_log_path(NSString *path, NSString *msg) {
    if (!path) return;
    @try {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [df stringFromDate:[NSDate date]], msg];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [line writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    } @catch (NSException *e) {}
}

void file_log(NSString *msg) {
    NSLog(@"[%@] %@", g_tag, msg);
    if (g_log) {
        os_log(g_log, "%{public}s", msg.UTF8String);
    }
    if (g_logSandbox) file_log_path(g_logSandbox, msg);
}

void logging_init(const char *subsystem) {
    if (!subsystem) return;

    g_log = os_log_create(subsystem, "tweak");

    // Derive a short tag (e.g. "kioueditor") from the last dot-separated
    // segment of the subsystem. The tag is reused for the sandbox log
    // filename so multiple tweaks loaded into the same process don't
    // clobber each other's files.
    NSString *sub = [NSString stringWithUTF8String:subsystem];
    NSArray *parts = [sub componentsSeparatedByString:@"."];
    if (parts.count > 0) {
        NSString *last = [parts lastObject];
        if (last.length > 0) g_tag = last;
    }

    NSString *filename = [g_tag stringByAppendingString:@".log"];
    g_logSandbox = [NSTemporaryDirectory()
                    stringByAppendingPathComponent:filename];
}
