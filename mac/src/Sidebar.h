// Sidebar: the panel of lighting controls beside the picture.
// (Replaces the floating "lighting dialog" of the Windows version.)

#import <Cocoa/Cocoa.h>
#import "Renderer.h"

@interface Sidebar : NSView

- (instancetype)initWithRenderer:(Renderer *)renderer;

// Re-reads every control from the scene.  Call after anything else changes
// the lighting (random lighting, opening a scene, dragging a light).
- (void)refresh;

// Which light the "Light" section edits (0-based).
@property (nonatomic) int selectedLight;

@end
