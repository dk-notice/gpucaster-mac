// Renderer: owns the Metal objects and draws each frame.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>

@interface Renderer : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)format;

// Re-reads and recompiles the shader file. On failure, returns NO, fills in
// lastError, and keeps drawing with the previous working shader.
- (BOOL)reloadShaders;

// Mouse drag, in screen points.
- (void)dragByX:(double)dx y:(double)dy;

// Renders one frame off-screen and saves it as a PNG. Used by the self-test.
- (BOOL)renderToPNG:(NSString *)path width:(int)width height:(int)height;

@property (nonatomic, readonly) NSString *lastError;   // nil if the last reload worked
@property (nonatomic, readonly) NSString *shaderDir;   // nil if not found
@property (nonatomic, readonly) double fps;
@property (nonatomic, readonly) CGSize drawableSize;   // in pixels

@end
