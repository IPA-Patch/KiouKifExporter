#import "Internal.h"
#import "Settings.h"

#import <UIKit/UIKit.h>

// ===========================================================================
// Settings.m — per-mode auto-save toggles + right-edge swipe trigger (v0.5).
//
// Design (matches issue #21):
//   * KKESettingsRegisterDefaults(): registers {KKE_save_<mode>: YES}
//     for every known mode so first-launch behaviour is "all on".
//   * KKEGestureInstall(): attaches a UIScreenEdgePanGestureRecognizer to
//     the key window's root view. Swiping in from the right edge presents
//     KKESettingsViewController as a bottom sheet. No floating button; no
//     overlay view needed — the gesture sits on the existing window.
//   * KKESettingsViewController: UITableView with one UISwitch row per mode.
//     Changes are written to NSUserDefaults immediately.
//   * kif_writer_emit_for_match_end() (Kif_Writer.m) calls
//     KKESettingsIsModeEnabled() at the top and returns nil early if
//     the flag is NO for the current mode.
// ===========================================================================

// ---------------------------------------------------------------------------
// Known mode tags (same order as KiouBinpatchMode in Internal.h).
// ---------------------------------------------------------------------------
static NSString * const kModeNames[] = {
    @"AIMatchMode",
    @"CPUStreamMode",
    @"LocalPvPMode",
    @"OnlinePvPMode",
    @"RecordReplayMode",
};
static const NSUInteger kModeCount =
    sizeof(kModeNames) / sizeof(kModeNames[0]);

static NSString *KKEKeyForTag(NSString *tag) {
    return [NSString stringWithFormat:@"%s%@", KKE_KEY_PREFIX, tag];
}

// ---------------------------------------------------------------------------
// KKESettingsRegisterDefaults
//
// Seeds NSUserDefaults so every mode is ON by default. Safe to call more
// than once (registerDefaults: only fills keys that aren't already set).
// ---------------------------------------------------------------------------
void KKESettingsRegisterDefaults(void) {
    NSMutableDictionary *defs = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < kModeCount; i++) {
        defs[KKEKeyForTag(kModeNames[i])] = @YES;
    }
    [[NSUserDefaults standardUserDefaults] registerDefaults:defs];
    file_log(@"[KKE] settings defaults registered (all modes ON)");
}

// ---------------------------------------------------------------------------
// KKESettingsIsModeEnabled
//
// Returns YES when the NSUserDefaults flag for `modeTag` is set (or when
// `modeTag` isn't a known mode tag — unknown modes default to enabled so
// future mode additions don't silently drop output).
// ---------------------------------------------------------------------------
BOOL KKESettingsIsModeEnabled(const char *modeTag) {
    if (!modeTag) return YES;
    NSString *key = KKEKeyForTag(@(modeTag));
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    // objectForKey: returns nil when the key is absent; treat as enabled
    // (matches the registered default of YES).
    id val = [ud objectForKey:key];
    return val == nil ? YES : [ud boolForKey:key];
}

// ---------------------------------------------------------------------------
// KKEKeyWindow — iOS 13+ safe replacement for the deprecated
// [UIApplication sharedApplication].keyWindow. Walks connected
// UIWindowScenes and returns the first key window in a foreground-active
// scene. Falls back to the first visible window if none is marked key.
// Returns nil when called before the app has set up its window hierarchy.
// ---------------------------------------------------------------------------
static UIWindow *KKEKeyWindow(void) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.count > 0) return ws.windows.firstObject;
    }
    return nil;
}

// ===========================================================================
// KKESettingsViewController — the per-mode toggle sheet.
// ===========================================================================
@interface KKESettingsViewController : UITableViewController
@end

@implementation KKESettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"KiouKifExporter";
    [self.tableView registerClass:[UITableViewCell class]
           forCellReuseIdentifier:@"cell"];
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self
        action:@selector(closeButtonTapped)];
    self.navigationItem.rightBarButtonItem = closeBtn;
}

- (void)closeButtonTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)kModeCount;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
        [tv dequeueReusableCellWithIdentifier:@"cell"
                                 forIndexPath:indexPath];
    NSString *tag = kModeNames[(NSUInteger)indexPath.row];
    cell.textLabel.text = tag;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = KKESettingsIsModeEnabled(tag.UTF8String);
    sw.tag = indexPath.row;
    [sw addTarget:self
           action:@selector(switchToggled:)
 forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (NSString *)tableView:(UITableView *)tv
titleForHeaderInSection:(NSInteger)section {
    return @"Auto-save KIF per match mode";
}

- (NSString *)tableView:(UITableView *)tv
titleForFooterInSection:(NSInteger)section {
    return @"When a mode is disabled, no .kif file is written when that "
           @"type of match ends. Settings survive app restart.";
}

- (void)switchToggled:(UISwitch *)sw {
    NSString *tag = kModeNames[(NSUInteger)sw.tag];
    NSString *key = KKEKeyForTag(tag);
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:key];
    file_log([NSString stringWithFormat:
              @"[KKE] %@ auto-save -> %@", tag, sw.on ? @"ON" : @"OFF"]);
}

@end

// ---------------------------------------------------------------------------
// KKEPresentSettings — present the per-mode toggle sheet on top of whatever
// view controller is currently frontmost. Extracted from the gesture
// handler so it can be triggered from any future entry point (debug menu,
// notification action, …) without duplicating sheet-construction logic.
//
// Hops to the main queue, walks down through presentedViewController to
// find the topmost VC, and refuses to stack a second sheet if one is
// already up.
// ---------------------------------------------------------------------------
void KKEPresentSettings(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = KKEKeyWindow().rootViewController;
        while (root.presentedViewController) {
            root = root.presentedViewController;
        }
        if (!root) {
            file_log(@"[KKE] present: no root VC found");
            return;
        }
        // Avoid stacking multiple sheets if the user triggers again while
        // one is already presented.
        if ([root.presentedViewController
                isKindOfClass:[UINavigationController class]]) {
            UINavigationController *existing =
                (UINavigationController *)root.presentedViewController;
            if ([existing.topViewController
                    isKindOfClass:[KKESettingsViewController class]]) {
                return;
            }
        }

        KKESettingsViewController *settings =
            [[KKESettingsViewController alloc]
                initWithStyle:UITableViewStyleInsetGrouped];
        UINavigationController *nav =
            [[UINavigationController alloc]
                initWithRootViewController:settings];

        if (@available(iOS 15.0, *)) {
            UISheetPresentationController *sheet =
                nav.sheetPresentationController;
            if (sheet) {
                sheet.detents = @[
                    [UISheetPresentationControllerDetent mediumDetent],
                    [UISheetPresentationControllerDetent largeDetent],
                ];
                sheet.prefersGrabberVisible = YES;
            }
        }
        [root presentViewController:nav animated:YES completion:nil];
        file_log(@"[KKE] settings sheet presented");
    });
}

// ===========================================================================
// KKEGestureHandler — target for the UIScreenEdgePanGestureRecognizer.
// Kept as a separate NSObject so its lifetime is independent of any VC.
// ===========================================================================
@interface KKEGestureHandler : NSObject
- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gr;
@end

@implementation KKEGestureHandler

- (void)handleEdgePan:(UIScreenEdgePanGestureRecognizer *)gr {
    // Fire on Began only — we don't need to track the drag.
    if (gr.state != UIGestureRecognizerStateBegan) return;
    file_log(@"[KKE] right-edge swipe began -> presenting settings");
    KKEPresentSettings();
}

@end

// ---------------------------------------------------------------------------
// KKEGestureInstall — public entry point called from Tweak.m.
//
// Attaches a UIScreenEdgePanGestureRecognizer (right edge) to the key
// window. The handler object is retained statically so it lives for the
// app's lifetime without needing an owner.
// ---------------------------------------------------------------------------
void KKEGestureInstall(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = KKEKeyWindow();
        if (!win) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(1.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    KKEGestureInstall();
                });
            return;
        }

        // Guard: don't install twice (e.g. if KKEGestureInstall is somehow
        // called a second time after a window recreation).
        for (UIGestureRecognizer *gr in win.gestureRecognizers) {
            if ([gr isKindOfClass:[UIScreenEdgePanGestureRecognizer class]]) {
                UIScreenEdgePanGestureRecognizer *ep =
                    (UIScreenEdgePanGestureRecognizer *)gr;
                if (ep.edges & UIRectEdgeRight) {
                    file_log(@"[KKE] right-edge gesture already installed, skipping");
                    return;
                }
            }
        }

        static KKEGestureHandler *sHandler = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ sHandler = [[KKEGestureHandler alloc] init]; });

        UIScreenEdgePanGestureRecognizer *gr =
            [[UIScreenEdgePanGestureRecognizer alloc]
                initWithTarget:sHandler
                        action:@selector(handleEdgePan:)];
        gr.edges = UIRectEdgeRight;
        // numberOfTouchesRequired defaults to 1 — one finger swipe from the
        // right edge. Keep it at 1 so it's easy to trigger intentionally.
        [win addGestureRecognizer:gr];

        file_log(@"[KKE] right-edge swipe gesture installed on key window");
    });
}
