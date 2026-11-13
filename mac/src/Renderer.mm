#import "Renderer.h"
#import <ImageIO/ImageIO.h>
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
static const int kTileEdge = 128;             // pixels; the app decides how many tiles to draw per frame
static const double kTargetGpuSeconds = 0.010;   // GPU time to spend per frame, to keep the app responsive
static const int kTileStride = 1280;          // bytes between tiles in the per-tile buffer (>= sizeof(TileUniforms))
static const int kAutoGeomPasses = 40;
static const int kAutoAmboPasses = 16;

static const uint32_t CLEAR_GEOM = 1, CLEAR_NORM = 2, CLEAR_AMBO = 4, CLEAR_ALL = 0xFFFFFFFF;

// Compiled shaders for each stage.
@interface Pipelines : NSObject
@property (nonatomic, strong) id<MTLRenderPipelineState> geom, norm, ambo, relight, display;
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
    BOOL _autoActive;
    BOOL _reloadPending;
    double _tilesPerFrame;
    NSTimeInterval _shaderStamp;
    std::mt19937 _timeRng;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    if ((self = [super init])) {
        _device = device;
        _queue = [device newCommandQueue];
        _cur = &_main;
        _mouseTarget = -1;
        _autoEnabled = YES;
        _autoActive = YES;
        _tilesPerFrame = 4;
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

#pragma mark - Shaders

// The shaders live outside the app bundle so they can be edited.  Look for a
// "shaders" folder next to, or a few levels above, the app.
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
    return nil;
}

// Reads a shader file and pastes in the files it #includes (Metal can't do
// that itself when compiling from text).  "#line" markers keep error messages
// pointing at the right file and line.
+ (NSString *)expandFile:(NSString *)name
                     dir:(NSString *)dir
                   shape:(NSString *)shapePath
                    seen:(NSMutableSet *)seen
                   error:(NSString **)error {
    NSString *path = [dir stringByAppendingPathComponent:name];
    if ([name isEqualToString:kShapeInclude]) {
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
    NSMutableString *out = [NSMutableString stringWithFormat:@"#line 1 \"%@\"\n", name];
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
                    NSString *body = [self expandFile:inc dir:dir shape:shapePath seen:seen error:error];
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
    return out;
}

+ (Pipelines *)buildPipelinesWithDevice:(id<MTLDevice>)device
                                    dir:(NSString *)dir
                                  shape:(NSString *)shapePath
                                  error:(NSString **)error {
    if (!dir) {
        if (error) *error = @"Could not find the shaders folder.";
        return nil;
    }
    NSString *src = [self expandFile:kMasterShader dir:dir shape:shapePath seen:[NSMutableSet set] error:error];
    if (!src) return nil;

    MTLCompileOptions *opts = [MTLCompileOptions new];
    // Fractals are sensitive to tiny rounding differences, and the shaders rely
    // on exact handling of "not a number" values, so turn off risky optimisations.
    opts.mathMode = MTLMathModeSafe;

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
    } specs[5] = {
        {@"fs_geom", MTLPixelFormatR32Float, false},
        {@"fs_norm", MTLPixelFormatRGBA16Snorm, false},
        {@"fs_ambo", MTLPixelFormatRGBA16Float, true},   // each pass adds to the last
        {@"fs_relight", MTLPixelFormatBGRA8Unorm, false},
        {@"fs_display", MTLPixelFormatBGRA8Unorm, false},
    };
    id<MTLRenderPipelineState> states[5];
    for (int i = 0; i < 5; i++) {
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
    return p;
}

- (BOOL)reloadShadersNow {
    NSString *err = nil;
    Pipelines *p = [Renderer buildPipelinesWithDevice:_device dir:self.shaderDir shape:self.shapePath error:&err];
    _shaderStamp = [self latestShaderModification];
    if (p) {
        _pipelines = p;
        self.lastError = nil;
        [self clearAll];
    } else {
        self.lastError = err;
    }
    return p != nil;
}

- (void)reloadShadersInBackground {
    if (self.compiling) {
        _reloadPending = YES;
        return;
    }
    self.compiling = YES;
    _shaderStamp = [self latestShaderModification];
    id<MTLDevice> device = _device;
    NSString *dir = self.shaderDir;
    NSString *shape = self.shapePath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = nil;
        Pipelines *p = [Renderer buildPipelinesWithDevice:device dir:dir shape:shape error:&err];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.compiling = NO;
            if (p) {
                self->_pipelines = p;
                self.lastError = nil;
                [self clearAll];
            } else {
                self.lastError = err;
            }
            if (self.onShaderResult) self.onShaderResult(p ? nil : err);
            if (self->_reloadPending) {
                self->_reloadPending = NO;
                [self reloadShadersInBackground];
            }
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

- (NSArray<NSString *> *)availableShapes {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *dir = self.shapesDir;
    if (!dir) return paths;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if ([name hasSuffix:@".metal"] && ![name hasPrefix:@"."]) [paths addObject:[dir stringByAppendingPathComponent:name]];
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    return paths;
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

- (void)selectShape:(NSString *)path {
    if (!path) return;
    self.shapePath = path;
    [[NSUserDefaults standardUserDefaults] setObject:path forKey:kShapeDefaultsKey];
    [self reloadShadersInBackground];
}

- (NSString *)compileErrorForShape:(NSString *)path {
    NSString *err = nil;
    Pipelines *p = [Renderer buildPipelinesWithDevice:_device dir:self.shaderDir shape:path error:&err];
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
    _final = [self makeTarget:MTLPixelFormatBGRA8Unorm shared:YES];
    _displayDirty = YES;
    [self clearAll];
}

#pragma mark - Commands

- (void)clearAll {
    _cur = &_main;
    _main.clear_flags = CLEAR_ALL;
    _refl.clear_flags = CLEAR_ALL;
    _main.next = GenGeom;
    _refl.next = GenGeom;
    _relightWhole = YES;
    _autoActive = _autoEnabled;
}

- (void)relight { _relightWhole = YES; }

- (void)setStage:(GenMode)mode {
    _autoActive = NO;
    if (mode == GenAmbo && !(_cur->normals_ready || _cur->gen == GenNormals)) return;   // needs normals first
    _cur->next = mode;
}

- (void)toggleReflection {
    _autoActive = NO;
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

- (void)setVizMode:(int)mode {
    _scene.cb.g_viz_mode = (uint32_t)((mode % kNumVizModes + kNumVizModes) % kNumVizModes);
    _relightWhole = YES;
}

- (void)setAutoEnabled:(BOOL)autoEnabled {
    _autoEnabled = autoEnabled;
    _autoActive = autoEnabled && _cur == &_main && _main.gen != GenNone;
    if (autoEnabled && _main.gen == GenNone && _cur == &_main && _main.ambo_pass < kAutoAmboPasses) {
        // Pick up where the picture left off.
        _autoActive = YES;
        _main.next = !_main.normals_ready ? (_main.geom_passes >= kAutoGeomPasses ? GenNormals : GenGeom) : GenAmbo;
    }
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
    if (_mouseTarget != -1) return;
    float scale = shift ? 1.0f : 8.0f;
    _scene.camera.pos -= _scene.camera.z * (dx - dy) * scale;
    [self clearAll];
}

- (void)dolly:(float)amount {
    if (_mouseTarget != -1) return;
    _scene.camera.pos += _scene.camera.z * amount;
    [self clearAll];
}

#pragma mark - Status

- (GenMode)stage { return _cur->gen; }
- (BOOL)onReflection { return _cur == &_refl; }
- (BOOL)autoRunning { return _autoActive; }
- (int)geomPasses { return _cur->geom_passes; }
// Completed passes (the one in progress doesn't count).
- (int)amboPasses { return MAX(0, _cur->ambo_pass - ((_cur->gen == GenAmbo && _cur->tile > 0) ? 1 : 0)); }
- (BOOL)normalsReady { return _cur->normals_ready; }
- (int)imageWidth { return _width; }
- (int)imageHeight { return _height; }

- (NSString *)statusText {
    static NSString *const stageNames[] = {@"Geometry", @"Normals", @"Ambient occlusion", @"Idle"};
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%d × %d  ·  %@", _width, _height, stageNames[_cur->gen]];
    [s appendFormat:@"  ·  geometry %d, ambient %d", self.geomPasses, self.amboPasses];
    if (_cur == &_refl) [s appendString:@"  ·  reflection rays"];
    if (_scene.cb.g_viz_mode != 0) [s appendFormat:@"  ·  view: %@", kVizModeNames[_scene.cb.g_viz_mode]];
    if (self.compiling) [s appendString:@"  ·  compiling shaders…"];
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

- (void)applyAuto {
    if (!_autoActive || _cur != &_main) return;
    IntersectionSet *s = _cur;
    if (s->gen == GenGeom) {
        s->next = (s->geom_passes >= kAutoGeomPasses) ? GenNormals : GenGeom;
    } else if (s->gen == GenNormals) {
        s->next = GenAmbo;
    } else if (s->gen == GenAmbo) {
        if (s->ambo_pass >= kAutoAmboPasses) {
            s->next = GenNone;
            _autoActive = NO;   // finished
        } else {
            s->next = GenAmbo;
        }
    }
}

- (void)endOfPass {
    IntersectionSet *s = _cur;
    if (s->gen == GenGeom) s->geom_passes++;
    if (s->gen == GenNormals) s->normals_ready = true;
    // Stop after one pass of normals, so that the depths and normals stay in step.
    if (s->gen == GenNormals && s->next == GenNormals) s->next = GenNone;
    if (s->gen == GenAmbo && s->next == GenAmbo && s->ambo_pass >= kMaxAmboPasses) s->next = GenNone;
    [self applyAuto];
    [self enterNextStage];
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

// Does one frame's worth of work: up to 'maxTiles' tiles of the current
// stage, then relights whatever changed.  Returns the number of tiles drawn.
- (int)stepInto:(id<MTLCommandBuffer>)cb maxTiles:(int)maxTiles {
    if (!_pipelines || !_main.initialized) return 0;

    if (_cur->gen == GenNone && _cur->next != GenNone) [self enterNextStage];
    [self processClears:cb];

    IntersectionSet *s = _cur;
    const int tilesTotal = [self tilesAcross] * [self tilesDown];
    const int n = (s->gen == GenNone || maxTiles <= 0) ? 0 : MIN(maxTiles, tilesTotal - s->tile);
    if (n == 0 && !_relightWhole) return 0;

    if (n > 0 && s->gen == GenAmbo && s->tile == 0) s->ambo_pass++;

    // Settings for this frame.
    _scene.UpdateCameraUniforms(_width, _height);
    Uniforms &u = _scene.cb;
    u.g_cur_ambo_pass = (uint32_t)s->ambo_pass;
    u.g_main_ambo_pass = (uint32_t)_main.ambo_pass;
    u.g_refl_ambo_pass = (uint32_t)_refl.ambo_pass;
    u.g_intersection_set = (s == &_main) ? 0 : 1;
    u.g_geom_frames_since_geom_clear = (uint32_t)s->geom_passes;
    u.g_tile_info = simd_make_float4((float)[self tileWidth], (float)[self tileHeight],
                                     (float)[self tilesAcross], (float)[self tilesDown]);
    u.g_main_ambo_tiles_done = [self amboTilesDone:&_main extra:(s == &_main ? n : 0)];
    u.g_refl_ambo_tiles_done = [self amboTilesDone:&_refl extra:(s == &_refl ? n : 0)];
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
        [enc setRenderPipelineState:_pipelines.relight];
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
    [self setImageWidth:(int)size.width height:(int)size.height];
    _displayDirty = YES;
}

- (BOOL)hasPendingWork {
    return _relightWhole || _cur->gen != GenNone || _cur->next != GenNone || _main.clear_flags || _refl.clear_flags;
}

- (void)drawInMTKView:(MTKView *)view {
    CGSize size = view.drawableSize;
    [self setImageWidth:(int)size.width height:(int)size.height];

    // When the picture is finished and already on screen, do nothing at all,
    // so an idle app uses no graphics card time.
    if (![self hasPendingWork] && !_displayDirty) return;

    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    const int tiles = [self stepInto:cb maxTiles:(int)MAX(1.0, _tilesPerFrame)];

    // Copy the picture to the window.
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (_pipelines && _final) {
        simd_float4 viewSize = simd_make_float4((float)size.width, (float)size.height,
                                                1.0f / (float)size.width, 1.0f / (float)size.height);
        [enc setRenderPipelineState:_pipelines.display];
        [enc setFragmentTexture:_final atIndex:0];
        [enc setFragmentSamplerState:_linearClamp atIndex:0];
        [enc setFragmentBytes:&viewSize length:sizeof(viewSize) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    [cb presentDrawable:drawable];
    _displayDirty = NO;

    // Measure how long the graphics card took, and adjust how many tiles to
    // draw per frame so the app stays responsive whatever the scene costs.
    if (tiles > 0) {
        __weak Renderer *weakSelf = self;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
            double seconds = done.GPUEndTime - done.GPUStartTime;
            if (seconds <= 0) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                Renderer *me = weakSelf;
                if (!me) return;
                double ideal = kTargetGpuSeconds / (seconds / tiles);
                me->_tilesPerFrame = MIN(4096.0, MAX(1.0, 0.5 * me->_tilesPerFrame + 0.5 * ideal));
            });
        }];
    }
    [cb commit];
}

#pragma mark - Off-screen use and saving

- (void)runPasses:(int)passes {
    const int tilesTotal = [self tilesAcross] * [self tilesDown];
    for (int i = 0; i < passes; i++) {
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        [self stepInto:cb maxTiles:tilesTotal];
        [cb commit];
        [cb waitUntilCompleted];
    }
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

- (BOOL)saveImageToPNG:(NSString *)path {
    if (!_final || !_pipelines) return NO;

    // Relight the whole picture so it is up to date, and wait for it.
    _relightWhole = YES;
    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self stepInto:cb maxTiles:0];
    if (_final.storageMode == MTLStorageModeManaged) {
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit synchronizeResource:_final];
        [blit endEncoding];
    }
    [cb commit];
    [cb waitUntilCompleted];

    const size_t rowBytes = (size_t)_width * 4;
    std::vector<uint8_t> pixels(rowBytes * (size_t)_height);
    [_final getBytes:pixels.data() bytesPerRow:rowBytes fromRegion:MTLRegionMake2D(0, 0, _width, _height) mipmapLevel:0];

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), _width, _height, 8, rowBytes, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    BOOL ok = NO;
    if (image) {
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
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

@end
