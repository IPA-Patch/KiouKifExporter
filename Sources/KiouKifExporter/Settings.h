#pragma once

#import <Foundation/Foundation.h>

// ===========================================================================
// Settings.h — KiouKifExporter per-mode auto-save toggle (v0.5).
//
// API (Cocoa-style PascalCase C functions, KKE prefix):
//
//   KKESettingsRegisterDefaults()  — call once at constructor time to seed
//       NSUserDefaults so all modes default to ON.
//
//   KKESettingsIsModeEnabled(tag)  — returns YES if KIF auto-save is
//       currently enabled for the given mode tag string
//       (e.g. "OnlinePvPMode"). Always returns YES for unrecognised tags
//       so future modes don't silently suppress output.
//
//   KKEGestureInstall()            — attach a right-edge swipe gesture to
//       the key window. Swiping in from the right edge opens the settings
//       sheet via KKEPresentSettings(). Safe to call multiple times — no-op
//       once already installed.
//
//   KKEPresentSettings()           — present the per-mode toggle sheet
//       directly. Used by the gesture handler; exposed in case another path
//       (e.g. a future debug entry point) wants to trigger it.
// ===========================================================================

// NSUserDefaults key prefix. Each mode's key is KKE_KEY_PREFIX + mode tag.
// E.g. "KKE_save_OnlinePvPMode".
#define KKE_KEY_PREFIX  "KKE_save_"

void KKESettingsRegisterDefaults(void);
BOOL KKESettingsIsModeEnabled(const char *modeTag);
void KKEGestureInstall(void);
void KKEPresentSettings(void);
