#import "LightControls.h"

static inline simd_float3 xyz(simd_float4 v) { return simd_make_float3(v.x, v.y, v.z); }

simd_float3 LightDirectionInView(SceneState *scene, int i) {
    simd_float3 toLight = -xyz(scene->cb.g_light_dir[i]);   // stored as the way the light travels
    const Frame &cam = scene->camera;
    return simd_make_float3(simd_dot(toLight, cam.x), simd_dot(toLight, cam.y), simd_dot(toLight, cam.z));
}

void SetLightDirectionInView(SceneState *scene, int i, simd_float3 toLight) {
    const Frame &cam = scene->camera;
    simd_float3 world = cam.x * toLight.x + cam.y * toLight.y + cam.z * toLight.z;
    scene->SetLightDirection(i, -world);
}

NSString *DescribeLightDirection(simd_float3 t) {
    if (simd_length(t) < 1e-6f) return @"No direction";
    t = simd_normalize(t);
    const float lean = 0.38f;   // how far off-centre counts as "left", "above" and so on
    NSString *vertical = (t.y > lean) ? @"upper" : (t.y < -lean) ? @"lower" : nil;
    NSString *horizontal = (t.x > lean) ? @"right" : (t.x < -lean) ? @"left" : nil;

    NSString *side = nil;
    if (vertical && horizontal) side = [NSString stringWithFormat:@"%@ %@", vertical, horizontal];
    else if (horizontal) side = horizontal;
    else if (vertical) side = (t.y > 0) ? @"above" : @"below";

    NSString *depth = (t.z < -lean) ? @"in front" : (t.z > lean) ? @"behind" : nil;

    NSString *text;
    if (side && depth) text = [NSString stringWithFormat:@"%@, %@", side, depth];
    else if (side) text = [NSString stringWithFormat:@"%@, side-on", side];
    else text = (t.z < 0) ? @"straight on" : @"directly behind";
    return [[[text substringToIndex:1] uppercaseString] stringByAppendingString:[text substringFromIndex:1]];
}

float LightBrightness(SceneState *scene, int i) {
    simd_float4 c = scene->cb.g_light_col[i];
    return MAX(c.x, MAX(c.y, c.z));
}

NSColor *LightDisplayColor(SceneState *scene, int i) {
    simd_float4 c = scene->cb.g_light_col[i];
    float m = LightBrightness(scene, i);
    if (m < 0.002f) return [NSColor colorWithWhite:0.35 alpha:1];
    return [NSColor colorWithSRGBRed:c.x / m green:c.y / m blue:c.z / m alpha:1];
}

#pragma mark - Direction ball

@implementation LightBallView {
    int _dragLight;        // the light being dragged, or -1
    float _dragSign;       // which side it stays on while dragged: -1 in front, +1 behind
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) _dragLight = -1;
    return self;
}

- (NSSize)intrinsicContentSize { return NSMakeSize(132, 132); }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSPoint)centre { return NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)); }
- (CGFloat)radius { return MIN(self.bounds.size.width, self.bounds.size.height) / 2 - 12; }

- (NSPoint)pointForLight:(int)i {
    simd_float3 t = LightDirectionInView(self.renderer.scene, i);
    if (simd_length(t) > 1e-6f) t = simd_normalize(t);
    NSPoint c = [self centre];
    return NSMakePoint(c.x + t.x * [self radius], c.y + t.y * [self radius]);
}

- (void)setSelectedLight:(int)selectedLight {
    _selectedLight = selectedLight;
    self.needsDisplay = YES;
}

- (void)drawRect:(NSRect)dirtyRect {
    SceneState *scene = self.renderer.scene;
    if (!scene) return;
    NSPoint c = [self centre];
    CGFloat r = [self radius];
    NSRect disc = NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r);

    // The ball, shaded so it reads as a sphere.
    NSBezierPath *ball = [NSBezierPath bezierPathWithOvalInRect:disc];
    NSGradient *shade = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0.42 alpha:1]
                                                      endingColor:[NSColor colorWithWhite:0.13 alpha:1]];
    [shade drawInBezierPath:ball relativeCenterPosition:NSMakePoint(-0.35, 0.4)];
    [[NSColor colorWithWhite:1 alpha:0.25] setStroke];
    ball.lineWidth = 1;
    [ball stroke];

    // Lights behind the scene first (hollow), then those in front (solid), so
    // the front ones are never hidden.
    for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < kNumEditableLights; i++) {
            simd_float3 t = LightDirectionInView(scene, i);
            BOOL behind = t.z > 0;
            if (behind != (pass == 0)) continue;
            BOOL off = LightBrightness(scene, i) < 0.002f;
            BOOL selected = (i == self.selectedLight);
            NSPoint p = [self pointForLight:i];
            CGFloat d = off ? 3.5 : 6;
            NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - d, p.y - d, 2 * d, 2 * d)];
            NSColor *colour = LightDisplayColor(scene, i);
            if (behind) {
                [[NSColor colorWithWhite:0 alpha:0.35] setFill];
                [dot fill];
                [colour setStroke];
                dot.lineWidth = 2.5;
                [dot stroke];
            } else {
                [colour setFill];
                [dot fill];
                [[NSColor colorWithWhite:0 alpha:0.5] setStroke];
                dot.lineWidth = 1;
                [dot stroke];
            }
            if (selected) {
                CGFloat s = d + 4;
                NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(p.x - s, p.y - s, 2 * s, 2 * s)];
                [[NSColor whiteColor] setStroke];
                ring.lineWidth = 1.5;
                [ring stroke];
            }
        }
    }
}

// The light whose dot is nearest the point, if any is close enough.
- (int)lightAtPoint:(NSPoint)p {
    int best = -1;
    CGFloat bestDist = 13;
    for (int i = 0; i < kNumEditableLights; i++) {
        NSPoint q = [self pointForLight:i];
        CGFloat dist = hypot(p.x - q.x, p.y - q.y);
        // Prefer the selected light when two dots overlap.
        if (dist < bestDist || (dist < 13 && i == self.selectedLight)) {
            bestDist = dist;
            best = i;
            if (i == self.selectedLight) break;
        }
    }
    return best;
}

- (void)moveLight:(int)i toPoint:(NSPoint)p {
    NSPoint c = [self centre];
    float x = (float)((p.x - c.x) / [self radius]);
    float y = (float)((p.y - c.y) / [self radius]);
    float len = sqrtf(x * x + y * y);
    if (len > 1) {   // outside the ball: hold it at the rim
        x /= len;
        y /= len;
        len = 1;
    }
    float z = _dragSign * sqrtf(MAX(0.0f, 1 - len * len));
    SetLightDirectionInView(self.renderer.scene, i, simd_make_float3(x, y, z));
    [self.renderer relight];
    self.needsDisplay = YES;
    if (self.onChanged) self.onChanged();
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    int hit = [self lightAtPoint:p];
    int light = (hit >= 0) ? hit : self.selectedLight;   // a click on the ball itself moves the selected light
    if (light < 0 || light >= kNumEditableLights) return;
    if (hit >= 0 && hit != self.selectedLight && self.onSelect) self.onSelect(hit);

    simd_float3 t = LightDirectionInView(self.renderer.scene, light);
    _dragSign = (t.z > 0) ? 1 : -1;
    if (self.onWillChange) self.onWillChange();

    if (e.clickCount == 2 && hit >= 0) {
        // Double-click: flip between lighting the front and shining from behind.
        t.z = -t.z;
        SetLightDirectionInView(self.renderer.scene, light, t);
        [self.renderer relight];
        self.needsDisplay = YES;
        if (self.onChanged) self.onChanged();
        _dragLight = -1;
        return;
    }
    _dragLight = light;
    if (hit < 0) [self moveLight:light toPoint:p];
}

- (void)mouseDragged:(NSEvent *)e {
    if (_dragLight < 0) return;
    [self moveLight:_dragLight toPoint:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)mouseUp:(NSEvent *)e { _dragLight = -1; }

@end

#pragma mark - Hold button

@implementation HoldButton
- (void)mouseDown:(NSEvent *)e {
    if (self.onPress) self.onPress();
    [super mouseDown:e];   // returns when the mouse button is released
    if (self.onRelease) self.onRelease();
}
@end
