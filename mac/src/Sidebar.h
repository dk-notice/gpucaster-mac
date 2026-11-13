// Sidebar: the panel of lighting controls beside the picture.
// (Replaces the floating "lighting dialog" of the Windows version.)

#import <Cocoa/Cocoa.h>
#import "Renderer.h"

@interface Sidebar : NSView

- (instancetype)initWithRenderer:(Renderer *)renderer;

// Re-reads every control from the scene.  Call after anything else changes
// the lighting (random lighting, opening a scene, dragging a light).
- (void)refresh;

// Rebuilds the Shape section if the shape or its adjustable values changed.
// Cheap to call often.
- (void)syncShapeParams;

// Called just before a control changes the scene, so the app can record an
// undo step.  'name' identifies the control (nil for one-off actions), so that
// one drag of a slider becomes one step.
@property (nonatomic, copy) void (^willChange)(NSString *name);

// Called after "Randomize all lighting".
@property (nonatomic, copy) void (^didRandomizeLighting)(void);

// Which light the "Light" section edits (0-based).
@property (nonatomic) int selectedLight;

@end
