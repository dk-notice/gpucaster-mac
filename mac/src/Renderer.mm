#import "Renderer.h"
#import <ImageIO/ImageIO.h>
#import <simd/simd.h>
#include <vector>

static NSString *const kShaderFile = @"placeholder.metal";

// Must match struct Uniforms in shaders/placeholder.metal.
struct Uniforms {
    vector_float2 resolution;
    float time;
    float pad;
    vector_float2 drag;
};

@interface Renderer ()
@property (nonatomic, readwrite) NSString *lastError;
@property (nonatomic, readwrite) NSString *shaderDir;
@property (nonatomic, readwrite) double fps;
@property (nonatomic, readwrite) CGSize drawableSize;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    MTLPixelFormat _format;
    CFTimeInterval _start;
    vector_float2 _drag;
    int _frames;
    CFTimeInterval _fpsMark;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device pixelFormat:(MTLPixelFormat)format {
    if ((self = [super init])) {
        _device = device;
        _format = format;
        _queue = [device newCommandQueue];
        _start = CACurrentMediaTime();
        _fpsMark = _start;
        _shaderDir = [Renderer findShaderDir];
        [self reloadShaders];
    }
    return self;
}

// The shaders live outside the app bundle so they can be edited. Look for a
// "shaders" folder next to, or a few levels above, the app.
+ (NSString *)findShaderDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    const char *env = getenv("GPUCASTER_SHADER_DIR");
    if (env && *env) return [NSString stringWithUTF8String:env];

    NSString *dir = [[NSBundle mainBundle] bundlePath];
    for (int i = 0; i < 5; i++) {
        dir = [dir stringByDeletingLastPathComponent];
        NSString *candidate = [dir stringByAppendingPathComponent:@"shaders"];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:kShaderFile]])
            return candidate;
    }
    return nil;
}

- (BOOL)reloadShaders {
    if (!self.shaderDir) {
        self.lastError = @"Could not find the shaders folder.";
        return NO;
    }
    NSString *path = [self.shaderDir stringByAppendingPathComponent:kShaderFile];
    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
    if (!src) {
        self.lastError = [NSString stringWithFormat:@"Could not read %@:\n%@", path, err.localizedDescription];
        return NO;
    }
    id<MTLLibrary> lib = [_device newLibraryWithSource:src options:nil error:&err];
    if (!lib) {
        self.lastError = [NSString stringWithFormat:@"%@ did not compile:\n\n%@", kShaderFile, err.localizedDescription];
        return NO;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs_fullscreen"];
    pd.fragmentFunction = [lib newFunctionWithName:@"fs_main"];
    pd.colorAttachments[0].pixelFormat = _format;
    if (!pd.vertexFunction || !pd.fragmentFunction) {
        self.lastError = [NSString stringWithFormat:@"%@ must define vs_fullscreen and fs_main.", kShaderFile];
        return NO;
    }
    id<MTLRenderPipelineState> pipeline = [_device newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!pipeline) {
        self.lastError = [NSString stringWithFormat:@"Could not build the render pipeline:\n%@", err.localizedDescription];
        return NO;
    }
    _pipeline = pipeline;
    self.lastError = nil;
    return YES;
}

- (void)dragByX:(double)dx y:(double)dy {
    _drag.x += (float)(dx * 0.01);
    _drag.y += (float)(dy * 0.01);
}

// Draws one full-screen pass into whatever target the pass descriptor names.
- (void)encodeInto:(id<MTLCommandBuffer>)cb
              pass:(MTLRenderPassDescriptor *)pass
             width:(double)width
            height:(double)height
              time:(float)time {
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    if (_pipeline) {
        Uniforms u = {};
        u.resolution = simd_make_float2((float)width, (float)height);
        u.time = time;
        u.drag = _drag;
        [enc setRenderPipelineState:_pipeline];
        [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
}

#pragma mark - MTKViewDelegate

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    self.drawableSize = size;
}

- (void)drawInMTKView:(MTKView *)view {
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable) return;

    CGSize size = view.drawableSize;
    self.drawableSize = size;
    CFTimeInterval now = CACurrentMediaTime();

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self encodeInto:cb pass:pass width:size.width height:size.height time:(float)(now - _start)];
    [cb presentDrawable:drawable];
    [cb commit];

    _frames++;
    if (now - _fpsMark >= 0.5) {
        self.fps = _frames / (now - _fpsMark);
        _frames = 0;
        _fpsMark = now;
    }
}

#pragma mark - Off-screen render

- (BOOL)renderToPNG:(NSString *)path width:(int)width height:(int)height {
    if (!_pipeline) return NO;

    MTLTextureDescriptor *td =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_format width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:td];
    if (!target) return NO;

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [_queue commandBuffer];
    [self encodeInto:cb pass:pass width:width height:height time:0.0f];
    [cb commit];
    [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) return NO;

    // Copy the pixels back from the GPU and write them out as a PNG.
    const size_t rowBytes = (size_t)width * 4;
    std::vector<uint8_t> pixels(rowBytes * (size_t)height);
    [target getBytes:pixels.data()
         bytesPerRow:rowBytes
          fromRegion:MTLRegionMake2D(0, 0, width, height)
         mipmapLevel:0];

    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(pixels.data(), width, height, 8, rowBytes, cs,
                                             kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGImageRef image = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    BOOL ok = NO;
    if (image) {
        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
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
