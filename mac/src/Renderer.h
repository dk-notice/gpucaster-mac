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

// A value a shape file declares as adjustable, with a line like
//     // param: twist = 0.3 (0 to 1)
// The app shows it as a slider, and the shape code uses the name as a number.
@interface ShapeParam : NSObject
@property (nonatomic, copy) NSString *name;        // as written in the file, e.g. "fold_radius"
@property (nonatomic, readonly) NSString *label;   // for display, e.g. "Fold radius"
@property (nonatomic) float defaultValue, minValue, maxValue;
@property (nonatomic) BOOL integer;                // whole numbers only
@property (nonatomic) int slot;                    // where its value is stored (0..39)
@end

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
// occlusion - and the same again for reflected rays if the surface is
// reflective - and stop when the picture is finished.
@property (nonatomic) BOOL autoEnabled;
@property (nonatomic) int autoGeomPasses;     // geometry passes in an automatic run
@property (nonatomic) int autoAmboPasses;     // ambient occlusion passes in an automatic run
@property (nonatomic) BOOL paused;            // hold the work without losing it
- (void)refineMore;                           // more ambient passes on a finished picture

// Shows the picture lit by one light alone (0-based), or -1 for all of them.
// Only what is displayed changes; the scene itself is untouched.
@property (nonatomic) int soloLight;

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
- (NSArray<NSString *> *)availableShapes;                      // built-in ones, then your own
- (NSArray<NSString *> *)builtInShapes;                        // full paths, sorted by name
- (NSArray<NSString *> *)userShapes;
// Shapes you make are kept in a "Gpucaster Shapes" folder in Documents, apart
// from the ones that come with the app.  The folder is only looked at once it
// has been used, so the app doesn't ask for access to Documents needlessly.
@property (nonatomic, readonly) NSString *userShapesDir;
- (BOOL)prepareUserShapesDir;                                  // creates it if needed; NO if that failed
// YES for a shape inside the app itself, which must not be edited in place.
- (BOOL)shapeIsReadOnly:(NSString *)path;
- (void)selectShape:(NSString *)path;                          // compiles it, then starts again
- (void)selectShape:(NSString *)path keepParamValues:(BOOL)keep;   // keep = values came from a scene file
// The adjustable values the current shape declares.
@property (nonatomic, readonly) NSArray<ShapeParam *> *shapeParams;
@property (nonatomic, readonly) NSInteger shapeParamsVersion;      // changes whenever the list does
- (float)valueOfParam:(ShapeParam *)param;
- (void)setValue:(float)value ofParam:(ShapeParam *)param;         // then starts the picture again
- (void)resetShapeParams;
+ (NSArray<ShapeParam *> *)paramsInShape:(NSString *)path;       // the adjustable values a shape file declares
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

// --- Experimental options ---------------------------------------------------
// Relaxed arithmetic in the shaders: usually faster, but can change the
// picture slightly.  Changing it recompiles the shaders.
@property (nonatomic) BOOL fastMath;
// 1 = full detail; 2 = render at half the window's resolution (a quarter of
// the pixels) and enlarge the result to fit.
@property (nonatomic) int detailDivisor;
// Passes completed per second, measured over the last few seconds (0 if unknown).
@property (nonatomic, readonly) double passesPerSecond;

// --- Status -----------------------------------------------------------------
@property (nonatomic, readonly) GenMode stage;
@property (nonatomic, readonly) BOOL onReflection;
@property (nonatomic, readonly) BOOL autoRunning;
@property (nonatomic, readonly) BOOL finished;      // nothing left to do
@property (nonatomic, readonly) double progress;    // 0..1 through an automatic run; -1 when run by hand
@property (nonatomic, readonly) int geomPasses;
@property (nonatomic, readonly) int amboPasses;
@property (nonatomic, readonly) BOOL normalsReady;
@property (nonatomic, readonly) int imageWidth;
@property (nonatomic, readonly) int imageHeight;
- (NSString *)statusText;

// --- Output -----------------------------------------------------------------
// Small pictures of the current scene under each of the given lightings.
- (NSArray<NSImage *> *)thumbnailsForLightings:(const std::vector<Lighting> &)lightings width:(int)width;
- (BOOL)saveImageToPNG:(NSString *)path;

// --- Large pictures ---------------------------------------------------------
// Whether this Mac's graphics card can hold a picture of this size.
- (BOOL)canRenderWidth:(int)width height:(int)height;
// A separate renderer with a copy of this one's scene, shape and quality
// settings, set up to build the same picture at another size by itself.
- (Renderer *)exportCopyWithWidth:(int)width height:(int)height;
// Does a slice of work without waiting for it; calls back on the main thread
// with how long the graphics card took.
- (void)stepOffscreenTiles:(int)tiles completion:(void (^)(double gpuSeconds))completion;

// --- Off-screen use (self-test) ---------------------------------------------
- (void)setImageWidth:(int)width height:(int)height;
- (void)runPasses:(int)passes;        // runs whole passes of the current stage and waits
- (BOOL)runUntilFinished:(int)maxPasses;   // runs an automatic run to the end; NO if it did not finish
// Reads back the stored data for one pixel of the primary rays (for checking results).
- (void)readPixelX:(int)x y:(int)y depth:(float *)depth normal:(simd_float4 *)normal ambo:(simd_float4 *)ambo;

@end
