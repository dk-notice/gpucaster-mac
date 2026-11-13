// Turns a square picture into a macOS app icon image: the picture clipped to
// the standard rounded square, with margins and a soft shadow, 1024 x 1024.
//
//   make_icon <square-input.png> <output.png>

#import <Cocoa/Cocoa.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) { fprintf(stderr, "usage: make_icon <input.png> <output.png>\n"); return 1; }
        NSImage *src = [[NSImage alloc] initWithContentsOfFile:@(argv[1])];
        if (!src) { fprintf(stderr, "make_icon: cannot read %s\n", argv[1]); return 1; }

        const int size = 1024;
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:size pixelsHigh:size
                                                                     bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];

        // Apple's icon grid: an 824-point rounded square centred in a 1024-point canvas.
        NSRect body = NSMakeRect(100, 100, 824, 824);
        NSBezierPath *shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 yRadius:185];

        [NSGraphicsContext saveGraphicsState];
        NSShadow *shadow = [NSShadow new];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        shadow.shadowBlurRadius = 24;
        shadow.shadowOffset = NSMakeSize(0, -12);
        [shadow set];
        [[NSColor blackColor] setFill];
        [shape fill];
        [NSGraphicsContext restoreGraphicsState];

        [shape addClip];
        [src drawInRect:body fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1];
        [NSGraphicsContext restoreGraphicsState];

        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        return [png writeToFile:@(argv[2]) atomically:YES] ? 0 : 1;
    }
}
