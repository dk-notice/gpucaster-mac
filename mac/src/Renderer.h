// Renderer: owns the Metal objects and runs the rendering stages.
//
// A picture is built in stages, each made of repeated passes over the image:
//   1. Geometry - find how far away the surface is at each pixel.
//   2. Normals  - find which way the surface faces.
//   3. Ambient occlusion - estimate how much light reaches each point.
// A cheap "relight" step then turns that data into the coloured picture.
// The same three stages can be repeated for one bounce of reflected rays.

#import <Cocoa/Cocoa.h>
#import <MetalKit/MetalKit.h>
#include "SceneState.h"

typedef NS_ENUM(int, GenMode) {
    GenGeom = 0,
    GenNormals = 1,
    GenAmbo = 2,
    GenNone = 3,
};

static const int kNumVizModes = 7;
extern NSString *const kVizModeNames[kNumVizModes];

@interface Renderer : NSObject <MTKViewDelegate>

- (instancetype)initWithDevice:(id<MTLDevice>)device;

// The scene being rendered.  After changing it, call -clearAll (shape or
// camera changed) or -relight (only lighting changed).
@property (nonatomic, readonly) SceneState *scene;

// --- Commands ---------------------------------------------------------------
- (void)setStage:(GenMode)mode;       // switch stage at the end of the current pass
- (void)toggleReflection;             // work on reflection rays / primary rays
- (void)clearAll;                     // throw away all results and start again
- (void)relight;                      // redo only the lighting
- (void)newSeed:(uint32_t)seed;       // new random scene, then start again
- (void)sceneReplaced;                // a scene file was loaded into -scene
- (void)setVizMode:(int)mode;

// When on, stages advance by themselves: geometry, normals, then ambient
// occlusion, and stop when the picture is finished.
@property (nonatomic) BOOL autoEnabled;

// --- Mouse ------------------------------------------------------------------
// What dragging moves: -1 = camera, 0..MAX_LIGHTS-1 = that light, 9 = all lights.
@property (nonatomic) int mouseTarget;
// dx, dy are fractions of the view size (dx positive = leftwards, dy positive = downwards).
- (void)dragPrimaryDX:(float)dx dy:(float)dy shift:(BOOL)shift control:(BOOL)control;
- (void)dragSecondaryDX:(float)dx dy:(float)dy shift:(BOOL)shift;
- (void)dolly:(float)amount;          // move the camera forwards (+) or backwards (-)

// --- Shapes -----------------------------------------------------------------
// A shape is a .metal file containing the Eval() function that defines the
// world.  The built-in ones live in the "shapes" folder inside shaderDir.
@property (nonatomic, readonly) NSString *shapePath;           // the shape in use (full path)
@property (nonatomic, readonly) NSString *shapesDir;
- (NSArray<NSString *> *)availableShapes;                      // full paths, sorted by name
- (void)selectShape:(NSString *)path;                          // compiles it, then starts again
+ (NSString *)displayNameForShape:(NSString *)path;            // "fractal_dodecahedron.metal" -> "Fractal dodecahedron"
// Compiles a shape without using it.  Returns nil if it is fine, else the error.
- (NSString *)compileErrorForShape:(NSString *)path;

// --- Shaders ----------------------------------------------------------------
@property (nonatomic, readonly) NSString *shaderDir;   // nil if not found
@property (nonatomic, readonly) NSString *lastError;   // nil if the last compile worked
@property (nonatomic, readonly) BOOL compiling;
@property (nonatomic, copy) void (^onShaderResult)(NSString *errorOrNil);
- (BOOL)reloadShadersNow;             // blocks until compiled
- (void)reloadShadersInBackground;
- (void)reloadShadersIfFilesChanged;  // call this regularly

// --- Status -----------------------------------------------------------------
@property (nonatomic, readonly) GenMode stage;
@property (nonatomic, readonly) BOOL onReflection;
@property (nonatomic, readonly) BOOL autoRunning;
@property (nonatomic, readonly) int geomPasses;
@property (nonatomic, readonly) int amboPasses;
@property (nonatomic, readonly) BOOL normalsReady;
@property (nonatomic, readonly) int imageWidth;
@property (nonatomic, readonly) int imageHeight;
- (NSString *)statusText;

// --- Output -----------------------------------------------------------------
- (BOOL)saveImageToPNG:(NSString *)path;

// --- Off-screen use (self-test) ---------------------------------------------
- (void)setImageWidth:(int)width height:(int)height;
- (void)runPasses:(int)passes;        // runs whole passes of the current stage and waits
// Reads back the stored data for one pixel of the primary rays (for checking results).
- (void)readPixelX:(int)x y:(int)y depth:(float *)depth normal:(simd_float4 *)normal ambo:(simd_float4 *)ambo;

@end
