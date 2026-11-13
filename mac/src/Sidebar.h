// Sidebar: the panel of lighting controls beside the picture.
// (Replaces the floating "lighting dialog" of the Windows version.)

#import <Cocoa/Cocoa.h>
#import "Renderer.h"

// Diagnostic log, for tracking down problems that only show with a real mouse.
// Lines are appended to ~/Library/Logs/Gpucaster/debug.log.  Does nothing
// unless switched on with GCLogEnable().
void GCLogEnable(void);
void GCLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
NSString *GCLogPath(void);

@interface Sidebar : NSView

// A short description of a view for the log ("slider Wrap", "button Random colour").
- (NSString *)describeView:(NSView *)view;

- (instancetype)initWithRenderer:(Renderer *)renderer;

// Re-reads every control from the scene.  Call after anything else changes
// the lighting (random lighting, opening a scene, dragging a light).
- (void)refresh;

// Brings the light list and direction ball up to date (their wording depends
// on the camera, so this is called regularly).  Cheap.
- (void)syncLights;

// Experimental options (half detail, fast math): load the saved choices at
// launch, and keep the ticks and the speed reading current.
- (void)applySavedExperimentalOptions;
- (void)syncExperimental;
- (void)expandAllForSnapshot;   // testing aid: open the collapsible groups and scroll to them

// Rebuilds the Shape section if the shape or its adjustable values changed.
// Cheap to call often.
- (void)syncShapeParams;

// Called just before a control changes the scene, so the app can record an
// undo step.  'name' identifies the control (nil for one-off actions), so that
// one drag of a slider becomes one step.
@property (nonatomic, copy) void (^willChange)(NSString *name);

// Called after "Randomize all lighting".
@property (nonatomic, copy) void (^didRandomizeLighting)(void);

// The strip of recent lightings: small pictures, newest first.
- (void)setLightingHistory:(NSArray<NSImage *> *)images;
@property (nonatomic, copy) void (^onPickLighting)(NSInteger index);   // one was clicked
@property (nonatomic, copy) void (^onKeepLighting)(void);              // "Keep current" was clicked

// For testing without a person: moves every slider through the same path a
// mouse drag takes and checks the scene value follows, and checks that each
// visible control is the thing a click at its centre would land on.
// Returns a report; lines starting "PROBLEM" are failures.
- (NSString *)checkControls;

// Which light the "Light" section edits (0-based).
@property (nonatomic) int selectedLight;

@end
