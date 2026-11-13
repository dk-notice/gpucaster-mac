// Gpucaster for macOS: app start-up, window, menus, toolbar and input.
//
// Run with "--selftest <folder>" to render a test scene off-screen, save a
// picture of each stage into the folder, and exit without opening a window.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "Renderer.h"
#import "Sidebar.h"

#pragma mark - Picture view

@interface RenderView : MTKView
@property (nonatomic, weak) Renderer *renderer;
@property (nonatomic, copy) void (^onLightsMoved)(void);
@end

@implementation RenderView

- (BOOL)acceptsFirstResponder { return YES; }

// Plain keys (G, N, A, ...) are menu shortcuts; offer the key to the menus first.
- (void)keyDown:(NSEvent *)e {
    if (![NSApp.mainMenu performKeyEquivalent:e]) [super keyDown:e];
}

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
    if (amount != 0) [self.renderer dolly:(float)amount];
}

- (void)magnifyWithEvent:(NSEvent *)e { [self.renderer dolly:(float)(e.magnification * 0.5)]; }

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
    NSArray<NSString *> *_shapePopupPaths;   // what the pop-up currently lists
    NSButton *_runButton;           // Pause / Resume / Refine More
    NSProgressIndicator *_progress;
    NSTextField *_status;
    NSTimer *_timer;
    NSString *_shownError;
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

    __weak AppDelegate *weakSelf = self;
    _view.onLightsMoved = ^{ [weakSelf sidebarRefresh]; };
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
- (void)refreshShapePopup {
    NSMutableArray<NSString *> *paths = [[_renderer availableShapes] mutableCopy];
    NSString *current = _renderer.shapePath;
    if (current && ![paths containsObject:current]) [paths addObject:current];   // a shape opened from elsewhere
    if (![paths isEqualToArray:_shapePopupPaths]) {
        _shapePopupPaths = [paths copy];
        [_shapePopup removeAllItems];
        for (NSString *path in paths) {
            [_shapePopup addItemWithTitle:@""];   // (titles set below, so duplicates are allowed)
            _shapePopup.lastItem.title = [Renderer displayNameForShape:path];
            _shapePopup.lastItem.representedObject = path;
        }
    }
    NSInteger index = current ? (NSInteger)[paths indexOfObject:current] : -1;
    if (index >= 0 && index != NSNotFound && _shapePopup.indexOfSelectedItem != index) [_shapePopup selectItemAtIndex:index];
}

- (void)tick {
    [_renderer reloadShadersIfFilesChanged];
    [self refreshShapePopup];
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
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = file;

    // Shape (the list of shapes at the top is filled in by -menuNeedsUpdate:)
    NSMenu *shape = [[NSMenu alloc] initWithTitle:@"Shape"];
    shape.delegate = self;
    [shape addItem:[NSMenuItem separatorItem]];
    [self add:@"Open Shape File…" to:shape action:@selector(openShapeFile:) key:@"o" mods:cmd | NSEventModifierFlagOption];
    [self add:@"New Shape…" to:shape action:@selector(newShape:) key:@"n" mods:cmd];
    [shape addItem:[NSMenuItem separatorItem]];
    [self add:@"Edit Shape in Text Editor" to:shape action:@selector(editShape:) key:@"e" mods:cmd];
    [self add:@"Show Shape in Finder" to:shape action:@selector(revealShape:) key:@"" mods:none];
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
    NSMutableArray<NSString *> *paths = [[_renderer availableShapes] mutableCopy];
    NSString *current = _renderer.shapePath;
    if (current && ![paths containsObject:current]) [paths addObject:current];
    NSInteger at = 0;
    for (NSString *path in paths) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[Renderer displayNameForShape:path]
                                                      action:@selector(shapeMenuPicked:)
                                               keyEquivalent:@""];
        item.target = self;
        item.tag = kShapeItemTag;
        item.representedObject = path;
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

- (void)shapePicked:(NSPopUpButton *)popup { [_renderer selectShape:popup.selectedItem.representedObject]; [self tick]; }
- (void)shapeMenuPicked:(NSMenuItem *)item { [_renderer selectShape:item.representedObject]; [self tick]; }

- (NSArray<UTType *> *)shapeTypes {
    UTType *t = [UTType typeWithFilenameExtension:@"metal"];
    return t ? @[t] : @[];
}

- (void)openShapeFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = [self shapeTypes];
    panel.allowsOtherFileTypes = YES;
    panel.message = @"Choose a shape file (.metal)";
    if (_renderer.shapesDir) panel.directoryURL = [NSURL fileURLWithPath:_renderer.shapesDir];
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse r) {
        if (r != NSModalResponseOK) return;
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
    panel.nameFieldStringValue = @"my_shape.metal";
    panel.message = @"Name the new shape. It starts as a copy of the current one.";
    if (_renderer.shapesDir) panel.directoryURL = [NSURL fileURLWithPath:_renderer.shapesDir];
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
        [self->_renderer selectShape:dest];
        [self tick];
        [self editShape:nil];
    }];
}

- (void)editShape:(id)sender {
    if (!_renderer.shapePath) return;
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
- (void)randomScene:(id)sender { [_renderer newSeed:_renderer.scene->NewRandomSeed()]; [self tick]; }
- (void)resetCamera:(id)sender { _renderer.scene->ResetCamera(); [_renderer clearAll]; }
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
    _renderer.scene->RandomizeLights();
    [_renderer relight];
    [_sidebar refresh];
}
- (void)brighter:(id)sender { _renderer.scene->cb.kLightScale *= 1.025f; [_renderer relight]; [_sidebar refresh]; }
- (void)darker:(id)sender { _renderer.scene->cb.kLightScale *= 0.975f; [_renderer relight]; [_sidebar refresh]; }

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
            if ([[NSFileManager defaultManager] fileExistsAtPath:shape]) [self->_renderer selectShape:shape];
        }
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
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
