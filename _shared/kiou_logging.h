#pragma once

#import <Foundation/Foundation.h>

// ===========================================================================
// kiou_logging.h — NSLog + os_log + sandbox file log destination.
//
// Implementation in kiou_logging.m. Each tweak picks its own os_log subsystem
// at init so console output stays distinguishable when several tweaks are
// loaded into the same process:
//
//   KiouEditor      : "com.neconome.shogi.kioueditor"
//   KiouUSIProxy    : "com.neconome.shogi.kiouusiproxy"
//   KiouKifExporter : "com.neconome.shogi.kioukifexporter"
//
// kiou_logging.m derives a short tag from the subsystem (the last dot-
// separated segment) and prepends it to each NSLog line.
//
// File log destination: NSTemporaryDirectory() + "<basename>.log", where
// the basename comes from the short tag derived above. This is the app
// sandbox's tmp/ directory — readable from host via
// `/var/mobile/Containers/Data/Application/<UUID>/tmp/<basename>.log`.
//
// Why no root-accessible destination: rootless tweaks run as the host app
// (`mobile`), which can't write to `/var/tmp/`. The old API took a second
// `logFile` argument that was meant to be a root-readable mirror; under
// rootless that write always failed (silently swallowed by the
// implementation), so the API has been simplified to drop it.
//
// Calls before logging_init() fall back to NSLog only; the file/os_log
// destinations come up once logging_init() has run.
// ===========================================================================

void file_log(NSString *msg);
void logging_init(const char *subsystem);
