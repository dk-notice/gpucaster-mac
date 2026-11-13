#import "Renderer.h"
#import <ImageIO/ImageIO.h>
#import <MetalFX/MetalFX.h>
#include <algorithm>
#include <random>
#include <vector>

NSString *const kVizModeNames[kNumVizModes] = {
    @"Final colour", @"Depth", @"Depth stripes", @"Normals",
    @"Normal stripes", @"Normal sample coverage", @"Reflectivity",
};

static NSString *const kMasterShader = @"gpucaster.metal";
static NSString *const kShapeInclude = @"@shape";     // stands for the chosen shape file
static NSString *const kDefaultShape = @"blobs.metal";
static NSString *const kShapeDefaultsKey = @"ShapePath";
static NSString *const kUserShapesUsedKey = @"UserShapesFolderUsed";
static NSString *const kUserShapesFolderName = @"Gpucaster Shapes";
static const int kTileEdge = 128;             // pixels; the app decides how many tiles to draw per frame
// Work is handed to the graphics card in slices, one after another, so the
// card is always busy.  Each slice aims to take this long.  Longer slices get
// more done (every slice has a fixed cost), so they are long while nothing is
// being touched, and short while the camera or a control is being moved, when
// a quick response matters more.
static const double kSliceSeconds = 0.030;
static const double kSliceSecondsInteracting = 0.008;
static const double kInteractingFor = 0.5;       // seconds after the last input that count as "moving"
static const int kSlicesInFlight = 2;            // slices queued at once, so the card never waits for the next
static const int kTileStride = 1280;          // bytes between tiles in the per-tile buffer (>= sizeof(TileUniforms))

static const uint32_t CLEAR_GEOM = 1, CLEAR_NORM = 2, CLEAR_AMBO = 4, CLEAR_ALL = 0xFFFFFFFF;

@implementation ShapeParam
- (NSString *)label {
    NSString *s = [self.name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    return s.length ? [[[s substringToIndex:1] uppercaseString] stringByAppendingString:[s substringFromIndex:1]] : s;
}
@end

// Compiled shaders for each stage, and what the shape file declared.
@interface Pipelines : NSObject
@property (nonatomic, strong) id<MTLRenderPipelineState> geom, norm, ambo, relight, display;
@property (nonatomic, strong) id<MTLRenderPipelineState> relightHDR, displayHDR;   // for extended brightness
@property (nonatomic, strong) NSArray<ShapeParam *> *params;
@property (nonatomic, copy) NSString *shapePath;   // the shape file these were compiled from
@end
@implementation Pipelines
@end

// The data for one set of rays: the primary rays from the camera ("main"),
// or the rays reflected off the first surface they hit ("refl").
struct IntersectionSet {
    id<MTLTexture> depth[2];   // two, because each geometry pass reads one and writes the other
    id<MTLTexture> norm;
    id<MTLTexture> ambo;
    bool     initialized = false;
    GenMode  gen = GenGeom;        // stage being worked on
    GenMode  next = GenGeom;       // stage to switch to when the current pass finishes
    int      tile = 0;             // next tile to draw in the current pass
    uint32_t frame = 0;            // counts tiles drawn; used to vary random choices
    bool     ambo_dirty = false;   // geometry or normals changed since ambient occlusion was computed
    uint32_t clear_flags = CLEAR_ALL;
    bool     normals_ready = false;
    int      ambo_pass = 0;
    int      geom_passes = 0;
    int      which = 0;            // which depth texture is being written
};

@interface Renderer ()
@property (nonatomic, readwrite) NSString *shaderDir;
@property (nonatomic, readwrite) NSString *shapePath;
@property (nonatomic, readwrite) NSArray<ShapeParam *> *shapeParams;
@property (nonatomic, readwrite) NSInteger shapeParamsVersion;
@property (nonatomic, readwrite) NSString *lastError;
@property (nonatomic, readwrite) BOOL compiling;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    Pipelines *_pipelines;
    SceneState _scene;

    id<MTLTexture> _noiseCube[4];
    id<MTLTexture> _noise2d;
    id<MTLTexture> _amboDirs;
    id<MTLTexture> _normalDirs;
    id<MTLTexture> _dummy;         // stands in for textures that don't exist yet
    id<MTLTexture> _final;         // the finished picture
    id<MTLSamplerState> _linearWrap, _nearestWrap, _nearestClamp, _linearClamp;

    IntersectionSet _main, _refl;
    IntersectionSet *_cur;
    int _width, _height;
    BOOL _relightWhole;
    BOOL _displayDirty;            // the window needs the picture copied to it again
    int _slicesInFlight;           // work slices handed to the graphics card and not yet finished
    std::vector<CFTimeInterval> _passEnds;   // when recent passes finished, for measuring speed
    id<MTLFXSpatialScaler> _scaler;          // MetalFX upscaler for Half detail, made when first needed
    id<MTLTexture> _upscaled;                // its output: the picture at the window's full size
    BOOL _viewIsEDR;                         // how the window is currently set up
    BOOL _edrPossible;                       // the screen can show extended brightness
    CFTimeInterval _lastInput;     // when the camera, a light or a setting was last changed
    BOOL _autoActive;
    BOOL _autoFinishedMain;        // the automatic run completed the primary rays
    int _amboTarget;               // ambient passes to reach for the primary rays (grows with "refine more")
    NSUInteger _compileGeneration; // counts compile requests; only the newest one's result is used
    int _compilesInFlight;
    NSString *_adoptedShapePath;   // the shape the shaders in use were compiled from
    NSString *_keepSlotsForShape;  // a scene file just supplied the values for this shape: leave them alone
    // How many tiles to draw per frame, learned separately for each stage
    // (geometry, normals, ambient occlusion), because their costs differ hugely.
    double _tilesForStage[3];
    NSTimeInterval _shaderStamp;
    std::mt19937 _timeRng;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _queue = [device newCommandQueue];
        _cur = &_main;
        _mouseTarget = -1;
        _soloLight = -1;
        _detailDivisor = 1;
        _autoEnabled = YES;
        _autoActive = YES;
        _autoGeomPasses = 40;
        _autoAmboPasses = 16;
        _amboTarget = _autoAmboPasses;
        [self forgetTileBudgets];
        _shaderDir = [Renderer findShaderDir];
        _shapePath = [self initialShape];
        _shaderStamp = [self latestShaderModification];

        [self makeSamplers];
        [self makeFixedTextures];
        [self uploadNoise];
        [self reloadShadersNow];
    }
    return self;
}

- (SceneState *)scene { return &_scene; }

#pragma mark - Large pictures

// Memory needed per pixel: two depth textures, normals, ambient occlusion and
// the finished picture, for primary rays and (possibly) reflected rays.
static const double kBytesPerPixel = 2 * (4 + 4 + 8 + 8) + 4;

- (BOOL)canRenderWidth:(int)width height:(int)height {
    if (width < 16 || height < 16 || width > 16384 || height > 16384) return NO;
    double bytes = (double)width * height * kBytesPerPixel;
    return bytes < 0.6 * (double)_device.recommendedMaxWorkingSetSize;
}

- (Renderer *)exportCopyWithWidth:(int)width height:(int)height {
    Renderer *r = [[Renderer alloc] initAsCopyOf:self];
    [r setImageWidth:width height:height];
    return r;
}

// Shares the compiled shaders and fixed textures of 'o', and copies its scene.
- (instancetype)initAsCopyOf:(Renderer *)o {
    if ((self = [super init])) {
        _device = o->_device;
        _queue = [_device newCommandQueue];
        _cur = &_main;
        _mouseTarget = -1;
        _soloLight = -1;
        _detailDivisor = 1;
        _autoEnabled = YES;
        _autoActive = YES;
        _autoGeomPasses = o.autoGeomPasses;
        _autoAmboPasses = o.autoAmboPasses;
        _amboTarget = _autoAmboPasses;
        [self forgetTileBudgets];
        _shaderDir = o.shaderDir;
        _shapePath = o.shapePath;
        _shaderStamp = o->_shaderStamp;
        _shapeParams = o.shapeParams;
        // An export is the finished picture, so it never uses the shortcuts the
        // window may be previewing with: no fast math, no skipping of empty sky.
        _fastMath = NO;
        _skipEmptySky = NO;
        _pipelines = o->_pipelines;
        _adoptedShapePath = o->_adoptedShapePath;
        if (o->_fastMath) {
            // The window's shaders were compiled with fast math; compile accurate ones for the export.
            NSString *err = nil;
            Pipelines *accurate = [Renderer buildPipelinesWithDevice:_device dir:_shaderDir shape:_shapePath fastMath:NO error:&err];
            if (accurate) _pipelines = accurate;
            else self.lastError = err;
        }
        _scene = o->_scene;
        _scene.cb.g_viz_mode = 0;
        _linearWrap = o->_linearWrap;
        _nearestWrap = o->_nearestWrap;
        _nearestClamp = o->_nearestClamp;
        _linearClamp = o->_linearClamp;
        _amboDirs = o->_amboDirs;
        _normalDirs = o->_normalDirs;
        _dummy = o->_dummy;
        [self uploadNoise];
    }
    return self;
}

- (void)stepOffscreenTiles:(int)tiles completion:(void (^)(double gpuSeconds))completion {
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self stepInto:cb maxTiles:MAX(tiles, 1) honourPause:NO];
    [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
        double seconds = done.GPUEndTime - done.GPUStartTime;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(seconds); });
    }];
    [cb commit];
}

#pragma mark - Shaders

// A copy of the shaders is inside the app.  When the app is run from its
// source folder, the "shaders" folder next to (or a few levels above) it is
// used instead, so the originals can be edited.
+ (NSString *)findShaderDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *env = getenv("GPUCASTER_SHADER_DIR");
    if (env && *env) return [NSString stringWithUTF8String:env];

    NSString *dir = [[NSBundle mainBundle] bundlePath];
    for (int i = 0; i < 5; i++) {
        dir = [dir stringByDeletingLastPathComponent];
        NSString *candidate = [dir stringByAppendingPathComponent:@"shaders"];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:kMasterShader]])
            return candidate;
    }

    // Otherwise use the copy inside the app.
    NSString *bundled = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"shaders"];
    if ([fm fileExistsAtPath:[bundled stringByAppendingPathComponent:kMasterShader]]) return bundled;
    return nil;
}

// Reads a shader file and pastes in the files it #includes (Metal can't do
// that itself when compiling from text).  "#line" markers keep error messages
// pointing at the right file and line.
+ (NSString *)expandFile:(NSString *)name
                     dir:(NSString *)dir
                   shape:(NSString *)shapePath
                  params:(NSArray<ShapeParam *> *)params
                    seen:(NSMutableSet *)seen
                   error:(NSString **)error {
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSMutableString *before = [NSMutableString string], *after = [NSMutableString string];
    if ([name isEqualToString:kShapeInclude]) {
        // Each declared parameter becomes a name the shape code can use as a
        // number.  The names are removed again after the shape, so they can't
        // clash with the rest of the shader code.
        static const char comp[4] = {'x', 'y', 'z', 'w'};
        for (ShapeParam *p in params) {
            [before appendFormat:@"#define %@ (g_dialog_coeffs[%d].%c)\n", p.name, p.slot / 4, comp[p.slot % 4]];
            [after appendFormat:@"#undef %@\n", p.name];
        }
        if (!shapePath) {
            if (error) *error = @"No shape file is selected.";
            return nil;
        }
        path = shapePath;
        name = shapePath.lastPathComponent;
    }
    NSError *err = nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!text) {
        if (error) *error = [NSString stringWithFormat:@"Could not read %@:\n%@", path, err.localizedDescription];
        return nil;
    }
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@#line 1 \"%@\"\n", before, name];
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"#include \""]) {
            NSRange open = [trimmed rangeOfString:@"\""];
            NSString *rest = [trimmed substringFromIndex:open.location + 1];
            NSRange close = [rest rangeOfString:@"\""];
            if (close.location != NSNotFound) {
                NSString *inc = [rest substringToIndex:close.location];
                if (![seen containsObject:inc]) {
                    [seen addObject:inc];
                    NSString *body = [self expandFile:inc dir:dir shape:shapePath params:params seen:seen error:error];
                    if (!body) return nil;
                    [out appendString:body];
                    [out appendFormat:@"\n#line %lu \"%@\"\n", (unsigned long)(i + 2), name];
                } else {
                    [out appendString:@"\n"];
                }
                continue;
            }
        }
        [out appendString:line];
        [out appendString:@"\n"];
    }
    [out appendString:after];
    return out;
}

// Finds the "// param: name = default (min to max)" lines in a shape file.
+ (NSArray<ShapeParam *> *)paramsInShape:(NSString *)shapePath {
    NSMutableArray<ShapeParam *> *params = [NSMutableArray array];
    NSString *text = shapePath ? [NSString stringWithContentsOfFile:shapePath encoding:NSUTF8StringEncoding error:nil] : nil;
    if (!text) return params;
    NSString *num = @"(-?[0-9]*\\.?[0-9]+)";
    NSString *pattern = [NSString stringWithFormat:
        @"^\\s*//\\s*param:\\s*([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*%@\\s*\\(\\s*%@\\s*to\\s*%@\\s*\\)", num, num, num];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                        options:NSRegularExpressionAnchorsMatchLines
                                                                          error:nil];
    NSMutableSet *names = [NSMutableSet set];
    for (NSTextCheckingResult *m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
        if (params.count >= MAX_VECTOR_COEFFS * 4) break;
        ShapeParam *p = [ShapeParam new];
        p.name = [text substringWithRange:[m rangeAtIndex:1]];
        if ([names containsObject:p.name]) continue;
        [names addObject:p.name];
        NSString *d = [text substringWithRange:[m rangeAtIndex:2]];
        NSString *lo = [text substringWithRange:[m rangeAtIndex:3]];
        NSString *hi = [text substringWithRange:[m rangeAtIndex:4]];
        p.defaultValue = d.floatValue;
        p.minValue = MIN(lo.floatValue, hi.floatValue);
        p.maxValue = MAX(lo.floatValue, hi.floatValue);
        p.integer = ![d containsString:@"."] && ![lo containsString:@"."] && ![hi containsString:@"."];
        p.slot = (int)params.count;
        [params addObject:p];
    }
    return params;
}

+ (Pipelines *)buildPipelinesWithDevice:(id<MTLDevice>)device
                                    dir:(NSString *)dir
                                  shape:(NSString *)shapePath
                               fastMath:(BOOL)fastMath
                                  error:(NSString **)error {
    if (!dir) {
        if (error) *error = @"Could not find the shaders folder.";
        return nil;
    }
    NSArray<ShapeParam *> *params = [self paramsInShape:shapePath];
    NSString *src = [self expandFile:kMasterShader dir:dir shape:shapePath params:params seen:[NSMutableSet set] error:error];
    if (!src) return nil;

    MTLCompileOptions *opts = [MTLCompileOptions new];
    // Fractals are sensitive to tiny rounding differences, and the shaders rely
    // on exact handling of "not a number" values, so turn off risky optimisations.
    // (Relaxed arithmetic is available as an experimental option.)
    opts.mathMode = fastMath ? MTLMathModeFast : MTLMathModeSafe;

    NSError *err = nil;
    id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
    if (!lib) {
        if (error) *error = err.localizedDescription;
        return nil;
    }

    id<MTLFunction> vs = [lib newFunctionWithName:@"vs_fullscreen"];
    Pipelines *p = [Pipelines new];
    struct Spec {
        NSString *fn;
        MTLPixelFormat fmt;
        bool additive;
    } specs[7] = {
        {@"fs_geom", MTLPixelFormatR32Float, false},
        {@"fs_norm", MTLPixelFormatRGBA16Snorm, false},
        {@"fs_ambo", MTLPixelFormatRGBA16Float, true},   // each pass adds to the last
        {@"fs_relight", MTLPixelFormatBGRA8Unorm, false},
        {@"fs_display", MTLPixelFormatBGRA8Unorm, false},
        {@"fs_relight", MTLPixelFormatRGBA16Float, false},       // extended brightness
        {@"fs_display_hdr", MTLPixelFormatRGBA16Float, false},
    };
    id<MTLRenderPipelineState> states[7];
    for (int i = 0; i < 7; i++) {
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vs;
        pd.fragmentFunction = [lib newFunctionWithName:specs[i].fn];
        pd.colorAttachments[0].pixelFormat = specs[i].fmt;
        if (specs[i].additive) {
            pd.colorAttachments[0].blendingEnabled = YES;
            pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
            pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
        }
        if (!vs || !pd.fragmentFunction) {
            if (error) *error = [NSString stringWithFormat:@"Shader function %@ is missing.", specs[i].fn];
            return nil;
        }
        states[i] = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!states[i]) {
            if (error) *error = err.localizedDescription;
            return nil;
        }
    }
    p.geom = states[0];
    p.norm = states[1];
    p.ambo = states[2];
    p.relight = states[3];
    p.display = states[4];
    p.relightHDR = states[5];
    p.displayHDR = states[6];
    p.params = params;
    p.shapePath = shapePath;
    return p;
}

// Goes back to drawing one tile per frame until the cost of the current
// shaders has been measured.  Without this, a cheap shape followed by an
// expensive one would try to draw a whole pass in a single frame.
- (void)forgetTileBudgets {
    for (double &t : _tilesForStage) t = 1;
}

// Starts using freshly compiled shaders, and sets up the shape's adjustable values.
- (void)adoptPipelines:(Pipelines *)p {
    // Work out every value first, then store them, so that parameters whose
    // storage slots have moved don't trample each other.
    // Decided from which file the new shaders were actually compiled from,
    // not from what has been clicked since, so that picking shapes in quick
    // succession can't hand one shape another's values.
    const BOOL sameShape = _adoptedShapePath && [p.shapePath isEqualToString:_adoptedShapePath];
    const BOOL keepSlots = _keepSlotsForShape && [p.shapePath isEqualToString:_keepSlotsForShape];
    NSArray<ShapeParam *> *old = self.shapeParams;
    NSMutableArray<NSNumber *> *values = [NSMutableArray array];
    for (ShapeParam *param in p.params) {
        float value = param.defaultValue;                    // a different shape starts from its defaults
        if (keepSlots) {
            value = [self valueOfParam:param];               // came from a scene file: leave it alone
        } else if (sameShape) {
            // The same file was edited and saved: keep each value that still exists, by name.
            for (ShapeParam *o in old) {
                if ([o.name isEqualToString:param.name]) value = [self valueOfParam:o];
            }
            value = MIN(MAX(value, param.minValue), param.maxValue);
        }
        [values addObject:@(value)];
    }
    for (NSUInteger i = 0; i < p.params.count; i++) [self storeValue:values[i].floatValue ofParam:p.params[i]];
    _keepSlotsForShape = nil;
    _adoptedShapePath = p.shapePath;
    [self forgetTileBudgets];
    _pipelines = p;
    self.shapeParams = p.params ?: @[];
    self.shapeParamsVersion++;
    self.lastError = nil;
    [self clearAll];
}

- (float)valueOfParam:(ShapeParam *)param {
    return _scene.cb.g_dialog_coeffs[param.slot / 4][param.slot % 4];
}

- (void)storeValue:(float)value ofParam:(ShapeParam *)param {
    _scene.cb.g_dialog_coeffs[param.slot / 4][param.slot % 4] = value;
}

- (void)setValue:(float)value ofParam:(ShapeParam *)param {
    _lastInput = CACurrentMediaTime();
    [self storeValue:value ofParam:param];
    [self clearAll];
}

- (void)resetShapeParams {
    for (ShapeParam *param in self.shapeParams) [self storeValue:param.defaultValue ofParam:param];
    [self clearAll];
}

- (BOOL)reloadShadersNow {
    NSString *err = nil;
    ++_compileGeneration;   // anything still compiling in the background is now out of date
    Pipelines *p = [Renderer buildPipelinesWithDevice:_device dir:self.shaderDir shape:self.shapePath fastMath:_fastMath error:&err];
    _shaderStamp = [self latestShaderModification];
    if (p) {
        [self adoptPipelines:p];
    } else {
        self.lastError = err;
    }
    return p != nil;
}

// Compiles in the background and switches over when done.  Each request
// starts straight away; if another request is made before it finishes, the
// older result is thrown away when it arrives.
- (void)reloadShadersInBackground {
    const NSUInteger generation = ++_compileGeneration;
    _compilesInFlight++;
    self.compiling = YES;
    _shaderStamp = [self latestShaderModification];
    id<MTLDevice> device = _device;
    NSString *dir = self.shaderDir;
    NSString *shape = self.shapePath;
    const BOOL fastMath = _fastMath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        Pipelines *p = [Renderer buildPipelinesWithDevice:device dir:dir shape:shape fastMath:fastMath error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_compilesInFlight--;
            self.compiling = (self->_compilesInFlight > 0);
            if (generation != self->_compileGeneration) return;   // superseded by a newer request
            if (p) {
                [self adoptPipelines:p];
            } else {
                self.lastError = err;
            }
            if (self.onShaderResult) self.onShaderResult(p ? nil : err);
        });
    });
}

- (NSTimeInterval)latestShaderModification {
    if (!self.shaderDir) return 0;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSTimeInterval latest = 0;
    for (NSString *name in [fm contentsOfDirectoryAtPath:self.shaderDir error:nil]) {
        if (![name hasSuffix:@".metal"] && ![name hasSuffix:@".h"]) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:[self.shaderDir stringByAppendingPathComponent:name] error:nil];
        latest = MAX(latest, [attrs.fileModificationDate timeIntervalSinceReferenceDate]);
    }
    if (self.shapePath) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:self.shapePath error:nil];
        latest = MAX(latest, [attrs.fileModificationDate timeIntervalSinceReferenceDate]);
    }
    return latest;
}

- (void)reloadShadersIfFilesChanged {
    if ([self latestShaderModification] > _shaderStamp) [self reloadShadersInBackground];
}

#pragma mark - Shapes

- (NSString *)shapesDir { return self.shaderDir ? [self.shaderDir stringByAppendingPathComponent:@"shapes"] : nil; }

static NSArray<NSString *> *ShapesIn(NSString *dir) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    if (!dir) return paths;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if ([name hasSuffix:@".metal"] && ![name hasPrefix:@"."]) [paths addObject:[dir stringByAppendingPathComponent:name]];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    return paths;
}

- (NSArray<NSString *> *)builtInShapes { return ShapesIn(self.shapesDir); }

- (NSString *)userShapesDir {
    const char *env = getenv("GPUCASTER_USER_SHAPES");
    if (env && *env) return [NSString stringWithUTF8String:env];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:kUserShapesFolderName];
}

- (BOOL)userShapesInUse {
    return getenv("GPUCASTER_USER_SHAPES") != NULL || [[NSUserDefaults standardUserDefaults] boolForKey:kUserShapesUsedKey];
}

- (NSArray<NSString *> *)userShapes {
    return [self userShapesInUse] ? ShapesIn(self.userShapesDir) : @[];
}

- (BOOL)prepareUserShapesDir {
    NSString *dir = self.userShapesDir;
    if (!dir) return NO;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if (ok) [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserShapesUsedKey];
    return ok;
}

- (NSArray<NSString *> *)availableShapes {
    return [[self builtInShapes] arrayByAddingObjectsFromArray:[self userShapes]];
}

- (BOOL)shapeIsReadOnly:(NSString *)path {
    NSString *bundle = [[[NSBundle mainBundle] bundlePath] stringByStandardizingPath];
    return path && [[path stringByStandardizingPath] hasPrefix:[bundle stringByAppendingString:@"/"]];
}

+ (NSString *)displayNameForShape:(NSString *)path {
    NSString *name = [path.lastPathComponent stringByDeletingPathExtension];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    if (name.length == 0) return @"(none)";
    return [[[name substringToIndex:1] uppercaseString] stringByAppendingString:[name substringFromIndex:1]];
}

// The shape to start with: one named for testing, else the one used last
// time, else the default, else whatever is in the folder.
- (NSString *)initialShape {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const char *env = getenv("GPUCASTER_SHAPE");
    if (env && *env) {
        NSString *s = [NSString stringWithUTF8String:env];
        [candidates addObject:s];
        if (self.shapesDir) {
            [candidates addObject:[self.shapesDir stringByAppendingPathComponent:s]];
            [candidates addObject:[self.shapesDir stringByAppendingPathComponent:[s stringByAppendingString:@".metal"]]];
        }
    } else {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kShapeDefaultsKey];
        if (saved) [candidates addObject:saved];
    }
    if (self.shapesDir) [candidates addObject:[self.shapesDir stringByAppendingPathComponent:kDefaultShape]];
    for (NSString *c in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:c isDirectory:&isDir] && !isDir) return c;
    }
    return [self availableShapes].firstObject;
}

- (void)selectShape:(NSString *)path { [self selectShape:path keepParamValues:NO]; }

- (void)selectShape:(NSString *)path keepParamValues:(BOOL)keep {
    if (!path) return;
    // A shape in your own folder means the folder is in use; start listing it.
    if (self.userShapesDir && [path hasPrefix:[self.userShapesDir stringByAppendingString:@"/"]])
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kUserShapesUsedKey];
    _keepSlotsForShape = keep ? path : nil;
    self.shapePath = path;
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:kShapeDefaultsKey];
    [self reloadShadersInBackground];
}

- (NSString *)compileErrorForShape:(NSString *)path {
    NSString *err = nil;
    Pipelines *p = [Renderer buildPipelinesWithDevice:_device dir:self.shaderDir shape:path fastMath:_fastMath error:&err];
    return p ? nil : (err ?: @"Unknown error.");
}

#pragma mark - Textures

- (void)makeSamplers {
    MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeRepeat;
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    _linearWrap = [_device newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterNearest;
    _nearestWrap = [_device newSamplerStateWithDescriptor:sd];
    sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToEdge;
    _nearestClamp = [_device newSamplerStateWithDescriptor:sd];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    _linearClamp = [_device newSamplerStateWithDescriptor:sd];
}

// Loads a list of "x y z" directions from a text file into a one-row texture.
- (id<MTLTexture>)loadDirections:(NSString *)name count:(int)count {
    std::vector<float> data((size_t)count * 4, 0.0f);
    NSString *path = [self.shaderDir stringByAppendingPathComponent:name];
    FILE *f = path ? fopen(path.fileSystemRepresentation, "r") : NULL;
    int got = 0;
    if (f) {
        for (; got < count; got++) {
            float x, y, z;
            if (fscanf(f, "%f %f %f", &x, &y, &z) != 3) break;
            data[got * 4 + 0] = x;
            data[got * 4 + 1] = y;
            data[got * 4 + 2] = z;
        }
        fclose(f);
    }
    if (got < count) NSLog(@"Gpucaster: %@ is missing or incomplete (%d of %d directions).", name, got, count);

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:count height:1 mipmapped:NO];
    id<MTLTexture> tex = [_device newTextureWithDescriptor:td];
    [tex replaceRegion:MTLRegionMake2D(0, 0, count, 1) mipmapLevel:0 withBytes:data.data() bytesPerRow:(NSUInteger)count * 16];
    return tex;
}

- (void)makeFixedTextures {
    _amboDirs = [self loadDirections:@"ambo_ray_dirs.txt" count:AMBO_RAY_DIRS];
    _normalDirs = [self loadDirections:@"normal_dirs_512.txt" count:NORMAL_RAY_DIRS];

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:1 height:1 mipmapped:NO];
    _dummy = [_device newTextureWithDescriptor:td];
    uint16_t zero[4] = {0, 0, 0, 0};
    [_dummy replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:zero bytesPerRow:8];
}

// Sends the scene's random noise to the graphics card.  Call after the seed changes.
- (void)uploadNoise {
    const int n = kNoiseCubeEdge;
    for (int i = 0; i < 4; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.textureType = MTLTextureType3D;
        td.pixelFormat = MTLPixelFormatRGBA8Snorm;
        td.width = td.height = td.depth = n;
        _noiseCube[i] = [_device newTextureWithDescriptor:td];
        [_noiseCube[i] replaceRegion:MTLRegionMake3D(0, 0, 0, n, n, n)
                         mipmapLevel:0
                               slice:0
                           withBytes:_scene.noise.cube[i].data()
                         bytesPerRow:n * 4
                       bytesPerImage:n * n * 4];
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Unorm
                                                                                  width:NOISE_2D_SIZE
                                                                                 height:NOISE_2D_SIZE
                                                                              mipmapped:NO];
    _noise2d = [_device newTextureWithDescriptor:td];
    [_noise2d replaceRegion:MTLRegionMake2D(0, 0, NOISE_2D_SIZE, NOISE_2D_SIZE)
                mipmapLevel:0
                  withBytes:_scene.noise.noise2d.data()
                bytesPerRow:NOISE_2D_SIZE * 8];
}

- (id<MTLTexture>)makeTarget:(MTLPixelFormat)format shared:(BOOL)shared {
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:_width height:_height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    if (shared)
        td.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    else
        td.storageMode = MTLStorageModePrivate;
    return [_device newTextureWithDescriptor:td];
}

- (void)initSet:(IntersectionSet *)s {
    *s = IntersectionSet();
    s->depth[0] = [self makeTarget:MTLPixelFormatR32Float shared:NO];
    s->depth[1] = [self makeTarget:MTLPixelFormatR32Float shared:NO];
    s->norm = [self makeTarget:MTLPixelFormatRGBA16Snorm shared:NO];
    s->ambo = [self makeTarget:MTLPixelFormatRGBA16Float shared:NO];
    s->initialized = true;
}

- (void)setImageWidth:(int)width height:(int)height {
    width = MAX(width, 16);
    height = MAX(height, 16);
    if (width == _width && height == _height && _main.initialized) return;
    _width = width;
    _height = height;
    [self initSet:&_main];
    _refl = IntersectionSet();   // made again when reflections are next used
    _final = [self makeTarget:(_edrOutput ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm) shared:YES];
    _displayDirty = YES;
    [self clearAll];
}

#pragma mark - Commands

- (void)clearAll {
    _passEnds.clear();
    _cur = &_main;
    _main.clear_flags = CLEAR_ALL;
    _refl.clear_flags = CLEAR_ALL;
    _main.next = GenGeom;
    _refl.next = GenGeom;
    _relightWhole = YES;
    _autoActive = _autoEnabled;
    _autoFinishedMain = NO;
    _amboTarget = _autoAmboPasses;
}

- (void)relight {
    _lastInput = CACurrentMediaTime();
    _relightWhole = YES;
    [self startReflectionsIfWanted];
}

// Reflections only matter when the surface is reflective.
- (BOOL)wantsReflections { return _scene.cb.kReflectivity > 0.001f; }

- (BOOL)reflectionsComplete {
    return _refl.initialized && _refl.gen == GenNone && _refl.normals_ready && _refl.ambo_pass >= _autoAmboPasses;
}

// If the automatic run finished without reflections and the surface has since
// been made reflective, carry on and compute them.
- (void)startReflectionsIfWanted {
    if (!_autoEnabled || _autoActive || !_autoFinishedMain || _cur != &_main || _main.gen != GenNone) return;
    if (![self wantsReflections] || [self reflectionsComplete]) return;
    _autoActive = YES;
    [self autoBeginReflections];
}

- (void)autoBeginReflections {
    if (!_refl.initialized) [self initSet:&_refl];
    _refl.clear_flags = CLEAR_ALL;
    _refl.next = GenGeom;
    _cur = &_refl;
}

- (void)setStage:(GenMode)mode {
    _autoActive = NO;
    _autoFinishedMain = NO;   // the user has taken over
    if (mode == GenAmbo && !(_cur->normals_ready || _cur->gen == GenNormals)) return;   // needs normals first
    _cur->next = mode;
}

- (void)toggleReflection {
    _autoActive = NO;
    _autoFinishedMain = NO;
    if (_cur == &_main) {
        if (!_refl.initialized) [self initSet:&_refl];
        _cur = &_refl;
    } else {
        _cur = &_main;
    }
    _relightWhole = YES;
}

- (void)newSeed:(uint32_t)seed {
    _scene.OnSeed(seed);
    [self uploadNoise];
    [self clearAll];
}

- (void)sceneReplaced {
    [self uploadNoise];
    [self clearAll];
}

- (void)setFastMath:(BOOL)fastMath {
    if (fastMath == _fastMath) return;
    _fastMath = fastMath;
    [self reloadShadersInBackground];
}

- (void)setDetailDivisor:(int)detailDivisor {
    detailDivisor = MAX(1, MIN(detailDivisor, 4));
    if (detailDivisor == _detailDivisor) return;
    _detailDivisor = detailDivisor;
    _displayDirty = YES;   // the next screen refresh resizes the picture and starts it again
}

- (BOOL)edrAvailable { return _edrPossible; }

- (void)setEdrOutput:(BOOL)edrOutput {
    if (edrOutput == _edrOutput) return;
    _edrOutput = edrOutput;
    if (_main.initialized) {
        // The stored picture changes format: brighter-than-white needs more than 8 bits.
        _final = [self makeTarget:(_edrOutput ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm) shared:YES];
        _relightWhole = YES;
    }
    _displayDirty = YES;
}

// Sets the window up for ordinary or extended brightness, to match the option.
// Returns YES if it changed something (the next frame then uses the new setup).
- (BOOL)matchView:(MTKView *)view {
    NSScreen *screen = view.window.screen;
    _edrPossible = screen && screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1.05;
    const BOOL want = _edrOutput && _edrPossible;
    if (want == _viewIsEDR) return NO;
    _viewIsEDR = want;
    CAMetalLayer *layer = (CAMetalLayer *)view.layer;
    view.colorPixelFormat = want ? MTLPixelFormatRGBA16Float : MTLPixelFormatBGRA8Unorm;
    layer.wantsExtendedDynamicRangeContent = want;
    if (want) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
        layer.colorspace = cs;
        CGColorSpaceRelease(cs);
    } else {
        layer.colorspace = nil;
    }
    _displayDirty = YES;
    return YES;
}

- (float)brightestValueInPicture {
    if (!_final) return 0;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    _relightWhole = YES;
    [self stepInto:cb maxTiles:0];
    [cb commit];
    [cb waitUntilCompleted];
    const int w = (int)_final.width, h = (int)_final.height;
    float best = 0;
    if (_final.pixelFormat == MTLPixelFormatRGBA16Float) {
        std::vector<_Float16> px((size_t)w * h * 4);
        [_final getBytes:px.data() bytesPerRow:(NSUInteger)w * 8 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        for (size_t i = 0; i < px.size(); i += 4) best = MAX(best, MAX((float)px[i], MAX((float)px[i + 1], (float)px[i + 2])));
    } else {
        std::vector<uint8_t> px((size_t)w * h * 4);
        [_final getBytes:px.data() bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        for (size_t i = 0; i < px.size(); i += 4) best = MAX(best, MAX(px[i], MAX(px[i + 1], px[i + 2])) / 255.0f);
    }
    return best;
}

- (BOOL)sharpUpscaleAvailable { return [MTLFXSpatialScalerDescriptor supportsDevice:_device]; }

- (void)setSharpUpscale:(BOOL)sharpUpscale {
    if (sharpUpscale == _sharpUpscale) return;
    _sharpUpscale = sharpUpscale;
    _displayDirty = YES;
}

// Enlarges the finished picture to 'width' x 'height' with MetalFX and
// returns the result, or nil if that isn't possible (the caller then enlarges
// it the plain way).  The upscaler is rebuilt whenever either size changes.
- (id<MTLTexture>)upscaleInto:(id<MTLCommandBuffer>)cb width:(int)width height:(int)height {
    if (!_final || ![self sharpUpscaleAvailable] || width <= _width || height <= _height) return nil;
    if (_final.pixelFormat != MTLPixelFormatBGRA8Unorm) return nil;   // not while showing extended brightness
    if (!_scaler || (int)_scaler.inputWidth != _width || (int)_scaler.inputHeight != _height ||
        (int)_scaler.outputWidth != width || (int)_scaler.outputHeight != height) {
        MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
        d.inputWidth = (NSUInteger)_width;
        d.inputHeight = (NSUInteger)_height;
        d.outputWidth = (NSUInteger)width;
        d.outputHeight = (NSUInteger)height;
        d.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;   // the picture is already display-ready
        _scaler = [d newSpatialScalerWithDevice:_device];
        _upscaled = nil;
        if (!_scaler) return nil;
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        td.usage = _scaler.outputTextureUsage | MTLTextureUsageShaderRead;
        td.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
        _upscaled = [_device newTextureWithDescriptor:td];
    }
    if (!_upscaled) return nil;
    _scaler.colorTexture = _final;
    _scaler.outputTexture = _upscaled;
    _scaler.inputContentWidth = (NSUInteger)_width;
    _scaler.inputContentHeight = (NSUInteger)_height;
    [_scaler encodeToCommandBuffer:cb];
    return _upscaled;
}

- (void)setSoloLight:(int)soloLight {
    if (soloLight == _soloLight) return;
    _soloLight = soloLight;
    _relightWhole = YES;
}

- (void)setVizMode:(int)mode {
    _scene.cb.g_viz_mode = (uint32_t)((mode % kNumVizModes + kNumVizModes) % kNumVizModes);
    _relightWhole = YES;
}

- (void)setAutoEnabled:(BOOL)autoEnabled {
    _autoEnabled = autoEnabled;
    if (!autoEnabled) {
        _autoActive = NO;
        return;
    }
    if (_cur != &_main) return;
    if (_main.gen != GenNone) {
        _autoActive = YES;
    } else if (!_main.normals_ready || _main.ambo_pass < _amboTarget) {
        // Pick up where the picture left off.
        _autoActive = YES;
        _main.next = !_main.normals_ready ? (_main.geom_passes >= _autoGeomPasses ? GenNormals : GenGeom) : GenAmbo;
    }
}

- (void)setPaused:(BOOL)paused {
    _paused = paused;
    _displayDirty = YES;
}

// Adds another round of ambient occlusion passes to a finished picture, for smoother shading.
- (void)refineMore {
    if (!_main.normals_ready) {
        self.autoEnabled = YES;
        return;
    }
    _cur = &_main;
    _amboTarget = MIN(_main.ambo_pass + _autoAmboPasses, kMaxAmboPasses);
    if (_main.ambo_pass >= _amboTarget) return;
    _autoActive = YES;
    _main.next = GenAmbo;
}

#pragma mark - Mouse

- (void)lightsChanged {
    if (_mouseTarget == 9) {
        for (int i = 0; i < MAX_LIGHTS; i++) _scene.SetLightDir(i, _scene.lights[i].z);
    } else {
        _scene.SetLightDir(_mouseTarget, _scene.lights[_mouseTarget].z);
    }
    _relightWhole = YES;
}

- (void)dragPrimaryDX:(float)dx dy:(float)dy shift:(BOOL)shift control:(BOOL)control {
    _lastInput = CACurrentMediaTime();
    Frame *frame = (_mouseTarget == -1) ? &_scene.camera
                 : (_mouseTarget >= 0 && _mouseTarget < MAX_LIGHTS) ? &_scene.lights[_mouseTarget] : nullptr;
    if (control) {
        if (frame) frame->RotateOnZ((dx - dy) * 2);   // roll
    } else if (shift) {
        if (frame) frame->pos += frame->x * dx * 4.0f + frame->y * dy * 4.0f;   // slide sideways
    } else {
        float scale = (_mouseTarget == -1) ? 1.0f : 4.0f;
        float horiz = dx * scale, vert = -dy * scale;
        if (_mouseTarget == -1) {
            // Orbit around the point the camera is looking at.
            float3 lookat = frame->pos + frame->z * kLookAtDistance;
            frame->RotateOnY(horiz);
            frame->RotateOnX(vert);
            frame->pos = lookat - frame->z * kLookAtDistance;
        } else if (_mouseTarget == 9) {
            for (int i = 0; i < MAX_LIGHTS; i++) {
                _scene.lights[i].RotateOnWSY(horiz);
                _scene.lights[i].RotateOnWSX(vert);
            }
        } else if (frame) {
            frame->RotateOnWSY(horiz);
            frame->RotateOnWSX(vert);
        }
    }
    if (_mouseTarget == -1) [self clearAll];
    else [self lightsChanged];
}

- (void)dragSecondaryDX:(float)dx dy:(float)dy shift:(BOOL)shift {
    _lastInput = CACurrentMediaTime();
    if (_mouseTarget != -1) return;
    float scale = shift ? 1.0f : 8.0f;
    _scene.camera.pos -= _scene.camera.z * (dx - dy) * scale;
    [self clearAll];
}

- (void)dolly:(float)amount {
    _lastInput = CACurrentMediaTime();
    if (_mouseTarget != -1) return;
    _scene.camera.pos += _scene.camera.z * amount;
    [self clearAll];
}

#pragma mark - Status

- (GenMode)stage { return _cur->gen; }
- (BOOL)onReflection { return _cur == &_refl; }
- (BOOL)autoRunning { return _autoActive; }

// Passes per second over the last three seconds of work.
- (double)passesPerSecond {
    const CFTimeInterval now = CACurrentMediaTime();
    size_t first = _passEnds.size();
    while (first > 0 && now - _passEnds[first - 1] < 3.0) first--;
    const size_t n = _passEnds.size() - first;
    if (n < 2 || now - _passEnds.back() > 1.5) return 0;   // too few to measure, or not working at the moment
    return (double)(n - 1) / (_passEnds.back() - _passEnds[first]);
}
- (BOOL)finished { return !_autoActive && _cur->gen == GenNone && _cur->next == GenNone; }

// How far through the automatic plan the picture is (0..1), or -1 when the
// stages are being run by hand.
- (double)progress {
    if (!_autoActive) return self.finished ? 1.0 : -1.0;
    const double tilesTotal = [self tilesAcross] * [self tilesDown];
    const BOOL refl = [self wantsReflections] || _cur == &_refl;
    const double mainPlan = _autoGeomPasses + 1 + _amboTarget;
    const double reflPlan = refl ? _autoGeomPasses + 1 + _autoAmboPasses : 0;
    auto done = [&](IntersectionSet &s, int amboTarget) {
        int completedAmbo = MAX(0, s.ambo_pass - ((s.gen == GenAmbo && s.tile > 0) ? 1 : 0));
        double d = MIN(s.geom_passes, _autoGeomPasses) + (s.normals_ready ? 1 : 0) + MIN(completedAmbo, amboTarget);
        if (&s == _cur && s.gen != GenNone) d += s.tile / tilesTotal;
        return d;
    };
    double d = (_cur == &_refl) ? mainPlan + done(_refl, _autoAmboPasses) : done(_main, _amboTarget);
    return MIN(1.0, MAX(0.0, d / (mainPlan + reflPlan)));
}
- (int)geomPasses { return _cur->geom_passes; }
// Completed passes (the one in progress doesn't count).
- (int)amboPasses { return MAX(0, _cur->ambo_pass - ((_cur->gen == GenAmbo && _cur->tile > 0) ? 1 : 0)); }
- (BOOL)normalsReady { return _cur->normals_ready; }
- (int)imageWidth { return _width; }
- (int)imageHeight { return _height; }

- (NSString *)statusText {
    static NSString *const stageNames[] = {@"Geometry", @"Normals", @"Ambient occlusion", @"Idle"};
    NSMutableString *s = [NSMutableString string];
    // While a newly picked shape is compiling, the picture still shows the old one; say so first.
    if (self.compiling && self.shapePath && ![self.shapePath isEqualToString:_adoptedShapePath])
        [s appendFormat:@"Loading %@…  ·  ", [Renderer displayNameForShape:self.shapePath]];
    [s appendFormat:@"%d × %d  ·  %@", _width, _height, stageNames[_cur->gen]];
    [s appendFormat:@"  ·  geometry %d, ambient %d", self.geomPasses, self.amboPasses];
    if (_cur == &_refl) [s appendString:@"  ·  reflection rays"];
    if (_scene.cb.g_viz_mode != 0) [s appendFormat:@"  ·  view: %@", kVizModeNames[_scene.cb.g_viz_mode]];
    if (_mouseTarget == 9) [s appendString:@"  ·  mouse moves all lights (0 for camera)"];
    else if (_mouseTarget >= 0) [s appendFormat:@"  ·  mouse moves light %d (0 for camera)", _mouseTarget + 1];
    if (_soloLight >= 0) [s appendFormat:@"  ·  light %d alone", _soloLight + 1];
    if (self.compiling) [s appendString:@"  ·  compiling…"];
    else if (self.lastError) [s appendString:@"  ·  SHADER ERROR"];
    return s;
}

#pragma mark - Rendering

- (int)tilesAcross { return MAX(1, _width / kTileEdge); }
- (int)tilesDown { return MAX(1, _height / kTileEdge); }

// Tiles are a fixed size (the last column and row may be narrower), so the
// relight shader can work out which tile a pixel belongs to.
- (int)tileWidth { int across = [self tilesAcross]; return (_width + across - 1) / across; }
- (int)tileHeight { int down = [self tilesDown]; return (_height + down - 1) / down; }

- (MTLScissorRect)rectForTile:(int)t {
    int across = [self tilesAcross], down = [self tilesDown];
    int tw = [self tileWidth], th = [self tileHeight];
    int tx = t % across, ty = (t / across) % down;
    int x0 = MIN(tx * tw, _width - 1), y0 = MIN(ty * th, _height - 1);
    int x1 = MIN(x0 + tw, _width), y1 = MIN(y0 + th, _height);
    return (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
}

// For the relight shader: how many tiles of this set's ambient occlusion pass
// are done, or a huge number if no pass is part-way through.
- (uint32_t)amboTilesDone:(IntersectionSet *)s extra:(int)justDrawn {
    int progress = s->tile + justDrawn;
    return (s->gen == GenAmbo && progress > 0) ? (uint32_t)progress : 0xFFFFFFFFu;
}

- (void)clearTexture:(id<MTLTexture>)tex in:(id<MTLCommandBuffer>)cb {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = tex;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
}

- (void)processClears:(id<MTLCommandBuffer>)cb {
    IntersectionSet *sets[2] = {&_main, &_refl};
    for (IntersectionSet *s : sets) {
        if (!s->clear_flags) continue;
        if (s->clear_flags & CLEAR_GEOM) {
            if (s->initialized) {
                [self clearTexture:s->depth[0] in:cb];
                [self clearTexture:s->depth[1] in:cb];
            }
            s->geom_passes = 0;
        }
        if (s->clear_flags & CLEAR_NORM) {
            if (s->initialized) [self clearTexture:s->norm in:cb];
            s->normals_ready = false;
        }
        if (s->clear_flags & CLEAR_AMBO) {
            if (s->initialized) [self clearTexture:s->ambo in:cb];
            s->ambo_pass = 0;
        }
        if (s->clear_flags == CLEAR_ALL) {
            s->tile = 0;
            s->gen = GenGeom;
            s->next = GenGeom;
            s->ambo_dirty = false;
        }
        s->clear_flags = 0;
    }
}

// Moves the current set on to its next stage.
- (void)enterNextStage {
    IntersectionSet *s = _cur;
    s->gen = s->next;
    if (s->gen == GenGeom) s->which = 1 - s->which;   // read the depth we just wrote; write the other
    if (s->gen == GenAmbo && s->ambo_dirty) {
        // The surface changed since ambient occlusion was last computed, so start it again.
        s->clear_flags |= CLEAR_AMBO;
        s->ambo_dirty = false;
    }
}

// Decides the next stage when the stages are running automatically.
- (void)applyAuto {
    if (!_autoActive) return;
    IntersectionSet *s = _cur;
    if (s->gen == GenGeom) {
        s->next = (s->geom_passes >= _autoGeomPasses) ? GenNormals : GenGeom;
    } else if (s->gen == GenNormals) {
        s->next = GenAmbo;
    } else if (s->gen == GenAmbo) {
        const int target = (s == &_main) ? _amboTarget : _autoAmboPasses;
        s->next = (s->ambo_pass >= target) ? GenNone : GenAmbo;
    }
}

// Called when the automatic run has finished all three stages for one set of rays.
- (void)autoSetFinished {
    if (_cur == &_main) {
        _autoFinishedMain = YES;
        if ([self wantsReflections] && ![self reflectionsComplete]) {
            [self autoBeginReflections];   // carry on with the reflected rays
            return;
        }
    } else {
        _cur = &_main;
    }
    _autoActive = NO;   // the picture is finished
    _relightWhole = YES;
}

- (void)endOfPass {
    IntersectionSet *s = _cur;
    _passEnds.push_back(CACurrentMediaTime());
    if (_passEnds.size() > 240) _passEnds.erase(_passEnds.begin());
    if (s->gen == GenGeom) s->geom_passes++;
    if (s->gen == GenNormals) s->normals_ready = true;
    // Stop after one pass of normals, so that the depths and normals stay in step.
    if (s->gen == GenNormals && s->next == GenNormals) s->next = GenNone;
    if (s->gen == GenAmbo && s->next == GenAmbo && s->ambo_pass >= kMaxAmboPasses) s->next = GenNone;
    [self applyAuto];
    [self enterNextStage];
    if (_autoActive && s->gen == GenNone) [self autoSetFinished];
}

// Binds everything the scene shaders read.  A texture can't be read while it
// is being drawn into, so 'target' is swapped for a blank stand-in.
- (void)bindScene:(id<MTLRenderCommandEncoder>)enc
           target:(id<MTLTexture>)target
       forRelight:(BOOL)forRelight
         uniforms:(id<MTLBuffer>)uniforms
            tiles:(id<MTLBuffer>)tiles {
    // While geometry is being refined, the geometry shader continues from the
    // previous pass's depth; everything else reads the latest depth.
    BOOL readPrevious = (!forRelight && _cur == &_main && _main.gen == GenGeom);
    id<MTLTexture> mainDepth = _main.depth[readPrevious ? 1 - _main.which : _main.which];
    id<MTLTexture> texs[14] = {
        _noiseCube[0], _noiseCube[1], _noiseCube[2], _noiseCube[3], _noise2d, _amboDirs, _normalDirs,
        mainDepth,
        _main.norm,
        _main.ambo,
        _refl.initialized ? _refl.depth[_refl.which] : nil,
        _refl.initialized ? _refl.norm : nil,
        _refl.initialized ? _refl.ambo : nil,
        _cur->depth[1 - _cur->which],
    };
    for (int i = 0; i < 14; i++) {
        id<MTLTexture> t = texs[i];
        if (!t || t == target) t = _dummy;
        [enc setFragmentTexture:t atIndex:i];
    }
    [enc setFragmentSamplerState:_linearWrap atIndex:0];
    [enc setFragmentSamplerState:_nearestWrap atIndex:1];
    [enc setFragmentSamplerState:_nearestClamp atIndex:2];
    [enc setFragmentBuffer:uniforms offset:0 atIndex:0];
    [enc setFragmentBuffer:tiles offset:0 atIndex:1];
}

// Fills in the values the shaders need that change from frame to frame.
// 'tilesThisFrame' is how many tiles are about to be drawn.
- (void)fillFrameUniforms:(int)tilesThisFrame {
    IntersectionSet *s = _cur;
    _scene.UpdateCameraUniforms(_width, _height);
    Uniforms &u = _scene.cb;
    u.g_cur_ambo_pass = (uint32_t)s->ambo_pass;
    u.g_main_ambo_pass = (uint32_t)_main.ambo_pass;
    u.g_refl_ambo_pass = (uint32_t)_refl.ambo_pass;
    u.g_intersection_set = (s == &_main) ? 0 : 1;
    u.g_geom_frames_since_geom_clear = (uint32_t)s->geom_passes;
    u.g_tile_info = simd_make_float4((float)[self tileWidth], (float)[self tileHeight],
                                     (float)[self tilesAcross], (float)[self tilesDown]);
    u.g_main_ambo_tiles_done = [self amboTilesDone:&_main extra:(s == &_main ? tilesThisFrame : 0)];
    u.g_refl_ambo_tiles_done = [self amboTilesDone:&_refl extra:(s == &_refl ? tilesThisFrame : 0)];
    u.g_skip_empty_after = _skipEmptySky ? 16 : 0;
    u.g_hdr_output = 0;   // (switched on only for the picture shown in the window)
}

// Does one frame's worth of work: up to 'maxTiles' tiles of the current
// stage, then relights whatever changed.  Returns the number of tiles drawn.
- (int)stepInto:(id<MTLCommandBuffer>)cb maxTiles:(int)maxTiles {
    return [self stepInto:cb maxTiles:maxTiles honourPause:YES];
}

- (int)stepInto:(id<MTLCommandBuffer>)cb maxTiles:(int)maxTiles honourPause:(BOOL)honourPause {
    if (!_pipelines || !_main.initialized) return 0;

    if (_cur->gen == GenNone && _cur->next != GenNone) [self enterNextStage];
    [self processClears:cb];

    IntersectionSet *s = _cur;
    const int tilesTotal = [self tilesAcross] * [self tilesDown];
    const BOOL hold = honourPause && _paused;
    const int n = (s->gen == GenNone || maxTiles <= 0 || hold) ? 0 : MIN(maxTiles, tilesTotal - s->tile);
    if (n == 0 && !_relightWhole) return 0;

    if (n > 0 && s->gen == GenAmbo && s->tile == 0) s->ambo_pass++;

    // Settings for this frame.
    [self fillFrameUniforms:n];
    Uniforms u = _scene.cb;
    const BOOL hdr = (_final.pixelFormat == MTLPixelFormatRGBA16Float);
    u.g_hdr_output = hdr ? 1 : 0;
    if (_soloLight >= 0) {
        // Showing one light alone: switch the others off in this frame's copy only.
        for (int i = 0; i < MAX_LIGHTS; i++) {
            if (i != _soloLight) u.g_light_col[i] = simd_make_float4(0, 0, 0, 0);
        }
    }
    id<MTLBuffer> ubuf = [_device newBufferWithBytes:&u length:sizeof(u) options:MTLResourceStorageModeShared];

    // Fresh random numbers for every tile.
    const int tileCount = MAX(n, 1);
    id<MTLBuffer> tbuf = [_device newBufferWithLength:(NSUInteger)tileCount * kTileStride options:MTLResourceStorageModeShared];
    std::uniform_real_distribution<float> unit(0.0f, 1.0f);
    for (int i = 0; i < tileCount; i++) {
        TileUniforms *t = (TileUniforms *)((uint8_t *)tbuf.contents + (size_t)i * kTileStride);
        for (int k = 0; k < TIME_UNORM_COUNT; k++)
            t->time_unorm[k] = simd_make_float4(unit(_timeRng), unit(_timeRng), unit(_timeRng), unit(_timeRng));
        t->g_cur_frame = s->frame + (uint32_t)i;
    }

    if (n > 0) {
        id<MTLTexture> target = (s->gen == GenGeom) ? s->depth[s->which] : (s->gen == GenNormals) ? s->norm : s->ambo;
        id<MTLRenderPipelineState> pipeline =
            (s->gen == GenGeom) ? _pipelines.geom : (s->gen == GenNormals) ? _pipelines.norm : _pipelines.ambo;

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pipeline];
        [self bindScene:enc target:target forRelight:NO uniforms:ubuf tiles:tbuf];
        for (int i = 0; i < n; i++) {
            [enc setScissorRect:[self rectForTile:s->tile + i]];
            [enc setFragmentBufferOffset:(NSUInteger)i * kTileStride atIndex:1];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        }
        [enc endEncoding];
    }

    // Relight: the tiles just drawn, or the whole picture if lighting changed.
    {
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = _final;
        rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:hdr ? _pipelines.relightHDR : _pipelines.relight];
        [self bindScene:enc target:_final forRelight:YES uniforms:ubuf tiles:tbuf];
        if (_relightWhole) {
            [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        } else {
            for (int i = 0; i < n; i++) {
                [enc setScissorRect:[self rectForTile:s->tile + i]];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }
        }
        [enc endEncoding];
        _relightWhole = NO;
    }

    if (n > 0) {
        s->tile += n;
        s->frame += (uint32_t)n;
        if (s->gen == GenGeom || s->gen == GenNormals) s->ambo_dirty = true;
        if (s->tile >= tilesTotal) {
            s->tile = 0;
            [self endOfPass];
        }
    }
    return n;
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self setImageWidth:(int)size.width / _detailDivisor height:(int)size.height / _detailDivisor];
    _displayDirty = YES;
}

- (BOOL)hasPendingWork {
    if (_relightWhole || _main.clear_flags || _refl.clear_flags) return YES;
    return !_paused && (_cur->gen != GenNone || _cur->next != GenNone);
}

// Hands the graphics card its next slices of work, if it has room for them.
// Called every screen refresh, and again each time a slice finishes, so the
// card goes straight from one slice to the next without waiting for the screen.
- (void)pumpWork {
    while (_slicesInFlight < kSlicesInFlight && [self hasPendingWork]) {
        // The stage about to be worked on, and how many tiles it can do in one slice.
        const GenMode stage = (_cur->gen == GenNone) ? _cur->next : _cur->gen;
        const int budget = (stage < GenNone) ? (int)MAX(1.0, _tilesForStage[stage]) : 1;

        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        const int tiles = [self stepInto:cb maxTiles:budget];
        _displayDirty = YES;
        _slicesInFlight++;

        const BOOL interacting = (CACurrentMediaTime() - _lastInput) < kInteractingFor;
        const double target = interacting ? kSliceSecondsInteracting : kSliceSeconds;
        const NSUInteger generation = _compileGeneration;
        __weak Renderer *weakSelf = self;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            if (done.status == MTLCommandBufferStatusError)
                NSLog(@"Gpucaster: the graphics card reported an error: %@", done.error.localizedDescription);
            double seconds = done.GPUEndTime - done.GPUStartTime;
            dispatch_async(dispatch_get_main_queue(), ^{
                Renderer *me = weakSelf;
                if (!me) return;
                me->_slicesInFlight--;
                // Learn how many tiles of this stage fit in a slice.  (Ignore
                // measurements made with shaders that have since been replaced.)
                if (tiles > 0 && stage < GenNone && seconds > 0 && generation == me->_compileGeneration) {
                    double ideal = MIN(4096.0, MAX(1.0, target / (seconds / tiles)));
                    double &t = me->_tilesForStage[stage];
                    // Drop straight away if a slice took too long; grow gradually.
                    t = (ideal < t) ? ideal : 0.5 * t + 0.5 * ideal;
                }
                [me pumpWork];
            });
        }];
        [cb commit];
    }
}

- (void)drawInMTKView:(MTKView *)view {
    CGSize size = view.drawableSize;
    [self setImageWidth:(int)size.width / _detailDivisor height:(int)size.height / _detailDivisor];

    if ([self matchView:view]) return;   // the window was just switched between ordinary and extended brightness
    [self pumpWork];

    // When the picture on screen is up to date, do nothing at all, so an idle
    // app uses no graphics card time.
    if (!_displayDirty) return;

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    // Copy the picture to the window.  This waits its turn behind the work
    // already handed to the graphics card, so it shows the latest results.
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    // At Half detail the picture is smaller than the window: enlarge it with
    // MetalFX if that is switched on, otherwise the copy below stretches it.
    id<MTLTexture> picture = _final;
    if (_sharpUpscale && _detailDivisor > 1) {
        id<MTLTexture> sharp = [self upscaleInto:cb width:(int)size.width height:(int)size.height];
        if (sharp) picture = sharp;
    }
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (_pipelines && picture) {
        simd_float4 viewSize = simd_make_float4((float)size.width, (float)size.height,
                                                1.0f / (float)size.width, 1.0f / (float)size.height);
        [enc setFragmentTexture:picture atIndex:0];
        [enc setFragmentSamplerState:_linearClamp atIndex:0];
        [enc setFragmentBytes:&viewSize length:sizeof(viewSize) atIndex:0];
        if (_viewIsEDR) {
            // How much brighter than white the display can go at this moment.
            float headroom = (float)MAX(1.0, view.window.screen.maximumExtendedDynamicRangeColorComponentValue);
            simd_float4 hdrInfo = simd_make_float4(headroom, 0, 0, 0);
            [enc setRenderPipelineState:_pipelines.displayHDR];
            [enc setFragmentBytes:&hdrInfo length:sizeof(hdrInfo) atIndex:1];
        } else {
            [enc setRenderPipelineState:_pipelines.display];
        }
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    [cb presentDrawable:drawable];
    [cb commit];
    _displayDirty = NO;
}

#pragma mark - Off-screen use and saving

- (void)runPasses:(int)passes {
    const int tilesTotal = [self tilesAcross] * [self tilesDown];
    for (int i = 0; i < passes; i++) {
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        [self stepInto:cb maxTiles:tilesTotal honourPause:NO];
        [cb commit];
        [cb waitUntilCompleted];
    }
}

- (BOOL)runUntilFinished:(int)maxPasses {
    for (int i = 0; i < maxPasses && !self.finished; i++) [self runPasses:1];
    return self.finished;
}

- (void)readPixelX:(int)x y:(int)y depth:(float *)depth normal:(simd_float4 *)normal ambo:(simd_float4 *)ambo {
    // Copy the three data textures into one-pixel buffers the CPU can read.
    id<MTLBuffer> buf = [_device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    id<MTLTexture> sources[3] = {_main.depth[_main.which], _main.norm, _main.ambo};
    for (int i = 0; i < 3; i++) {
        [blit copyFromTexture:sources[i] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x, y, 0)
                   sourceSize:MTLSizeMake(1, 1, 1) toBuffer:buf destinationOffset:(NSUInteger)i * 16
       destinationBytesPerRow:16 destinationBytesPerImage:16];
    }
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    const uint8_t *p = (const uint8_t *)buf.contents;
    memcpy(depth, p, 4);
    const int16_t *n = (const int16_t *)(p + 16);
    *normal = simd_make_float4(n[0], n[1], n[2], n[3]) / 32767.0f;
    const _Float16 *a = (const _Float16 *)(p + 32);
    *ambo = simd_make_float4((float)a[0], (float)a[1], (float)a[2], (float)a[3]);
}

// Small pictures of the current scene under each of the given lightings.
// All are drawn in one go, so the app pauses only briefly.
- (NSArray<NSImage *> *)thumbnailsForLightings:(const std::vector<Lighting> &)lightings width:(int)width {
    NSMutableArray<NSImage *> *images = [NSMutableArray array];
    if (!_pipelines || !_main.initialized || lightings.empty() || _width <= 0) return images;
    const int w = MAX(16, width), h = MAX(10, (int)lround((double)w * _height / _width));

    const Lighting saved = _scene.GetLighting();
    const uint32_t savedViz = _scene.cb.g_viz_mode;
    id<MTLBuffer> tbuf = [_device newBufferWithLength:kTileStride options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    NSMutableArray<id<MTLTexture>> *targets = [NSMutableArray array];
    for (const Lighting &l : lightings) {
        _scene.SetLighting(l);
        [self fillFrameUniforms:0];
        Uniforms u = _scene.cb;
        u.g_viz_mode = 0;
        u.g_image_size.z = 1.0f / w;   // the shader turns pixel positions into 0..1 with these
        u.g_image_size.w = 1.0f / h;
        id<MTLBuffer> ubuf = [_device newBufferWithBytes:&u length:sizeof(u) options:MTLResourceStorageModeShared];

        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
        id<MTLTexture> target = [_device newTextureWithDescriptor:td];
        [targets addObject:target];

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = target;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:_pipelines.relight];
        [self bindScene:enc target:target forRelight:YES uniforms:ubuf tiles:tbuf];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        if (target.storageMode == MTLStorageModeManaged) {
            id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
            [blit synchronizeResource:target];
            [blit endEncoding];
        }
    }
    _scene.SetLighting(saved);
    _scene.cb.g_viz_mode = savedViz;
    [cb commit];
    [cb waitUntilCompleted];

    for (id<MTLTexture> target in targets) {
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                                                                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32];
        uint8_t *px = rep.bitmapData;
        [target getBytes:px bytesPerRow:(NSUInteger)w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        for (int i = 0; i < w * h; i++) {   // BGRA -> RGBA
            uint8_t b = px[i * 4];
            px[i * 4] = px[i * 4 + 2];
            px[i * 4 + 2] = b;
            px[i * 4 + 3] = 255;
        }
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w / 2.0, h / 2.0)];
        [image addRepresentation:rep];
        [images addObject:image];
    }
    return images;
}

static BOOL WriteBGRA8TextureToPNG(id<MTLTexture> tex, NSString *path) {
    const int w = (int)tex.width, h = (int)tex.height;
    const size_t rowBytes = (size_t)w * 4;
    std::vector<uint8_t> pixels(rowBytes * (size_t)h);
    [tex getBytes:pixels.data() bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), w, h, 8, rowBytes, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    BOOL ok = NO;
    if (image) {
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
        if (dest) {
            CGImageDestinationAddImage(dest, image, NULL);
            ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(image);
    }
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return ok;
}

- (BOOL)saveEnlargedToPNG:(NSString *)path width:(int)width height:(int)height sharp:(BOOL)sharp {
    if (!_final || !_pipelines) return NO;
    _relightWhole = YES;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self stepInto:cb maxTiles:0];
    id<MTLTexture> picture = _final;
    if (sharp) {
        picture = [self upscaleInto:cb width:width height:height];
        if (!picture) return NO;
    }
    // Draw it into a texture of the window's size, exactly as the window would.
    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    simd_float4 viewSize = simd_make_float4((float)width, (float)height, 1.0f / width, 1.0f / height);
    [enc setRenderPipelineState:_pipelines.display];
    [enc setFragmentTexture:picture atIndex:0];
    [enc setFragmentSamplerState:_linearClamp atIndex:0];
    [enc setFragmentBytes:&viewSize length:sizeof(viewSize) atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    if (target.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:target];
        [blit endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];
    return WriteBGRA8TextureToPNG(target, path);
}

- (BOOL)saveImageToPNG:(NSString *)path {
    if (!_final || !_pipelines) return NO;

    // Relight the whole picture so it is up to date, and wait for it.
    _relightWhole = YES;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self stepInto:cb maxTiles:0];

    id<MTLTexture> toSave = _final;
    if (_final.pixelFormat != MTLPixelFormatBGRA8Unorm) {
        // The window is showing extended brightness, which a PNG can't hold:
        // light an ordinary copy of the picture for saving.
        [self fillFrameUniforms:0];
        Uniforms u = _scene.cb;
        id<MTLBuffer> ubuf = [_device newBufferWithBytes:&u length:sizeof(u) options:MTLResourceStorageModeShared];
        id<MTLBuffer> tbuf = [_device newBufferWithLength:kTileStride options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:_width height:_height mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        td.storageMode = _device.hasUnifiedMemory ? MTLStorageModeShared : MTLStorageModeManaged;
        toSave = [_device newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
        rp.colorAttachments[0].texture = toSave;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:_pipelines.relight];
        [self bindScene:enc target:toSave forRelight:YES uniforms:ubuf tiles:tbuf];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
    }
    if (toSave.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:toSave];
        [blit endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];
    return WriteBGRA8TextureToPNG(toSave, path);
}

@end
