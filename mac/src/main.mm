// Gpucaster for macOS: app start-up, window, menus and input.
//
// Run with "--selftest <file.png>" to render one frame off-screen, save it,
// and exit without opening a window.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#import "Renderer.h"

static const MTLPixelFormat kViewFormat = MTLPixelFormatBGRA8Unorm;

#pragma mark - View

@interface RenderView : MTKView
@property (nonatomic, strong) Renderer *renderer;
@property (nonatomic, copy) void (^onReload)(void);
@end

@implementation RenderView
- (BOOL)acceptsFirstResponder { return YES; }
- (void)mouseDragged:(NSEvent *)e { [self.renderer dragByX:e.deltaX y:e.deltaY]; }
- (void)keyDown:(NSEvent *)e {
    if (e.keyCode == 96 /* F5, as in the Windows version */ && self.onReload) {
        self.onReload();
    } else {
        [super keyDown:e];
    }
}
@end

#pragma mark - App

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow *_window;
    RenderView *_view;
    Renderer *_renderer;
    NSTimer *_titleTimer;
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

    _renderer = [[Renderer alloc] initWithDevice:device pixelFormat:kViewFormat];

    NSRect frame = NSMakeRect(0, 0, 1024, 640);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.title = @"Gpucaster";
    _window.releasedWhenClosed = NO;
    [_window center];

    _view = [[RenderView alloc] initWithFrame:frame device:device];
    _view.colorPixelFormat = kViewFormat;
    _view.clearColor = MTLClearColorMake(0, 0, 0, 1);
    _view.renderer = _renderer;
    _view.delegate = _renderer;
    __weak AppDelegate *weakSelf = self;
    _view.onReload = ^{ [weakSelf reloadShaders:nil]; };
    _window.contentView = _view;
    [_window makeFirstResponder:_view];

    [self buildMenus];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    _titleTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   target:self
                                                 selector:@selector(updateTitle)
                                                 userInfo:nil
                                                  repeats:YES];
    if (_renderer.lastError) [self showShaderError];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)buildMenus {
    NSMenu *bar = [NSMenu new];

    NSMenuItem *appItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"About Gpucaster" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Gpucaster" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItemWithTitle:@"Quit Gpucaster" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *viewItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *reload = [viewMenu addItemWithTitle:@"Reload Shaders" action:@selector(reloadShaders:) keyEquivalent:@"r"];
    reload.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    [viewMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]
        .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    viewItem.submenu = viewMenu;

    NSMenuItem *windowItem = [bar addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    windowItem.submenu = windowMenu;
    NSApp.windowsMenu = windowMenu;

    NSApp.mainMenu = bar;
}

- (void)reloadShaders:(id)sender {
    if (![_renderer reloadShaders]) [self showShaderError];
    [self updateTitle];
}

- (void)showShaderError {
    NSAlert *a = [NSAlert new];
    a.alertStyle = NSAlertStyleWarning;
    a.messageText = @"Shader problem";
    a.informativeText = _renderer.lastError ?: @"Unknown error.";
    [a beginSheetModalForWindow:_window completionHandler:nil];
}

- (void)updateTitle {
    CGSize s = _renderer.drawableSize;
    NSString *state = _renderer.lastError ? @"shader error" : @"placeholder scene";
    _window.title = [NSString stringWithFormat:@"Gpucaster — %.0f x %.0f — %@ — %.0f fps",
                                               s.width, s.height, state, _renderer.fps];
}

@end

#pragma mark - Entry point

static int RunSelfTest(NSString *outPath) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { fprintf(stderr, "selftest: no Metal device\n"); return 1; }
    Renderer *r = [[Renderer alloc] initWithDevice:device pixelFormat:kViewFormat];
    if (r.lastError) { fprintf(stderr, "selftest: %s\n", r.lastError.UTF8String); return 1; }
    if (![r renderToPNG:outPath width:800 height:500]) {
        fprintf(stderr, "selftest: render or save failed\n");
        return 1;
    }
    printf("selftest: ok (%s, shaders from %s) -> %s\n",
           device.name.UTF8String, r.shaderDir.UTF8String, outPath.UTF8String);
    return 0;
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
