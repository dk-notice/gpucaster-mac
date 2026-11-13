// Gpucaster for macOS: app start-up, window, menus, toolbar and input.
//
// Run with "--selftest <folder>" to render a test scene off-screen, save a
// picture of each stage into the folder, and exit without opening a window.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Renderer.h"
#import "Sidebar.h"
#import "LightControls.h"

#pragma mark - Picture view

// One step of undo history: the whole scene, and which shape it was using.
@interface UndoEntry : NSObject {
@public
    SceneState::Snapshot snapshot;
}
@property (nonatomic, copy) NSString *shape;
@end
@implementation UndoEntry
@end

@interface RenderView : MTKView
@property (nonatomic, weak) Renderer *renderer;
@property (nonatomic, copy) void (^onWillChange)(NSString *name);   // about to move the camera or a light
@property (nonatomic, copy) void (^onLightsMoved)(void);
@end

@implementation RenderView

- (BOOL)acceptsFirstResponder { return YES; }

// Plain keys (G, N, A, ...) are menu shortcuts; offer the key to the menus first.
- (void)keyDown:(NSEvent *)e {
    if (![NSApp.mainMenu performKeyEquivalent:e]) [super keyDown:e];
}

- (void)noteChange:(NSString *)name { if (self.onWillChange) self.onWillChange(name); }
- (void)mouseDown:(NSEvent *)e { [self noteChange:nil]; }
- (void)rightMouseDown:(NSEvent *)e { [self noteChange:nil]; }
- (void)otherMouseDown:(NSEvent *)e { [self noteChange:nil]; }

- (void)mouseDragged:(NSEvent *)e {
    NSEventModifierFlags f = e.modifierFlags;
    [self.renderer dragPrimaryDX:(float)(-e.deltaX / self.bounds.size.width)
                              dy:(float)(e.deltaY / self.bounds.size.height)
                           shift:(f & NSEventModifierFlagShift) != 0
                         control:(f & (NSEventModifierFlagControl | NSEventModifierFlagOption)) != 0];
    if (self.renderer.mouseTarget != -1 && self.onLightsMoved) self.onLightsMoved();
}

- (void)secondaryDrag:(NSEvent *)e {
    [self.renderer dragSecondaryDX:(float)(-e.deltaX / self.bounds.size.width)
                                dy:(float)(e.deltaY / self.bounds.size.height)
                             shift:(e.modifierFlags & NSEventModifierFlagShift) != 0];
}
- (void)rightMouseDragged:(NSEvent *)e { [self secondaryDrag:e]; }
- (void)otherMouseDragged:(NSEvent *)e { [self secondaryDrag:e]; }

- (void)scrollWheel:(NSEvent *)e {
    double amount = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.002 : e.scrollingDeltaY * 0.02;
    if (amount == 0) return;
    [self noteChange:@"zoom"];
    [self.renderer dolly:(float)amount];
}

- (void)magnifyWithEvent:(NSEvent *)e {
    [self noteChange:@"zoom"];
    [self.renderer dolly:(float)(e.magnification * 0.5)];
}

@end

#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate>
@end

@implementation AppDelegate {
    NSWindow *_window;
    RenderView *_view;
    Renderer *_renderer;
    Sidebar *_sidebar;
    NSPopUpButton *_shapePopup;
    NSArray *_shapePopupPaths;      // what the pop-up currently lists (NSNull = dividing line)
    NSButton *_runButton;           // Pause / Resume / Refine More
    NSProgressIndicator *_progress;
    NSTextField *_status;
    NSTimer *_timer;
    NSString *_shownError;

    // Undo
    NSMutableArray<UndoEntry *> *_undo, *_redo;
    NSString *_lastChangeName;       // for treating one slider drag as one step
    CFTimeInterval _lastChangeTime;

    // Large image export
    Renderer *_exporter;             // builds the big picture; nil when not exporting
    NSString *_exportPath;
    NSPanel *_exportSheet;
    NSProgressIndicator *_exportBar;
    NSTextField *_exportLabel;
    BOOL _exportCancelled;
    BOOL _pausedBeforeExport;
    double _exportTiles;             // tiles per slice, tuned as it goes
    CFTimeInterval _exportStart;

    // Recent lightings, newest first
    std::vector<Lighting> _history;
    BOOL _historyDirty;
    BOOL _wasFinished;
    int _tickCount;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"This Mac has no Metal-capable graphics device.";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }

    _renderer = [[Renderer alloc] initWithDevice:device];

    NSRect frame = NSMakeRect(0, 0, 1280, 760);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Gpucaster";
    _window.releasedWhenClosed = NO;
    _window.minSize = NSMakeSize(700, 420);

    _view = [[RenderView alloc] initWithFrame:frame device:device];
    _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    _view.clearColor = MTLClearColorMake(0, 0, 0, 1);
    _view.renderer = _renderer;
    _view.delegate = _renderer;
    _view.translatesAutoresizingMaskIntoConstraints = NO;

    _sidebar = [[Sidebar alloc] initWithRenderer:_renderer];
    _sidebar.translatesAutoresizingMaskIntoConstraints = NO;

    _undo = [NSMutableArray array];
    _redo = [NSMutableArray array];

    __weak AppDelegate *weakSelf = self;
    _view.onLightsMoved = ^{ [weakSelf sidebarRefresh]; };
    _view.onWillChange = ^(NSString *name) { [weakSelf checkpoint:name]; };
    _sidebar.willChange = ^(NSString *name) { [weakSelf checkpoint:name]; };
    _sidebar.didRandomizeLighting = ^{ [weakSelf rememberLighting]; };
    _sidebar.onKeepLighting = ^{ [weakSelf rememberLighting]; };
    _sidebar.onPickLighting = ^(NSInteger index) { [weakSelf pickLighting:index]; };
    [self rememberLighting];
    _renderer.onShaderResult = ^(NSString *error) { [weakSelf shaderResult:error]; };

    NSView *bar = [self buildToolbar];

    NSStackView *body = [NSStackView stackViewWithViews:@[_view, _sidebar]];
    body.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    body.spacing = 0;
    body.distribution = NSStackViewDistributionFill;
    body.detachesHiddenViews = YES;
    [_view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_view setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *root = [NSStackView stackViewWithViews:@[bar, body]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical;
    root.spacing = 0;
    root.alignment = NSLayoutAttributeLeading;
    root.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *content = [[NSView alloc] initWithFrame:frame];
    [content addSubview:root];
    _window.contentView = content;
    [NSLayoutConstraint activateConstraints:@[
        [root.topAnchor constraintEqualToAnchor:content.topAnchor],
        [root.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [root.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [root.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [bar.widthAnchor constraintEqualToAnchor:root.widthAnchor],
        [body.widthAnchor constraintEqualToAnchor:root.widthAnchor],
    ]];

    // Diagnostic log (see Sidebar.h): on when the app is run from its source
    // folder, or when GPUCASTER_LOG is set.  Records every mouse press with
    // what it landed on, so problems that need a real mouse can be traced.
    if (getenv("GPUCASTER_LOG") || ![_renderer shapeIsReadOnly:[_renderer.shaderDir stringByAppendingPathComponent:@"gpucaster.metal"]]) {
        GCLogEnable();
        GCLog(@"Gpucaster started; shaders from %@", _renderer.shaderDir);
        [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp)
                                              handler:^NSEvent *(NSEvent *e) {
            AppDelegate *me = weakSelf;
            if (!me) return e;
            NSView *hit = e.window ? [e.window.contentView hitTest:e.locationInWindow] : nil;
            NSString *what = (e.window == me->_window) ? [me->_sidebar describeView:hit]
                                                       : [NSString stringWithFormat:@"%@ in window \"%@\"", NSStringFromClass([hit class]), e.window.title];
            GCLog(@"mouse %@ at (%.0f, %.0f) on %@; key window \"%@\"; first responder %@",
                  e.type == NSEventTypeLeftMouseDown ? @"DOWN" : @"up", e.locationInWindow.x, e.locationInWindow.y, what,
                  NSApp.keyWindow.title, NSStringFromClass([me->_window.firstResponder class]));
            return e;
        }];
    }

    [self buildMenus];
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_view];
    [NSApp activateIgnoringOtherApps:YES];

    _timer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self tick];
    if (_renderer.lastError) [self shaderResult:_renderer.lastError];

    // For testing the layout without a person watching: save a picture of the
    // window's controls after a few seconds, then quit.  (The 3D picture
    // itself is drawn by the graphics card and does not appear in this copy.)
    // For testing the export without a person: GPUCASTER_EXPORT=<file.png>
    // (and optionally GPUCASTER_EXPORT_SCALE=<n>) exports once the window is
    // up, then quits.
    const char *exportTo = getenv("GPUCASTER_EXPORT");
    if (exportTo && *exportTo) {
        NSString *path = [NSString stringWithUTF8String:exportTo];
        int scale = getenv("GPUCASTER_EXPORT_SCALE") ? MAX(1, atoi(getenv("GPUCASTER_EXPORT_SCALE"))) : 2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self startExportWidth:self->_renderer.imageWidth * scale height:self->_renderer.imageHeight * scale path:path];
        });
    }

    // For testing the controls without a person: GPUCASTER_UICHECK=1 exercises
    // every sidebar control a few seconds after launch, prints a report and quits.
    if (getenv("GPUCASTER_UICHECK")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            printf("%s", [self->_sidebar checkControls].UTF8String);
            [NSApp terminate:nil];
        });
    }

    const char *shot = getenv("GPUCASTER_UISHOT");
    if (shot && *shot) {
        NSString *path = [NSString stringWithUTF8String:shot];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSView *content = self->_window.contentView;
            NSBitmapImageRep *rep = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
            [content cacheDisplayInRect:content.bounds toBitmapImageRep:rep];
            // Put the controls on a plain background so the text is readable.
            NSBitmapImageRep *flat = [content bitmapImageRepForCachingDisplayInRect:content.bounds];
            [NSGraphicsContext saveGraphicsState];
            NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:flat];
            [[NSColor colorWithWhite:0.3 alpha:1] setFill];   // mid-grey, so light or dark text both show
            NSRectFill(content.bounds);
            [rep drawInRect:content.bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:NO hints:nil];
            [NSGraphicsContext restoreGraphicsState];
            [[flat representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
            printf("uishot: %s  |  %s\n", path.UTF8String, [self->_renderer statusText].UTF8String);
            [NSApp terminate:nil];
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

#pragma mark - Toolbar

- (NSView *)buildToolbar {
    _shapePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    _shapePopup.target = self;
    _shapePopup.action = @selector(shapePicked:);
    _shapePopup.toolTip = @"The shape being drawn (a file in the shapes folder)";

    _runButton = [NSButton buttonWithTitle:@"Refine More" target:self action:@selector(runButtonClicked:)];
    [_runButton.widthAnchor constraintEqualToConstant:104].active = YES;   // fits the longest title, so nothing jumps
    NSButton *clear = [NSButton buttonWithTitle:@"Restart" target:self action:@selector(clearScene:)];
    clear.toolTip = @"Throw away the picture and start again (C)";

    _progress = [NSProgressIndicator new];
    _progress.style = NSProgressIndicatorStyleBar;
    _progress.indeterminate = NO;
    _progress.minValue = 0;
    _progress.maxValue = 1;
    _progress.controlSize = NSControlSizeSmall;
    [_progress.widthAnchor constraintEqualToConstant:140].active = YES;

    _status = [NSTextField labelWithString:@""];
    _status.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _status.textColor = NSColor.secondaryLabelColor;
    _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [_status setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_status setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bar = [NSStackView stackViewWithViews:@[_shapePopup, _runButton, clear, _progress, _status]];
    bar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bar.spacing = 12;
    bar.edgeInsets = NSEdgeInsetsMake(6, 12, 6, 12);
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    return bar;
}

// Keeps the shape pop-up in step with the files in the shapes folder.
// The shapes to offer: built-in ones, then yours, then (if it is neither) the
// one in use, which was opened from somewhere else.  nil marks a dividing line.
- (NSArray *)shapeListWithDividers {
    NSMutableArray *list = [[_renderer builtInShapes] mutableCopy];
    NSArray<NSString *> *mine = [_renderer userShapes];
    if (mine.count) {
        [list addObject:[NSNull null]];
        [list addObjectsFromArray:mine];
    }
    NSString *current = _renderer.shapePath;
    if (current && ![list containsObject:current]) {
        [list addObject:[NSNull null]];
        [list addObject:current];
    }
    return list;
}

// Keeps the shape pop-up in step with the shape folders.
- (void)refreshShapePopup {
    NSArray *list = [self shapeListWithDividers];
    if (![list isEqualToArray:_shapePopupPaths]) {
        _shapePopupPaths = list;
        [_shapePopup removeAllItems];
        for (id entry in list) {
            if (entry == [NSNull null]) {
                [_shapePopup.menu addItem:[NSMenuItem separatorItem]];
                continue;
            }
            [_shapePopup addItemWithTitle:@""];   // (titles set below, so duplicates are allowed)
            _shapePopup.lastItem.title = [Renderer displayNameForShape:entry];
            _shapePopup.lastItem.representedObject = entry;
        }
    }
    NSString *current = _renderer.shapePath;
    NSInteger index = current ? [_shapePopup indexOfItemWithRepresentedObject:current] : -1;
    if (index >= 0 && _shapePopup.indexOfSelectedItem != index) [_shapePopup selectItemAtIndex:index];
}

- (void)tick {
    [_renderer reloadShadersIfFilesChanged];
    [self refreshShapePopup];
    [_sidebar syncShapeParams];
    if (!_sidebar.hidden) [_sidebar syncLights];
    _status.stringValue = [_renderer statusText];

    // One button: pause while working, resume when paused, refine when finished.
    BOOL finished = _renderer.finished;
    if (_renderer.paused) {
        _runButton.title = @"Resume";
        _runButton.toolTip = @"Carry on from where it paused (Space)";
    } else if (finished) {
        _runButton.title = @"Refine More";
        _runButton.toolTip = @"Add more shading passes for a smoother picture";
    } else {
        _runButton.title = @"Pause";
        _runButton.toolTip = @"Hold the work without losing it (Space)";
    }
    double p = _renderer.progress;
    _progress.hidden = (p < 0 || finished);
    if (p >= 0) _progress.doubleValue = p;

    // Keep the little lighting pictures up to date: straight away when the
    // list changes or the picture finishes, and now and then while it builds.
    _tickCount++;
    if (!_sidebar.hidden && (_historyDirty || (finished && !_wasFinished) || (!finished && _tickCount % 8 == 0))) {
        [_sidebar setLightingHistory:[_renderer thumbnailsForLightings:_history width:126]];
        _historyDirty = NO;
    }
    _wasFinished = finished;
}

#pragma mark - Undo and lighting history

- (UndoEntry *)currentEntry {
    UndoEntry *e = [UndoEntry new];
    e->snapshot = _renderer.scene->GetSnapshot();
    e.shape = _renderer.shapePath;
    return e;
}

// Records the scene as it is now, just before something changes it.  Repeated
// changes with the same name in quick succession (dragging one slider) count
// as a single step.
- (void)checkpoint:(NSString *)name {
    CFTimeInterval now = CACurrentMediaTime();
    BOOL sameAsLast = name && [name isEqualToString:_lastChangeName] && (now - _lastChangeTime) < 1.0;
    _lastChangeName = name;
    _lastChangeTime = now;
    if (sameAsLast) return;
    [_undo addObject:[self currentEntry]];
    if (_undo.count > 200) [_undo removeObjectAtIndex:0];
    [_redo removeAllObjects];
}

- (void)applyEntry:(UndoEntry *)e {
    SceneState::Change change = _renderer.scene->RestoreSnapshot(e->snapshot);
    BOOL shapeChanged = e.shape && ![e.shape isEqualToString:_renderer.shapePath];
    if (change == SceneState::NewSeed) [_renderer sceneReplaced];
    if (shapeChanged) [_renderer selectShape:e.shape keepParamValues:YES];
    else if (change == SceneState::PictureRestart) [_renderer clearAll];
    else if (change == SceneState::LightingOnly) [_renderer relight];
    _lastChangeName = nil;
    [_sidebar refresh];
    [self tick];
}

- (BOOL)entry:(UndoEntry *)a matches:(UndoEntry *)b {
    BOOL sameShape = (a.shape == b.shape) || [a.shape isEqualToString:b.shape];
    return sameShape && SceneState::SameScene(a->snapshot, b->snapshot);
}

// Steps back (or forward) to the nearest recorded state that differs from
// now.  Records that turned out to change nothing - a click on the picture
// that didn't move the camera, say - are skipped.
- (void)stepFrom:(NSMutableArray<UndoEntry *> *)from to:(NSMutableArray<UndoEntry *> *)to {
    UndoEntry *now = [self currentEntry];
    while (from.count > 0) {
        UndoEntry *e = from.lastObject;
        [from removeLastObject];
        if ([self entry:e matches:now]) continue;
        [to addObject:now];
        [self applyEntry:e];
        return;
    }
}

- (void)undo:(id)sender { [self stepFrom:_undo to:_redo]; }
- (void)redo:(id)sender { [self stepFrom:_redo to:_undo]; }

// Adds the current lighting to the front of the recent list.
- (void)rememberLighting {
    _history.insert(_history.begin(), _renderer.scene->GetLighting());
    if (_history.size() > 12) _history.resize(12);
    _historyDirty = YES;
}

- (void)pickLighting:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_history.size()) return;
    [self checkpoint:nil];
    _renderer.scene->SetLighting(_history[(size_t)index]);
    [_renderer relight];
    [_sidebar refresh];
}

- (void)sidebarRefresh { [_sidebar refresh]; }

#pragma mark - Menus

- (NSMenuItem *)add:(NSString *)title to:(NSMenu *)menu action:(SEL)action key:(NSString *)key mods:(NSEventModifierFlags)mods {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:key];
    item.keyEquivalentModifierMask = mods;
    item.target = self;
    return item;
}

static NSString *FunctionKey(unichar c) { return [NSString stringWithCharacters:&c length:1]; }

- (void)buildMenus {
    const NSEventModifierFlags none = 0, cmd = NSEventModifierFlagCommand, shift = NSEventModifierFlagShift,
                               ctrl = NSEventModifierFlagControl;
    NSMenu *bar = [NSMenu new];

    // App menu
    NSMenu *app = [NSMenu new];
    [app addItemWithTitle:@"About Gpucaster" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [app addItem:[NSMenuItem separatorItem]];
    [app addItemWithTitle:@"Hide Gpucaster" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:@"Quit Gpucaster" action:@selector(terminate:) keyEquivalent:@"q"];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = app;

    // File
    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [self add:@"Open Scene…" to:file action:@selector(openScene:) key:@"o" mods:cmd];
    [self add:@"Import Lighting from Scene…" to:file action:@selector(importLights:) key:@"o" mods:cmd | shift];
    [self add:@"Save Scene…" to:file action:@selector(saveScene:) key:@"s" mods:cmd | shift];
    [file addItem:[NSMenuItem separatorItem]];
    [self add:@"Save Image…" to:file action:@selector(saveImage:) key:@"s" mods:cmd];
    [self add:@"Export Large Image…" to:file action:@selector(exportLargeImage:) key:@"e" mods:cmd | shift];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = file;

    // Edit
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [self add:@"Undo" to:edit action:@selector(undo:) key:@"z" mods:cmd];
    [self add:@"Redo" to:edit action:@selector(redo:) key:@"z" mods:cmd | shift];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = edit;

    // Shape (the list of shapes at the top is filled in by -menuNeedsUpdate:)
    NSMenu *shape = [[NSMenu alloc] initWithTitle:@"Shape"];
    shape.delegate = self;
    [shape addItem:[NSMenuItem separatorItem]];
    [self add:@"Open Shape File…" to:shape action:@selector(openShapeFile:) key:@"o" mods:cmd | NSEventModifierFlagOption];
    [self add:@"New Shape…" to:shape action:@selector(newShape:) key:@"n" mods:cmd];
    [shape addItem:[NSMenuItem separatorItem]];
    [self add:@"Edit Shape in Text Editor" to:shape action:@selector(editShape:) key:@"e" mods:cmd];
    [self add:@"Show Shape in Finder" to:shape action:@selector(revealShape:) key:@"" mods:none];
    [self add:@"Show My Shapes Folder" to:shape action:@selector(showMyShapes:) key:@"" mods:none];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = shape;

    // Render
    NSMenu *render = [[NSMenu alloc] initWithTitle:@"Render"];
    [self add:@"Pause" to:render action:@selector(togglePause:) key:@" " mods:none];
    [self add:@"Refine More" to:render action:@selector(refineMore:) key:@"m" mods:none];
    [self add:@"Restart" to:render action:@selector(clearScene:) key:@"c" mods:none];
    [self add:@"New Random Scene" to:render action:@selector(randomScene:) key:@"r" mods:none];
    [self add:@"Reset Camera" to:render action:@selector(resetCamera:) key:@"" mods:none];
    [render addItem:[NSMenuItem separatorItem]];
    [self add:@"Run Stages Automatically" to:render action:@selector(toggleAuto:) key:@"p" mods:none];
    [[render addItemWithTitle:@"Run a stage by hand:" action:nil keyEquivalent:@""] setEnabled:NO];
    [self add:@"Geometry" to:render action:@selector(stageMenu:) key:@"g" mods:none].tag = GenGeom;
    [self add:@"Normals" to:render action:@selector(stageMenu:) key:@"n" mods:none].tag = GenNormals;
    [self add:@"Ambient Occlusion" to:render action:@selector(stageMenu:) key:@"a" mods:none].tag = GenAmbo;
    [self add:@"Stop After This Pass" to:render action:@selector(stageMenu:) key:@"\e" mods:none].tag = GenNone;
    [self add:@"Work on Reflections" to:render action:@selector(toggleReflection:) key:@"f" mods:none];
    [render addItem:[NSMenuItem separatorItem]];
    [self add:@"Reload Shaders" to:render action:@selector(reloadShaders:) key:@"r" mods:cmd];
    [self add:@"Reload Shaders" to:render action:@selector(reloadShaders:) key:FunctionKey(NSF5FunctionKey) mods:none].alternate = NO;
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = render;

    // Lighting
    NSMenu *light = [[NSMenu alloc] initWithTitle:@"Lighting"];
    [self add:@"Random Lighting" to:light action:@selector(randomLights:) key:@"l" mods:none];
    [self add:@"Brighter" to:light action:@selector(brighter:) key:@"=" mods:none];
    [self add:@"Darker" to:light action:@selector(darker:) key:@"-" mods:none];
    [light addItem:[NSMenuItem separatorItem]];
    [self add:@"Mouse Moves Camera" to:light action:@selector(mouseTargetMenu:) key:@"0" mods:none].tag = -1;
    for (int i = 0; i < 5; i++) {
        NSString *title = [NSString stringWithFormat:@"Mouse Moves Light %d", i + 1];
        [self add:title to:light action:@selector(mouseTargetMenu:) key:[NSString stringWithFormat:@"%d", i + 1] mods:none].tag = i;
    }
    [self add:@"Mouse Moves All Lights" to:light action:@selector(mouseTargetMenu:) key:@"9" mods:none].tag = 9;
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = light;

    // View
    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    [self add:@"Show Sidebar" to:view action:@selector(toggleSidebar:) key:@"l" mods:ctrl];
    [view addItem:[NSMenuItem separatorItem]];
    [self add:@"Previous View Mode" to:view action:@selector(vizStep:) key:FunctionKey(NSF1FunctionKey) mods:none].tag = -1;
    [self add:@"Next View Mode" to:view action:@selector(vizStep:) key:FunctionKey(NSF2FunctionKey) mods:none].tag = 1;
    [view addItem:[NSMenuItem separatorItem]];
    for (int i = 0; i < kNumVizModes; i++)
        [self add:kVizModeNames[i] to:view action:@selector(vizMenu:) key:@"" mods:none].tag = i;
    [view addItem:[NSMenuItem separatorItem]];
    NSMenuItem *full = [view addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"];
    full.keyEquivalentModifierMask = cmd | ctrl;
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = view;

    // Window
    NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
    [window addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [window addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = window;
    NSApp.windowsMenu = window;

    // Help
    NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
    [self add:@"Mouse and Keyboard Help" to:help action:@selector(showHelp:) key:@"h" mods:none];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = help;

    NSApp.mainMenu = bar;
}

static const NSInteger kShapeItemTag = 1000;

// Rebuilds the list of shapes at the top of the Shape menu each time it opens.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    while (menu.numberOfItems > 0 && [menu itemAtIndex:0].tag == kShapeItemTag) [menu removeItemAtIndex:0];
    NSInteger at = 0;
    for (id entry in [self shapeListWithDividers]) {
        NSMenuItem *item;
        if (entry == [NSNull null]) {
            item = [NSMenuItem separatorItem];
        } else {
            item = [[NSMenuItem alloc] initWithTitle:[Renderer displayNameForShape:entry]
                                              action:@selector(shapeMenuPicked:)
                                       keyEquivalent:@""];
            item.target = self;
            item.representedObject = entry;
        }
        item.tag = kShapeItemTag;
        [menu insertItem:item atIndex:at++];
    }
}

// Ticks next to the menu items that are switched on.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    BOOL on = NO;
    if (a == @selector(shapeMenuPicked:)) {
        item.state = [item.representedObject isEqual:_renderer.shapePath] ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (a == @selector(undo:)) return _undo.count > 0;
    if (a == @selector(redo:)) return _redo.count > 0;
    if (a == @selector(editShape:) || a == @selector(revealShape:) || a == @selector(newShape:))
        return _renderer.shapePath != nil;
    if (a == @selector(stageMenu:)) {
        on = (_renderer.stage == (GenMode)item.tag);
        if (item.tag == GenAmbo) return _renderer.normalsReady || _renderer.stage == GenNormals;
    } else if (a == @selector(toggleAuto:)) {
        on = _renderer.autoEnabled;
    } else if (a == @selector(togglePause:)) {
        item.title = _renderer.paused ? @"Resume" : @"Pause";
        return _renderer.paused || !_renderer.finished;
    } else if (a == @selector(refineMore:)) {
        return _renderer.finished;
    } else if (a == @selector(toggleReflection:)) {
        on = _renderer.onReflection;
    } else if (a == @selector(mouseTargetMenu:)) {
        on = (_renderer.mouseTarget == item.tag);
    } else if (a == @selector(vizMenu:)) {
        on = ((NSInteger)_renderer.scene->cb.g_viz_mode == item.tag);
    } else if (a == @selector(toggleSidebar:)) {
        item.title = _sidebar.hidden ? @"Show Sidebar" : @"Hide Sidebar";
    }
    item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
}

#pragma mark - Shape actions

- (void)shapePicked:(NSPopUpButton *)popup { [self checkpoint:nil]; [_renderer selectShape:popup.selectedItem.representedObject]; [self tick]; }
- (void)shapeMenuPicked:(NSMenuItem *)item { [self checkpoint:nil]; [_renderer selectShape:item.representedObject]; [self tick]; }

- (NSArray<UTType *> *)shapeTypes {
    UTType *t = [UTType typeWithFilenameExtension:@"metal"];
    return t ? @[t] : @[];
}

- (void)openShapeFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = [self shapeTypes];
    panel.allowsOtherFileTypes = YES;
    panel.message = @"Choose a shape file (.metal)";
    if ([_renderer userShapes].count) panel.directoryURL = [NSURL fileURLWithPath:_renderer.userShapesDir];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        [self checkpoint:nil];
        [self->_renderer selectShape:panel.URL.path];
        [self tick];
    }];
}

// Copies the current shape under a new name, switches to it and opens it for editing.
- (void)newShape:(id)sender {
    NSString *source = _renderer.shapePath;
    if (!source) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = [self shapeTypes];
    panel.nameFieldStringValue = [[[source.lastPathComponent stringByDeletingPathExtension]
        stringByAppendingString:@"_copy"] stringByAppendingPathExtension:@"metal"];
    panel.message = @"Name the new shape. It starts as a copy of the current one.";
    if ([_renderer prepareUserShapesDir]) panel.directoryURL = [NSURL fileURLWithPath:_renderer.userShapesDir];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSString *dest = panel.URL.path;
        if ([dest isEqualToString:source]) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        [fm removeItemAtPath:dest error:nil];   // the save panel has already asked about replacing
        if (![fm copyItemAtPath:source toPath:dest error:&err]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"The new shape could not be created" detail:err.localizedDescription];
            });
            return;
        }
        [self checkpoint:nil];
        [self->_renderer selectShape:dest];
        [self tick];
        [self editShape:nil];
    }];
}

- (void)showMyShapes:(id)sender {
    if (![_renderer prepareUserShapesDir]) {
        [self showError:@"Your shapes folder could not be created" detail:_renderer.userShapesDir];
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:_renderer.userShapesDir isDirectory:YES]];
}

- (void)editShape:(id)sender {
    if (!_renderer.shapePath) return;
    // The shapes that come inside the app can't be changed in place; make a copy instead.
    if ([_renderer shapeIsReadOnly:_renderer.shapePath]) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"This shape comes with the app";
        a.informativeText = @"To change it, make your own copy. The copy goes in the \"Gpucaster Shapes\" folder in Documents and opens in your text editor.";
        [a addButtonWithTitle:@"Make a Copy…"];
        [a addButtonWithTitle:@"Cancel"];
        [a beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
            if (r == NSAlertFirstButtonReturn) dispatch_async(dispatch_get_main_queue(), ^{ [self newShape:nil]; });
        }];
        return;
    }
    NSURL *file = [NSURL fileURLWithPath:_renderer.shapePath];
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    // ".metal" has no editor of its own, so use whatever opens plain text files.
    NSURL *editor = [ws URLForApplicationToOpenContentType:UTTypePlainText];
    if (editor) {
        [ws openURLs:@[file] withApplicationAtURL:editor configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
    } else {
        [ws openURL:file];
    }
}

- (void)revealShape:(id)sender {
    if (!_renderer.shapePath) return;
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:_renderer.shapePath]]];
}

// Puts a copy of the current shape beside a saved scene or image, as
// "<name>.metal", so the picture can always be recreated.
- (void)copyShapeBeside:(NSString *)savedPath {
    NSString *source = _renderer.shapePath;
    if (!source) return;
    NSString *dest = [[savedPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"metal"];
    if ([dest isEqualToString:source]) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dest error:nil];
    [fm copyItemAtPath:source toPath:dest error:nil];
}

#pragma mark - Render actions

- (void)runButtonClicked:(id)sender {
    if (_renderer.paused) _renderer.paused = NO;
    else if (_renderer.finished) [_renderer refineMore];
    else _renderer.paused = YES;
    [self tick];
}
- (void)togglePause:(id)sender { _renderer.paused = !_renderer.paused; [self tick]; }
- (void)refineMore:(id)sender { _renderer.paused = NO; [_renderer refineMore]; [self tick]; }
- (void)stageMenu:(NSMenuItem *)item { [_renderer setStage:(GenMode)item.tag]; [self tick]; }
- (void)toggleAuto:(id)sender { _renderer.autoEnabled = !_renderer.autoEnabled; [self tick]; }
- (void)toggleReflection:(id)sender { [_renderer toggleReflection]; [self tick]; }
- (void)clearScene:(id)sender { [_renderer clearAll]; [self tick]; }
- (void)randomScene:(id)sender { [self checkpoint:nil]; [_renderer newSeed:_renderer.scene->NewRandomSeed()]; [self tick]; }
- (void)resetCamera:(id)sender { [self checkpoint:nil]; _renderer.scene->ResetCamera(); [_renderer clearAll]; }
- (void)reloadShaders:(id)sender { [_renderer reloadShadersInBackground]; [self tick]; }

- (void)shaderResult:(NSString *)error {
    [self tick];
    if (!error || [error isEqualToString:_shownError]) {
        if (!error) _shownError = nil;
        return;
    }
    _shownError = error;
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = @"The shaders did not compile";
    a.informativeText = [error stringByAppendingString:
        @"\n\nThe picture keeps using the last version that worked. Fix the file and save it; it reloads by itself."];
    [a beginSheetModalForWindow:_window completionHandler:nil];
}

#pragma mark - Lighting and view actions

- (void)randomLights:(id)sender {
    [self checkpoint:nil];
    _renderer.scene->RandomizeLights();
    [_renderer relight];
    [_sidebar refresh];
    [self rememberLighting];
}
- (void)brighter:(id)sender { [self checkpoint:@"brightness"]; _renderer.scene->cb.kLightScale *= 1.025f; [_renderer relight]; [_sidebar refresh]; }
- (void)darker:(id)sender { [self checkpoint:@"brightness"]; _renderer.scene->cb.kLightScale *= 0.975f; [_renderer relight]; [_sidebar refresh]; }

- (void)mouseTargetMenu:(NSMenuItem *)item {
    _renderer.mouseTarget = (int)item.tag;
    if (item.tag >= 0 && item.tag < 5) _sidebar.selectedLight = (int)item.tag;
    [_sidebar refresh];
}

- (void)vizStep:(NSMenuItem *)item {
    [_renderer setVizMode:(int)_renderer.scene->cb.g_viz_mode + (int)item.tag];
    [_sidebar refresh];
}
- (void)vizMenu:(NSMenuItem *)item { [_renderer setVizMode:(int)item.tag]; [_sidebar refresh]; }

- (void)toggleSidebar:(id)sender { _sidebar.hidden = !_sidebar.hidden; }

- (void)showHelp:(id)sender {
    NSAlert *a = [NSAlert new];
    a.messageText = @"Mouse and keyboard";
    a.informativeText =
        @"MOUSE\n"
         "Drag: orbit the camera\n"
         "Shift-drag: slide the camera sideways\n"
         "Control-drag or Option-drag: roll the camera\n"
         "Right-drag, scroll or pinch: move forwards and backwards\n"
         "(Often the camera starts inside the surface; move backwards to see it.)\n\n"
         "THE PICTURE\n"
         "It builds itself: geometry, then normals, then shading, and reflections\n"
         "if the surface is reflective.\n"
         "Space pause or resume, M refine more, C restart, R new random scene\n\n"
         "BY HAND (as in the Windows version)\n"
         "G geometry, N normals, A ambient occlusion, Esc stop, F reflections,\n"
         "P turn the automatic run on or off\n\n"
         "LIGHTING\n"
         "L random lighting, = brighter, - darker\n"
         "Recent lightings are kept as small pictures in the sidebar. Cmd-Z undoes any change.\n"
         "0 mouse moves camera, 1-5 mouse moves that light, 9 all lights\n\n"
         "Every command is also in the menus, with its shortcut.";
    [a beginSheetModalForWindow:_window completionHandler:nil];
}

#pragma mark - Files

- (void)showError:(NSString *)message detail:(NSString *)detail {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = message;
    a.informativeText = detail ?: @"";
    [a beginSheetModalForWindow:_window completionHandler:nil];
}

- (NSArray<UTType *> *)sceneTypes {
    UTType *t = [UTType typeWithFilenameExtension:@"scn"];
    return t ? @[t] : @[];
}

- (void)openSceneLightsOnly:(BOOL)lightsOnly {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = [self sceneTypes];
    panel.allowsOtherFileTypes = YES;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        std::string error;
        [self checkpoint:nil];
        if (!self->_renderer.scene->Import(panel.URL.fileSystemRepresentation, lightsOnly, &error)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"The scene could not be opened" detail:@(error.c_str())];
            });
            return;
        }
        if (lightsOnly) {
            [self->_renderer relight];
        } else {
            [self->_renderer sceneReplaced];
            // A scene saved by this app has its shape beside it, as "<name>.metal".
            NSString *shape = [[panel.URL.path stringByDeletingPathExtension] stringByAppendingPathExtension:@"metal"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:shape]) [self->_renderer selectShape:shape keepParamValues:YES];
        }
        [self rememberLighting];
        [self->_sidebar refresh];
        [self tick];
    }];
}
- (void)openScene:(id)sender { [self openSceneLightsOnly:NO]; }
- (void)importLights:(id)sender { [self openSceneLightsOnly:YES]; }

- (void)saveScene:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = [self sceneTypes];
    panel.nameFieldStringValue = @"scene.scn";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        std::string error;
        if (!self->_renderer.scene->Export(panel.URL.fileSystemRepresentation, &error)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"The scene could not be saved" detail:@(error.c_str())];
            });
            return;
        }
        [self copyShapeBeside:panel.URL.path];
    }];
}

// Saves the picture, plus the scene file and a copy of the shape beside it,
// so the picture can always be recreated.
- (void)saveImage:(id)sender {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePNG];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"gpucaster_%08x.png", _renderer.scene->cb.g_scene_seed];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        NSString *path = panel.URL.path;
        if (![self->_renderer saveImageToPNG:path]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showError:@"The image could not be saved" detail:path];
            });
            return;
        }
        NSString *base = [path stringByDeletingPathExtension];
        self->_renderer.scene->Export([base stringByAppendingPathExtension:@"scn"].fileSystemRepresentation, nullptr);
        [self copyShapeBeside:path];
    }];
}

#pragma mark - Large image export

// Asks for a size and a file, then builds the picture again at that size in
// the background, with a progress sheet, and saves it.
- (void)exportLargeImage:(id)sender {
    if (_exporter) return;
    const int w = _renderer.imageWidth, h = _renderer.imageHeight;

    NSPopUpButton *sizes = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 330, 26) pullsDown:NO];
    for (int m : {2, 3, 4, 6, 8, 12, 16}) {
        if (![_renderer canRenderWidth:w * m height:h * m]) continue;
        [sizes addItemWithTitle:[NSString stringWithFormat:@"%d × the window:  %d × %d  (%.0f megapixels)", m, w * m, h * m,
                                                           (double)w * m * h * m * 1e-6]];
        sizes.lastItem.tag = m;
    }
    if (sizes.numberOfItems == 0) {
        [self showError:@"This picture is already as large as this Mac can render" detail:@"Make the window smaller and try again."];
        return;
    }
    [sizes selectItemAtIndex:MIN(2, sizes.numberOfItems - 1)];
    NSTextField *label = [NSTextField labelWithString:@"Size:"];
    NSStackView *accessory = [NSStackView stackViewWithViews:@[label, sizes]];
    accessory.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);

    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePNG];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"gpucaster_%08x_large.png", _renderer.scene->cb.g_scene_seed];
    panel.message = @"The picture is built again at the larger size, using the Quality settings in the sidebar.";
    panel.accessoryView = accessory;
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
        int m = (int)sizes.selectedItem.tag;
        NSString *path = panel.URL.path;
        dispatch_async(dispatch_get_main_queue(), ^{ [self startExportWidth:w * m height:h * m path:path]; });
    }];
}

- (void)startExportWidth:(int)width height:(int)height path:(NSString *)path {
    _exporter = [_renderer exportCopyWithWidth:width height:height];
    _exportPath = path;
    _exportCancelled = NO;
    _exportTiles = 4;
    _exportStart = CACurrentMediaTime();
    _pausedBeforeExport = _renderer.paused;
    _renderer.paused = YES;   // give the graphics card to the big picture

    _exportLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"Rendering %d × %d…", width, height]];
    _exportBar = [NSProgressIndicator new];
    _exportBar.style = NSProgressIndicatorStyleBar;
    _exportBar.indeterminate = NO;
    _exportBar.minValue = 0;
    _exportBar.maxValue = 1;
    [_exportBar.widthAnchor constraintEqualToConstant:340].active = YES;
    NSButton *cancel = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelExport:)];
    cancel.keyEquivalent = @"\e";
    NSStackView *stack = [NSStackView stackViewWithViews:@[_exportLabel, _exportBar, cancel]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 10;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 16, 20);
    _exportSheet = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 120)
                                              styleMask:NSWindowStyleMaskTitled
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    _exportSheet.contentView = stack;
    [_window beginSheet:_exportSheet completionHandler:nil];
    [self exportStep];
}

- (void)cancelExport:(id)sender { _exportCancelled = YES; }

// One slice of the export.  Each slice starts the next when the graphics card
// has finished it, so the app stays responsive throughout.
- (void)exportStep {
    if (!_exporter) return;
    if (_exportCancelled) {
        [self finishExportSaved:NO error:nil];
        return;
    }
    if (_exporter.finished) {
        _exportLabel.stringValue = @"Saving…";
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = [self->_exporter saveImageToPNG:self->_exportPath];
            [self finishExportSaved:ok error:ok ? nil : @"The image could not be written."];
        });
        return;
    }
    double p = _exporter.progress;
    if (p >= 0) {
        _exportBar.doubleValue = p;
        double elapsed = CACurrentMediaTime() - _exportStart;
        if (p > 0.02 && elapsed > 2) {
            int left = (int)lround(elapsed * (1 - p) / p);
            _exportLabel.stringValue = [NSString stringWithFormat:@"Rendering %d × %d…  about %d:%02d left",
                                                                  _exporter.imageWidth, _exporter.imageHeight, left / 60, left % 60];
        }
    }
    const int tiles = (int)MAX(1.0, _exportTiles);
    __weak AppDelegate *weakSelf = self;
    [_exporter stepOffscreenTiles:tiles completion:^(double seconds) {
        AppDelegate *me = weakSelf;
        if (!me) return;
        // Aim for slices of about a twentieth of a second.
        if (seconds > 0) me->_exportTiles = MIN(8192.0, MAX(1.0, 0.5 * me->_exportTiles + 0.5 * 0.05 / (seconds / tiles)));
        [me exportStep];
    }];
}

- (void)finishExportSaved:(BOOL)saved error:(NSString *)error {
    NSString *path = _exportPath;
    if (saved) {
        // Keep the scene and shape beside the picture, as Save Image does.
        _exporter.scene->Export([[path stringByDeletingPathExtension] stringByAppendingPathExtension:@"scn"].fileSystemRepresentation, nullptr);
        [self copyShapeBeside:path];
    }
    _exporter = nil;   // frees the large textures
    _exportPath = nil;
    [_window endSheet:_exportSheet];
    _exportSheet = nil;
    _renderer.paused = _pausedBeforeExport;
    [self tick];
    if (getenv("GPUCASTER_EXPORT")) {
        printf("export: %s in %.1f s -> %s\n", saved ? "saved" : "NOT saved", CACurrentMediaTime() - _exportStart, path.UTF8String);
        [NSApp terminate:nil];
        return;
    }
    if (saved) {
        [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:path]]];
    } else if (error) {
        [self showError:@"The large image could not be saved" detail:error];
    }
}

@end

#pragma mark - Self-test

// Renders the default scene off-screen through every stage and saves pictures.
static int RunSelfTest(NSString *outDir) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { fprintf(stderr, "selftest: no Metal device\n"); return 1; }
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    // Always test the default shape, not whichever one the app used last,
    // unless GPUCASTER_SHAPE names another.
    const bool defaultShape = !getenv("GPUCASTER_SHAPE");
    setenv("GPUCASTER_SHAPE", "blobs", 0);
    Renderer *r = [[Renderer alloc] initWithDevice:device];
    if (r.lastError) { fprintf(stderr, "selftest: shader error:\n%s\n", r.lastError.UTF8String); return 1; }
    r.autoEnabled = NO;
    [r setImageWidth:960 height:600];

    int failures = 0;
    auto save = ^(NSString *name) {
        NSString *path = [outDir stringByAppendingPathComponent:name];
        if (![r saveImageToPNG:path]) fprintf(stderr, "selftest: could not save %s\n", path.UTF8String);
    };
    CFTimeInterval t0 = CACurrentMediaTime();

    // A stage change takes effect when the pass in progress finishes.
    [r runPasses:39];
    [r setStage:GenNormals];
    [r runPasses:1];
    save(@"1_geometry.png");
    if (r.geomPasses != 40) { fprintf(stderr, "selftest: expected 40 geometry passes, got %d\n", r.geomPasses); failures++; }

    [r runPasses:1];   // one pass of normals, after which it stops by itself
    save(@"2_normals_lit.png");
    if (!r.normalsReady || r.stage != GenNone) { fprintf(stderr, "selftest: normals stage did not finish\n"); failures++; }

    [r setStage:GenAmbo];
    [r runPasses:15];
    [r setStage:GenNone];
    [r runPasses:1];
    save(@"3_final.png");
    if (r.amboPasses != 16 || r.stage != GenNone) { fprintf(stderr, "selftest: expected 16 ambient passes then idle, got %d\n", r.amboPasses); failures++; }

    // Check the stored data at a pixel in the middle of the picture (default scene only).
    if (defaultShape) {
        float depth; simd_float4 normal, ambo;
        [r readPixelX:480 y:400 depth:&depth normal:&normal ambo:&ambo];
        float fraction = ambo.w / MAX(r.amboPasses, 1);
        printf("selftest: centre pixel depth %.4f, normal (%.3f %.3f %.3f), ambient sum %.3f over %d passes = %.3f\n",
               depth, normal.x, normal.y, normal.z, ambo.w, r.amboPasses, fraction);
        float nlen = simd_length(simd_make_float3(normal.x, normal.y, normal.z));
        if (!(depth > 0 && depth < kMaxDist)) { fprintf(stderr, "selftest: no surface found at the centre pixel\n"); failures++; }
        if (fabsf(nlen - 1) > 0.02f) { fprintf(stderr, "selftest: normal is not unit length (%.3f)\n", nlen); failures++; }
        if (!(fraction > 0.05f && fraction < 1.0f)) { fprintf(stderr, "selftest: ambient occlusion fraction %.3f is implausible\n", fraction); failures++; }
    }

    for (int mode = 1; mode < kNumVizModes; mode++) {
        [r setVizMode:mode];
        save([NSString stringWithFormat:@"view_%d.png", mode]);
    }
    [r setVizMode:0];

    // An automatic run must go through every stage by itself, including the
    // reflection stages when the surface is reflective, and then stop.
    {
        Renderer *a = [[Renderer alloc] initWithDevice:device];
        a.autoGeomPasses = 12;
        a.autoAmboPasses = 4;
        a.scene->cb.kReflectivity = 0.5f;
        [a setImageWidth:480 height:300];
        BOOL done = [a runUntilFinished:200];
        double p = a.progress;
        [a saveImageToPNG:[outDir stringByAppendingPathComponent:@"4_auto_with_reflections.png"]];
        printf("selftest: automatic run %s (geometry %d, ambient %d, on %s rays, progress %.2f)\n", done ? "finished" : "DID NOT FINISH",
               a.geomPasses, a.amboPasses, a.onReflection ? "reflection" : "primary", p);
        if (!done || a.onReflection || a.geomPasses != 12 || a.amboPasses != 4 || p != 1.0) failures++;
        // Without reflectivity it must not spend time on reflections: 12 + 1 + 4 passes.
        Renderer *b = [[Renderer alloc] initWithDevice:device];
        b.autoGeomPasses = 12;
        b.autoAmboPasses = 4;
        b.scene->cb.kReflectivity = 0;
        [b setImageWidth:480 height:300];
        [b runPasses:17];
        if (!b.finished) { fprintf(stderr, "selftest: non-reflective automatic run did not finish in 17 passes\n"); failures++; }
        [b refineMore];
        [b runUntilFinished:50];
        if (b.amboPasses != 8) { fprintf(stderr, "selftest: refine more gave %d ambient passes, expected 8\n", b.amboPasses); failures++; }
    }

    // Shape parameters: the Mandelbox declares five, they start at their
    // defaults, and changing one changes the picture.
    {
        setenv("GPUCASTER_SHAPE", "mandelbox", 1);
        Renderer *m = [[Renderer alloc] initWithDevice:device];
        setenv("GPUCASTER_SHAPE", "blobs", 1);
        m.autoEnabled = NO;
        [m setImageWidth:320 height:200];
        ShapeParam *scale = nil;
        for (ShapeParam *sp in m.shapeParams) if ([sp.name isEqualToString:@"scale"]) scale = sp;
        float depthA = 0, depthB = 0; simd_float4 n, am;
        if (m.shapeParams.count != 5 || !scale || [m valueOfParam:scale] != 2.0f) {
            fprintf(stderr, "selftest: Mandelbox parameters not read correctly (%d found)\n", (int)m.shapeParams.count);
            failures++;
        } else {
            [m runPasses:20];
            [m readPixelX:160 y:100 depth:&depthA normal:&n ambo:&am];
            [m setValue:-1.5f ofParam:scale];
            [m runPasses:20];
            [m readPixelX:160 y:100 depth:&depthB normal:&n ambo:&am];
            printf("selftest: Mandelbox centre depth %.4f at scale 2, %.4f at scale -1.5\n", depthA, depthB);
            if (depthA == depthB) { fprintf(stderr, "selftest: changing a shape parameter did not change the picture\n"); failures++; }
        }
    }

    // Undo snapshots: random lighting and a camera move must be reversible exactly.
    {
        SceneState *sc = r.scene;
        SceneState::Snapshot before = sc->GetSnapshot();
        sc->RandomizeLights();
        SceneState::Change c1 = sc->RestoreSnapshot(before);
        bool same1 = memcmp(&before.cb, &sc->cb, sizeof(Uniforms)) == 0;
        sc->camera.pos.x += 0.25f;
        SceneState::Change c2 = sc->RestoreSnapshot(before);
        uint32_t seed = sc->cb.g_scene_seed;
        sc->OnSeed(12345);
        SceneState::Change c3 = sc->RestoreSnapshot(before);
        bool same3 = memcmp(&before.cb, &sc->cb, sizeof(Uniforms)) == 0 && sc->cb.g_scene_seed == seed;
        if (!same1 || !same3 || c1 != SceneState::LightingOnly || c2 != SceneState::PictureRestart || c3 != SceneState::NewSeed) {
            fprintf(stderr, "selftest: undo snapshot did not restore the scene (%d %d %d %d %d)\n", same1, same3, c1, c2, c3);
            failures++;
        }
        [r sceneReplaced];

        // Lighting thumbnails: two different lightings give two different small pictures,
        // and making them leaves the scene's own lighting untouched.
        std::vector<Lighting> ls;
        ls.push_back(sc->GetLighting());
        Uniforms keep = sc->cb;
        sc->RandomizeLights();   // (twice: restoring the seed above also rewound the random numbers,
        sc->RandomizeLights();   //  so the first one repeats the lighting the scene started with)
        ls.push_back(sc->GetLighting());
        sc->SetLighting(ls[0]);
        [r runPasses:10];               // lighting only shows once the surface has normals
        [r setStage:GenNormals];
        [r runPasses:2];
        NSArray<NSImage *> *thumbs = [r thumbnailsForLightings:ls width:126];
        bool differ = thumbs.count == 2 && ![[thumbs[0] TIFFRepresentation] isEqualToData:[thumbs[1] TIFFRepresentation]];
        bool untouched = memcmp(keep.g_light_col, sc->cb.g_light_col, sizeof(keep.g_light_col)) == 0;
        for (NSUInteger i = 0; i < thumbs.count; i++) {
            NSBitmapImageRep *rep = (NSBitmapImageRep *)thumbs[i].representations.firstObject;
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
                writeToFile:[outDir stringByAppendingPathComponent:[NSString stringWithFormat:@"thumb_%d.png", (int)i]] atomically:YES];
        }
        if (!differ || !untouched) { fprintf(stderr, "selftest: lighting thumbnails wrong (%d %d)\n", differ, untouched); failures++; }
    }

    // Large export: a copy of the renderer builds the same scene at twice the
    // size by itself, and saves a picture with the right dimensions.
    {
        Renderer *small = [[Renderer alloc] initWithDevice:device];
        small.autoGeomPasses = 12;
        small.autoAmboPasses = 4;
        [small setImageWidth:480 height:300];
        Renderer *big = [small exportCopyWithWidth:960 height:600];
        BOOL done = [big runUntilFinished:200];
        NSString *path = [outDir stringByAppendingPathComponent:@"5_export_2x.png"];
        BOOL saved = done && [big saveImageToPNG:path];
        NSImageRep *rep = saved ? [NSImageRep imageRepWithContentsOfFile:path] : nil;
        bool sameScene = memcmp(small.scene->cb.g_light_col, big.scene->cb.g_light_col, sizeof(big.scene->cb.g_light_col)) == 0 &&
                         small.scene->cb.g_scene_seed == big.scene->cb.g_scene_seed;
        if (!saved || rep.pixelsWide != 960 || rep.pixelsHigh != 600 || !sameScene || ![small canRenderWidth:960 height:600] ||
            [small canRenderWidth:20000 height:20000]) {
            fprintf(stderr, "selftest: large export failed (done %d, saved %d, %ld x %ld)\n", done, saved, (long)rep.pixelsWide, (long)rep.pixelsHigh);
            failures++;
        }
    }

    // Switching shapes the way the app does (compiling in the background):
    // after each switch the renderer must be using the new shape's own
    // parameters at their default values - including when a second shape is
    // picked before the first has finished compiling.
    if (defaultShape) {
        Renderer *sw = [[Renderer alloc] initWithDevice:device];
        [sw setImageWidth:320 height:200];
        auto waitForCompile = ^{
            NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:60];
            do {
                [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            } while (sw.compiling && [limit timeIntervalSinceNow] > 0);
        };
        auto check = ^BOOL(NSString *path, NSString *what) {
            NSArray<ShapeParam *> *want = [Renderer paramsInShape:path];
            BOOL ok = !sw.lastError && [sw.shapePath isEqualToString:path] && sw.shapeParams.count == want.count;
            for (NSUInteger i = 0; ok && i < want.count; i++) {
                ShapeParam *have = sw.shapeParams[i];
                ok = [have.name isEqualToString:want[i].name] && [sw valueOfParam:have] == want[i].defaultValue;
            }
            if (!ok) fprintf(stderr, "selftest: after %s, %s is not loaded with its defaults\n", what.UTF8String, path.lastPathComponent.UTF8String);
            return ok;
        };
        NSArray<NSString *> *shapes = [sw availableShapes];
        int bad = 0;
        for (NSString *path in shapes) {            // one at a time
            [sw selectShape:path];
            waitForCompile();
            if (!check(path, @"a switch")) bad++;
        }
        for (NSUInteger i = 0; i + 1 < shapes.count; i++) {   // two in quick succession
            [sw selectShape:shapes[i]];
            [sw selectShape:shapes[i + 1]];
            waitForCompile();
            if (!check(shapes[i + 1], @"a quick double switch")) bad++;
        }
        printf("selftest: shape switching, %d problems\n", bad);
        if (bad) failures++;
    }

    // Your own shapes folder: a shape put there is listed after the built-in
    // ones and is not treated as part of the app.
    if (defaultShape) {
        NSString *mine = [outDir stringByAppendingPathComponent:@"my_shapes"];
        setenv("GPUCASTER_USER_SHAPES", mine.fileSystemRepresentation, 1);
        Renderer *u = [[Renderer alloc] initWithDevice:device];
        NSArray<NSString *> *builtIn = [u builtInShapes];
        NSString *copy = [mine stringByAppendingPathComponent:@"my_test_shape.metal"];
        BOOL made = [u prepareUserShapesDir];
        [[NSFileManager defaultManager] removeItemAtPath:copy error:nil];
        made = made && [[NSFileManager defaultManager] copyItemAtPath:builtIn.firstObject toPath:copy error:nil];
        NSArray<NSString *> *all = [u availableShapes];
        BOOL listed = made && [[u userShapes] isEqualToArray:@[copy]] && all.count == builtIn.count + 1 && [all.lastObject isEqualToString:copy];
        BOOL loads = listed && ![u compileErrorForShape:copy] && ![u shapeIsReadOnly:copy];
        NSString *insideApp = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"shaders/shapes/blobs.metal"];
        BOOL protects = [u shapeIsReadOnly:insideApp];
        printf("selftest: shaders from %s; %d built-in shapes\n", u.shaderDir.UTF8String, (int)builtIn.count);
        if (!listed || !loads || !protects || builtIn.count < 10) {
            fprintf(stderr, "selftest: user shapes folder not working (%d %d %d)\n", listed, loads, protects);
            failures++;
        }
        unsetenv("GPUCASTER_USER_SHAPES");
    }

    // Lights: directions set from the camera's point of view read back the
    // same, are described in plain words, and "solo" changes only the display.
    if (defaultShape) {
        SceneState *sc = r.scene;
        SceneState::Snapshot keep = sc->GetSnapshot();
        int bad = 0;
        sc->camera.RotateOnY(0.7f);   // an arbitrary camera, so view and world directions differ
        sc->camera.RotateOnX(-0.4f);
        struct { simd_float3 dir; const char *words; } cases[] = {
            {{-0.69f, 0.69f, -0.2f}, "Upper left, side-on"},
            {{0, 0, -1}, "Straight on"},
            {{0, 0, 1}, "Directly behind"},
            {{0.9f, 0, 0.44f}, "Right, behind"},
            {{0, -1, 0}, "Below, side-on"},
            {{0.5f, 0.6f, -0.62f}, "Upper right, in front"},
        };
        for (auto &c : cases) {
            simd_float3 want = simd_normalize(c.dir);
            SetLightDirectionInView(sc, 1, want);
            simd_float3 got = LightDirectionInView(sc, 1);
            NSString *words = DescribeLightDirection(got);
            if (simd_distance(want, got) > 1e-4f || ![words isEqualToString:@(c.words)]) {
                fprintf(stderr, "selftest: light direction (%.2f %.2f %.2f) read back as (%.2f %.2f %.2f), \"%s\" (wanted \"%s\")\n",
                        want.x, want.y, want.z, got.x, got.y, got.z, words.UTF8String, c.words);
                bad++;
            }
        }
        // A light pointing straight along the world's up axis must not break.
        sc->SetLightDirection(2, simd_make_float3(0, 1, 0));
        if (!isfinite(simd_length(sc->lights[2].x)) || !isfinite(simd_length(sc->lights[2].y))) bad++;
        sc->RestoreSnapshot(keep);
        [r sceneReplaced];
        [r runPasses:10];
        [r setStage:GenNormals];
        [r runPasses:2];
        NSString *allPath = [outDir stringByAppendingPathComponent:@"6_all_lights.png"];
        NSString *soloPath = [outDir stringByAppendingPathComponent:@"6_light_1_alone.png"];
        Uniforms before = sc->cb;
        [r saveImageToPNG:allPath];
        r.soloLight = 0;
        [r saveImageToPNG:soloPath];
        r.soloLight = -1;
        bool differ = ![[NSData dataWithContentsOfFile:allPath] isEqualToData:[NSData dataWithContentsOfFile:soloPath]];
        bool untouched = memcmp(before.g_light_col, sc->cb.g_light_col, sizeof(before.g_light_col)) == 0;
        if (!differ || !untouched) { fprintf(stderr, "selftest: solo light wrong (%d %d)\n", differ, untouched); bad++; }
        printf("selftest: lights, %d problems\n", bad);
        if (bad) failures++;
    }

    // Every shape in the shapes folder must compile.
    if (defaultShape) {
        NSArray<NSString *> *shapes = [r availableShapes];
        int bad = 0;
        for (NSString *path in shapes) {
            NSString *err = [r compileErrorForShape:path];
            if (err) {
                fprintf(stderr, "selftest: shape %s does not compile:\n%s\n", path.lastPathComponent.UTF8String, err.UTF8String);
                bad++;
            }
        }
        printf("selftest: %d of %d shapes compile\n", (int)shapes.count - bad, (int)shapes.count);
        if (bad || shapes.count == 0) failures++;
    }

    // Scene files must survive a save and reload unchanged.
    NSString *scn = [outDir stringByAppendingPathComponent:@"roundtrip.scn"];
    Uniforms before = r.scene->cb;
    std::string error;
    if (!r.scene->Export(scn.fileSystemRepresentation, &error) || !r.scene->Import(scn.fileSystemRepresentation, false, &error)) {
        fprintf(stderr, "selftest: scene save/load failed: %s\n", error.c_str());
        failures++;
    } else if (memcmp(&before, &r.scene->cb, sizeof(Uniforms)) != 0) {
        fprintf(stderr, "selftest: scene changed after save and reload\n");
        failures++;
    }

    printf("selftest: %s on %s, %.1f s, pictures in %s\n", failures ? "FAILED" : "ok", device.name.UTF8String,
           CACurrentMediaTime() - t0, outDir.UTF8String);
    return failures ? 1 : 0;
}

// Renders one picture without opening a window:
//   Gpucaster --render out.png [--shape name-or-file] [--scene file.scn]
//             [--size WIDTHxHEIGHT] [--geometry passes] [--shading passes]
static int RunRender(int argc, const char *argv[]) {
    NSString *out = nil, *scene = nil;
    int width = 1920, height = 1200, geometry = 40, shading = 16;
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
        if (!v) break;
        if (!strcmp(a, "--render")) out = @(v);
        else if (!strcmp(a, "--shape")) setenv("GPUCASTER_SHAPE", v, 1);
        else if (!strcmp(a, "--scene")) scene = @(v);
        else if (!strcmp(a, "--size")) sscanf(v, "%dx%d", &width, &height);
        else if (!strcmp(a, "--geometry")) geometry = atoi(v);
        else if (!strcmp(a, "--shading")) shading = atoi(v);
        else continue;
        i++;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || !out) { fprintf(stderr, "render: no Metal device, or no output file given\n"); return 1; }
    setenv("GPUCASTER_SHAPE", "blobs", 0);   // unless --shape said otherwise
    Renderer *r = [[Renderer alloc] initWithDevice:device];
    if (r.lastError) { fprintf(stderr, "render: shader error:\n%s\n", r.lastError.UTF8String); return 1; }
    if (scene) {
        std::string error;
        if (!r.scene->Import(scene.fileSystemRepresentation, false, &error)) {
            fprintf(stderr, "render: cannot open scene: %s\n", error.c_str());
            return 1;
        }
        [r sceneReplaced];
    }
    if (![r canRenderWidth:width height:height]) { fprintf(stderr, "render: %d x %d is too large for this Mac\n", width, height); return 1; }
    r.autoGeomPasses = MAX(1, geometry);
    r.autoAmboPasses = MAX(1, shading);
    [r setImageWidth:width height:height];
    CFTimeInterval t0 = CACurrentMediaTime();
    if (![r runUntilFinished:100000] || ![r saveImageToPNG:out]) { fprintf(stderr, "render: failed\n"); return 1; }
    printf("render: %d x %d, %s, %.1f s -> %s\n", r.imageWidth, r.imageHeight,
           [Renderer displayNameForShape:r.shapePath].UTF8String, CACurrentMediaTime() - t0, out.UTF8String);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--render") == 0) return RunRender(argc, argv);
        }
        for (int i = 1; i + 1 < argc; i++) {
            if (strcmp(argv[i], "--selftest") == 0)
                return RunSelfTest([NSString stringWithUTF8String:argv[i + 1]]);
        }
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
