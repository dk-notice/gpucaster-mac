// Controls for seeing and setting where the lights shine from.
//
// Every light in Gpucaster is like the sun: it has a direction but no
// position.  So "where a light is" means which side of the scene it shines
// from, as seen from the camera.

#import <Cocoa/Cocoa.h>
#import "Renderer.h"

static const int kNumEditableLights = 5;   // the shaders light the scene with the first five

// The direction from the scene towards light 'i', in the camera's terms:
// .x = to the right, .y = upwards, .z = away from the camera.  So a light with
// negative z is on the camera's side, lighting the front of things.
simd_float3 LightDirectionInView(SceneState *scene, int i);

// The reverse: points light 'i' so that it shines from that direction.
void SetLightDirectionInView(SceneState *scene, int i, simd_float3 toLight);

// A few plain words for where a light shines from, e.g. "Upper left, in front".
NSString *DescribeLightDirection(simd_float3 toLight);

// How bright a light is (its strongest colour channel); 0 means off.
float LightBrightness(SceneState *scene, int i);

// The light's colour at full brightness, for showing in a swatch.
NSColor *LightDisplayColor(SceneState *scene, int i);

// A ball standing in for the scene as the camera sees it, with one dot per
// light showing where it shines from.  Solid dots light the front; hollow
// ones shine from behind.  Drag a dot to move its light; double-click to flip
// it between front and behind.
@interface LightBallView : NSView
@property (nonatomic, weak) Renderer *renderer;
@property (nonatomic) int selectedLight;
@property (nonatomic, copy) void (^onSelect)(int light);
@property (nonatomic, copy) void (^onWillChange)(void);   // about to move a light
@property (nonatomic, copy) void (^onChanged)(void);      // moved one
@end

// A button that reports being pressed and released, for "hold to show".
@interface HoldButton : NSButton
@property (nonatomic, copy) void (^onPress)(void);
@property (nonatomic, copy) void (^onRelease)(void);
@end
