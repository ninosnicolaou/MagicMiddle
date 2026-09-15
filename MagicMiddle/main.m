#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#include <stdint.h>
#include <stdbool.h>

// This app intentionally uses Apple's private MultitouchSupport framework.
// macOS does not expose Magic Mouse touch coordinates through a public API.
// The framework is loaded dynamically so the app can fail gracefully if Apple changes it.

typedef const void *MTDeviceRef;
typedef uint32_t MTTouchState;

typedef struct { float x; float y; } MMPoint;
typedef struct { MMPoint position; MMPoint velocity; } MMVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    MTTouchState state;
    int32_t fingerID;
    int32_t handID;
    MMVector normalizedVector;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MMVector absoluteVector;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MMTouch;

typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, void (*)(MTDeviceRef, MMTouch[], size_t, double, size_t));
typedef int (*MTDeviceStartFn)(MTDeviceRef, int);
typedef int (*MTDeviceStopFn)(MTDeviceRef);
typedef bool (*MTDeviceIsBuiltInFn)(MTDeviceRef);
typedef int (*MTDeviceGetFamilyIDFn)(MTDeviceRef, int *);
typedef int (*MTDeviceGetDriverTypeFn)(MTDeviceRef, int *);
typedef int (*MTDeviceGetSensorSurfaceDimensionsFn)(MTDeviceRef, int *, int *);
typedef int (*MTDeviceGetActualTypeFn)(MTDeviceRef, int *);

static void *gMTHandle = NULL;
static MTDeviceCreateListFn gCreateList = NULL;
static MTRegisterContactFrameCallbackFn gRegisterCallback = NULL;
static MTDeviceStartFn gStart = NULL;
static MTDeviceStopFn gStop = NULL;
static MTDeviceIsBuiltInFn gIsBuiltIn = NULL;
static MTDeviceGetFamilyIDFn gFamilyID = NULL;
static MTDeviceGetDriverTypeFn gDriverType = NULL;
static MTDeviceGetSensorSurfaceDimensionsFn gSurfaceDims = NULL;
static MTDeviceGetActualTypeFn gActualType = NULL;
static MTDeviceRef gMouse = NULL;

static volatile bool gTouchActive = false;
static volatile float gTouchX = 0.5f;
static volatile float gTouchY = 0.5f;
static volatile bool gTouchIsCenter = false;
static volatile uint64_t gTouchGeneration = 0;
static uint64_t gConsumedGeneration = 0;
static bool gMiddleButtonDown = false;
static CFMachPortRef gEventTap = NULL;
static CFRunLoopSourceRef gEventTapSource = NULL;

// Center sensitivity is a single setting from 1 (narrow) to 5 (wide).
// The setting controls a centered rectangle; higher sensitivity means a larger
// area counts as "center". It is persisted with NSUserDefaults.
static volatile float gCenterHalfWidth = 0.15f;
static volatile float gCenterHalfHeight = 0.25f;

static void setCenterSensitivity(int level) {
    if (level < 1) level = 1;
    if (level > 5) level = 5;
    // Horizontal/vertical half-widths. Level 3 matches the original 30% x 50% zone.
    static const float widths[]  = { 0.10f, 0.125f, 0.15f, 0.20f, 0.25f };
    static const float heights[] = { 0.18f, 0.22f, 0.25f, 0.35f, 0.42f };
    gCenterHalfWidth = widths[level - 1];
    gCenterHalfHeight = heights[level - 1];
}

static bool isCenter(float x, float y) {
    return x >= (0.5f - gCenterHalfWidth) && x <= (0.5f + gCenterHalfWidth) &&
           y >= (0.5f - gCenterHalfHeight) && y <= (0.5f + gCenterHalfHeight);
}

static void touchFrame(MTDeviceRef device, MMTouch touches[], size_t numTouches, double timestamp, size_t frame) {
    (void)device; (void)timestamp; (void)frame;
    if (numTouches == 0) {
        gTouchActive = false;
        gTouchIsCenter = false;
        return;
    }

    // Only one finger is considered. This app has exactly one gesture: physical
    // click while the finger is in the center of the Magic Mouse.
    const MMTouch *t = &touches[0];
    if (t->state == 4 || t->state == 3) { // touching / makeTouch
        gTouchX = t->normalizedVector.position.x;
        gTouchY = t->normalizedVector.position.y;
        gTouchActive = true;
        gTouchIsCenter = isCenter(gTouchX, gTouchY);
        gTouchGeneration++;
    } else if (t->state == 5 || t->state == 7) { // break / out
        gTouchActive = false;
        gTouchIsCenter = false;
    }
}

static bool loadMultitouch(void) {
    const char *path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
    gMTHandle = dlopen(path, RTLD_NOW);
    if (!gMTHandle) return false;

    gCreateList = (MTDeviceCreateListFn)dlsym(gMTHandle, "MTDeviceCreateList");
    if (!gCreateList) return false;
    gRegisterCallback = (MTRegisterContactFrameCallbackFn)dlsym(gMTHandle, "MTRegisterContactFrameCallback");
    if (!gRegisterCallback) return false;
    gStart = (MTDeviceStartFn)dlsym(gMTHandle, "MTDeviceStart");
    if (!gStart) return false;
    gStop = (MTDeviceStopFn)dlsym(gMTHandle, "MTDeviceStop");
    if (!gStop) return false;

    gIsBuiltIn = (MTDeviceIsBuiltInFn)dlsym(gMTHandle, "MTDeviceIsBuiltIn");
    gFamilyID = (MTDeviceGetFamilyIDFn)dlsym(gMTHandle, "MTDeviceGetFamilyID");
    gDriverType = (MTDeviceGetDriverTypeFn)dlsym(gMTHandle, "MTDeviceGetDriverType");
    gSurfaceDims = (MTDeviceGetSensorSurfaceDimensionsFn)dlsym(gMTHandle, "MTDeviceGetSensorSurfaceDimensions");
    gActualType = (MTDeviceGetActualTypeFn)dlsym(gMTHandle, "MTDeviceGetActualType");
    return true;
}

static bool looksLikeMagicMouse(MTDeviceRef device) {
    if (gIsBuiltIn && gIsBuiltIn(device)) return false;

    int family = -1, driver = -1, actual = -1, w = 0, h = 0;
    if (gFamilyID) gFamilyID(device, &family);
    if (gDriverType) gDriverType(device, &driver);
    if (gActualType) gActualType(device, &actual);
    if (gSurfaceDims) gSurfaceDims(device, &w, &h);

    // First-generation Magic Mouse has long been identified by these values.
    // Family 112 / driver type 4 is also used by Magic Mouse hardware.
    if ((family == 112 && (driver == -1 || driver == 4)) ||
        (w == 5152 && h == 9056)) {
        return true;
    }

    // If the device is external, has a touch surface, and looks like a mouse
    // driver, accept it. This covers newer Magic Mouse revisions where Apple's
    // private identifiers have changed.
    if (driver == 4 && w > 0 && h > 0) return true;
    (void)actual;
    return false;
}

static bool startMagicMouse(void) {
    if (!loadMultitouch()) return false;
    CFArrayRef list = gCreateList();
    if (!list) return false;

    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        MTDeviceRef d = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        if (looksLikeMagicMouse(d)) {
            gMouse = d;
            CFRetain((CFTypeRef)gMouse);
            break;
        }
    }
    CFRelease(list);
    if (!gMouse) return false;

    gRegisterCallback(gMouse, touchFrame);
    if (gStart(gMouse, 0) != 0) return false;
    return true;
}

static void postMiddleClick(CGPoint point, CGEventRef original) {
    CGEventSourceRef source = CGEventCreateSourceFromEvent(original);
    if (!source) source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    CGEventRef down = CGEventCreateMouseEvent(source, kCGEventOtherMouseDown, point, kCGMouseButtonCenter);
    CGEventRef up   = CGEventCreateMouseEvent(source, kCGEventOtherMouseUp, point, kCGMouseButtonCenter);
    if (down && up) {
        CGEventSetIntegerValueField(down, kCGMouseEventClickState, 1);
        CGEventSetIntegerValueField(up, kCGMouseEventClickState, 1);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
    if (source) CFRelease(source);
}

static CGEventRef eventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }

    if (type == kCGEventLeftMouseDown) {
        // The Magic Mouse generates its ordinary left-click event after the
        // physical click. If a center touch is active, consume that left click
        // and replace it with a true middle-button click.
        if (gTouchActive && gTouchIsCenter && !gMiddleButtonDown && gConsumedGeneration != gTouchGeneration) {
            gMiddleButtonDown = true;
            gConsumedGeneration = gTouchGeneration;
            CGPoint p = CGEventGetLocation(event);
            postMiddleClick(p, event);
            return NULL;
        }
    }

    if (type == kCGEventLeftMouseUp && gMiddleButtonDown) {
        gMiddleButtonDown = false;
        return NULL;
    }

    return event;
}

static bool installEventTap(void) {
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp);
    gEventTap = CGEventTapCreate(kCGHIDEventTap,
                                 kCGHeadInsertEventTap,
                                 kCGEventTapOptionDefault,
                                 mask,
                                 eventTapCallback,
                                 NULL);
    if (!gEventTap) return false;
    gEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(gEventTap, true);
    return true;
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSMenuItem *sensitivityItem;
@property(nonatomic, assign) BOOL mouseFound;
@property(nonatomic, assign) BOOL menuBarIconVisible;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;

    self.menuBarIconVisible = [[NSUserDefaults standardUserDefaults] objectForKey:@"ShowMenuBarIcon"] == nil
        ? YES
        : [[NSUserDefaults standardUserDefaults] boolForKey:@"ShowMenuBarIcon"];

    NSInteger savedSensitivity = [[NSUserDefaults standardUserDefaults] integerForKey:@"CenterSensitivity"];
    if (savedSensitivity < 1 || savedSensitivity > 5) savedSensitivity = 3;
    setCenterSensitivity((int)savedSensitivity);

    self.menu = [[NSMenu alloc] initWithTitle:@"Magic Middle"];

    NSMenuItem *sensitivity = [[NSMenuItem alloc] initWithTitle:@"Center Sensitivity" action:nil keyEquivalent:@""];
    self.sensitivityItem = sensitivity;
    NSMenu *sensitivityMenu = [[NSMenu alloc] initWithTitle:@"Center Sensitivity"];
    NSArray<NSString *> *levels = @[ @"1 — Very Narrow", @"2 — Narrow", @"3 — Default", @"4 — Wide", @"5 — Very Wide" ];
    for (NSInteger i = 0; i < levels.count; i++) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:levels[i] action:@selector(setSensitivity:) keyEquivalent:@""];
        item.target = self;
        item.tag = i + 1;
        [sensitivityMenu addItem:item];
    }
    sensitivity.submenu = sensitivityMenu;
    [self.menu addItem:sensitivity];

    NSMenuItem *hide = [[NSMenuItem alloc] initWithTitle:@"Hide Menu Bar Icon" action:@selector(toggleMenuBarIcon:) keyEquivalent:@""];
    hide.target = self;
    hide.tag = 0;
    [self.menu addItem:hide];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About Magic Middle" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [self.menu addItem:about];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"];
    quit.target = self;
    [self.menu addItem:quit];

    if (self.menuBarIconVisible) [self createStatusItem];
    [self updateSensitivityChecks];

    self.mouseFound = startMagicMouse();
    BOOL tapOK = installEventTap();

    if (!tapOK) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Accessibility permission required";
        a.informativeText = @"Enable this app in System Settings → Privacy & Security → Accessibility, then relaunch it.";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

- (void)createStatusItem {
    if (self.statusItem) return;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    if (@available(macOS 11.0, *)) {
        self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"computermouse" accessibilityDescription:@"Magic Middle"];
    }
    if (!self.statusItem.button.image) self.statusItem.button.title = @"MM";
    self.statusItem.menu = self.menu;
}

- (void)removeStatusItem {
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}

- (void)updateSensitivityChecks {
    NSInteger current = [[NSUserDefaults standardUserDefaults] integerForKey:@"CenterSensitivity"];
    if (current < 1 || current > 5) current = 3;
    for (NSMenuItem *item in self.sensitivityItem.submenu.itemArray) {
        item.state = (item.tag == current) ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)setSensitivity:(NSMenuItem *)sender {
    NSInteger level = sender.tag;
    if (level < 1 || level > 5) return;
    [[NSUserDefaults standardUserDefaults] setInteger:level forKey:@"CenterSensitivity"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    setCenterSensitivity((int)level);
    [self updateSensitivityChecks];
}

- (void)toggleMenuBarIcon:(NSMenuItem *)sender {
    (void)sender;
    self.menuBarIconVisible = !self.menuBarIconVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.menuBarIconVisible forKey:@"ShowMenuBarIcon"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    if (self.menuBarIconVisible) {
        [self createStatusItem];
    } else {
        [self removeStatusItem];
    }
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Magic Middle";
    a.informativeText = self.mouseFound
        ? @"Running. Physically click the Magic Mouse while your finger is in the center area to send a real middle click.\n\nNo other gestures are changed."
        : @"The app is running, but a Magic Mouse was not detected. Connect your Magic Mouse and relaunch the app.";
    [a addButtonWithTitle:@"OK"];
    [a runModal];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    if (gMouse && gStop) gStop(gMouse);
    if (gMouse) { CFRelease((CFTypeRef)gMouse); gMouse = NULL; }
    if (gEventTapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), gEventTapSource, kCFRunLoopCommonModes); CFRelease(gEventTapSource); gEventTapSource = NULL; }
    if (gEventTap) { CGEventTapEnable(gEventTap, false); CFRelease(gEventTap); gEventTap = NULL; }
    if (gMTHandle) { dlclose(gMTHandle); gMTHandle = NULL; }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
