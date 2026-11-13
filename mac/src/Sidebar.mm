#import "Sidebar.h"
#import "LightControls.h"

static const CGFloat kSidebarWidth = 300;
static const CGFloat kSideMargin = 12;
static const NSInteger kShapeTagBase = 10000;
static const int kHistorySlots = 12;       // recent lightings shown
static const int kHistoryPerRow = 4;

#pragma mark - Diagnostic log

static FILE *gLogFile = NULL;
static CFTimeInterval gLogStart = 0;

NSString *GCLogPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Gpucaster/debug.log"];
}

void GCLogEnable(void) {
    if (gLogFile) return;
    NSString *path = GCLogPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    gLogFile = fopen(path.fileSystemRepresentation, "w");   // a fresh log each launch
    gLogStart = CACurrentMediaTime();
}

void GCLog(NSString *format, ...) {
    if (!gLogFile) return;
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    fprintf(gLogFile, "%8.3f  %s\n", CACurrentMediaTime() - gLogStart, line.UTF8String);
    fflush(gLogFile);
}

// A view whose origin is at the top-left, so scrolled content starts at the top.
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

typedef float (^FloatGetter)(void);
typedef void (^FloatSetter)(float);

// What has to happen after a control changes.
typedef NS_ENUM(int, ChangeKind) {
    ChangeRelight,   // only the lighting: instant
    ChangeRestart,   // the shape itself: start the picture again
    ChangeNothing,   // a setting that takes effect later
};

// One slider row and how it connects to the scene.
@interface SliderEntry : NSObject
@property (nonatomic, strong) NSSlider *slider;
@property (nonatomic, strong) NSTextField *valueLabel;
@property (nonatomic, copy) FloatGetter get;
@property (nonatomic, copy) FloatSetter set;
@property (nonatomic, copy) NSString *name;     // for grouping undo steps
@property (nonatomic) ChangeKind kind;
@property (nonatomic) BOOL integer;
@end
@implementation SliderEntry
- (NSString *)format:(float)v {
    return self.integer ? [NSString stringWithFormat:@"%d", (int)lroundf(v)] : [NSString stringWithFormat:@"%.2f", v];
}
- (void)refresh {
    float v = self.get();
    self.slider.floatValue = v;
    self.valueLabel.stringValue = [self format:v];
}
@end

@implementation Sidebar {
    Renderer *_renderer;
    NSStackView *_stack;          // everything, top to bottom
    NSStackView *_target;         // where the building-block methods add rows
    NSMutableArray<SliderEntry *> *_entries;        // indexed by slider tag
    NSMutableArray<NSStackView *> *_disclosures;   // collapsible groups, indexed by their arrow button's tag
    NSTextField *_speedLabel;
    NSButton *_halfDetail;
    NSButton *_sharpUpscale;
    NSButton *_skipSky;
    NSButton *_edr;
    NSButton *_fastMath;
    NSStackView *_shapeSection;   // sliders for the values the current shape declares
    NSMutableArray<SliderEntry *> *_shapeEntries;   // indexed by slider tag - kShapeTagBase
    NSInteger _shapeParamsSeen;   // which version of the renderer's list is on screen
    NSMutableArray<NSButton *> *_historyButtons;
    NSPopUpButton *_vizPopup;
    LightBallView *_ball;                         // where each light shines from
    NSMutableArray<NSView *> *_lightRows;         // one row per light: on/off, swatch, description
    NSMutableArray<NSButton *> *_lightToggles;
    NSMutableArray<NSView *> *_lightSwatches;
    NSMutableArray<NSButton *> *_lightNames;
    NSTextField *_selectedLightTitle;
    f4 _colorBeforeOff[kNumEditableLights];       // so switching a light back on restores it
    int _colorActionCount;                        // for testing: times a colour well reported a change
    CFTimeInterval _ignoreWellsUntil;             // briefly ignore the echo after the app itself sets a well
    NSColorWell *_lightColor;
    NSButton *_lightSpec;
    NSColorWell *_fogColor;
    NSButton *_amboDirectional;
}

- (instancetype)initWithRenderer:(Renderer *)renderer {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kSidebarWidth, 600)])) {
        _renderer = renderer;
        _entries = [NSMutableArray array];
        _shapeEntries = [NSMutableArray array];
        _shapeParamsSeen = -1;
        [self build];
        [self refresh];
    }
    return self;
}

- (SceneState *)scene { return _renderer.scene; }

// Tells the app a change is about to happen, so it can be undone.
- (void)noteChange:(NSString *)name {
    if (self.willChange) self.willChange(name);
}

#pragma mark - Building blocks

- (NSStackView *)verticalStack {
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 5;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

- (NSTextField *)label:(NSString *)text bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = bold ? [NSFont boldSystemFontOfSize:12] : [NSFont systemFontOfSize:11];
    l.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    return l;
}

- (void)addSection:(NSString *)title {
    NSView *previous = _target.arrangedSubviews.lastObject;
    if (previous) [_target setCustomSpacing:16 afterView:previous];
    [_target addArrangedSubview:[self label:title bold:YES]];
}

// Adds a view that fills the width of the current stack (inside its margins).
- (void)addRow:(NSView *)row {
    [_target addArrangedSubview:row];
    CGFloat margins = (_target == _stack) ? -2 * kSideMargin : 0;
    [row.widthAnchor constraintEqualToAnchor:_target.widthAnchor constant:margins].active = YES;
}

- (NSStackView *)rowWithTitle:(NSString *)title control:(NSView *)control {
    NSTextField *l = [self label:title bold:NO];
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [l.widthAnchor constraintEqualToConstant:104].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[l, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    [self addRow:row];
    return row;
}

- (SliderEntry *)addSlider:(NSString *)title
                       min:(float)min
                       max:(float)max
                      kind:(ChangeKind)kind
                       get:(FloatGetter)get
                       set:(FloatSetter)set {
    SliderEntry *e = [SliderEntry new];
    e.get = get;
    e.set = set;
    e.kind = kind;
    e.name = title;

    e.slider = [NSSlider sliderWithValue:min minValue:min maxValue:max target:self action:@selector(sliderMoved:)];
    e.slider.continuous = YES;
    e.slider.controlSize = NSControlSizeSmall;
    e.slider.tag = (NSInteger)_entries.count;
    [_entries addObject:e];

    e.valueLabel = [self label:@"0.00" bold:NO];
    e.valueLabel.alignment = NSTextAlignmentRight;
    e.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    [e.valueLabel.widthAnchor constraintEqualToConstant:34].active = YES;

    NSStackView *row = [self rowWithTitle:title control:e.slider];
    [row addArrangedSubview:e.valueLabel];
    return e;
}

- (NSString *)describeView:(NSView *)view {
    if (!view) return @"nothing";
    for (NSView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:[NSSlider class]]) {
            for (SliderEntry *e in [_entries arrayByAddingObjectsFromArray:_shapeEntries])
                if (e.slider == v) return [NSString stringWithFormat:@"slider \"%@\" (tag %ld, enabled %d)", e.name, (long)e.slider.tag, e.slider.enabled];
            return @"slider (unknown)";
        }
        if ([v isKindOfClass:[NSButton class]]) return [NSString stringWithFormat:@"%@ \"%@\"", NSStringFromClass([v class]), ((NSButton *)v).title];
        if ([v isKindOfClass:[NSControl class]]) return NSStringFromClass([v class]);
    }
    return [NSString stringWithFormat:@"%@ (inside %@)", NSStringFromClass([view class]), NSStringFromClass([view.superview class])];
}

- (void)sliderMoved:(NSSlider *)slider {
    SliderEntry *e = (slider.tag >= kShapeTagBase) ? _shapeEntries[(NSUInteger)(slider.tag - kShapeTagBase)]
                                                   : _entries[(NSUInteger)slider.tag];
    {
        float before = e.get();
        GCLog(@"slider \"%@\" moved to %.3f (scene had %.3f; selected light %d; solo %d; picker open %d; event %@)", e.name,
              slider.floatValue, before, _selectedLight + 1, _renderer.soloLight + 1, NSColorPanel.sharedColorPanelExists && NSColorPanel.sharedColorPanel.visible,
              NSApp.currentEvent ? @(NSApp.currentEvent.type) : @"none");
        // Shortly afterwards, record whether the change stuck.
        __weak Sidebar *weakSelf = self;
        float wanted = slider.floatValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            GCLog(@"   0.4 s later: slider \"%@\" shows %.3f, scene has %.3f (was set to %.3f)", e.name, e.slider.floatValue, e.get(), wanted);
        });
    }
    [self noteChange:e.name];
    float v = e.integer ? roundf(slider.floatValue) : slider.floatValue;
    e.set(v);
    e.valueLabel.stringValue = [e format:v];
    if (e.kind == ChangeRelight) [_renderer relight];
    else if (e.kind == ChangeRestart) [_renderer clearAll];
}

- (NSButton *)addCheckbox:(NSString *)title action:(SEL)action {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11];
    [_target addArrangedSubview:b];
    return b;
}

- (NSButton *)button:(NSString *)title action:(SEL)action {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11];
    return b;
}

- (void)addButtons:(NSArray<NSButton *> *)buttons {
    NSStackView *row = [NSStackView stackViewWithViews:buttons];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    [_target addArrangedSubview:row];
}

- (NSPopUpButton *)addPopup:(NSString *)title items:(NSArray<NSString *> *)items action:(SEL)action {
    NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    p.controlSize = NSControlSizeSmall;
    p.font = [NSFont systemFontOfSize:11];
    [p addItemsWithTitles:items];
    p.target = self;
    p.action = action;
    [self rowWithTitle:title control:p];
    return p;
}

- (NSColorWell *)addColorWell:(NSString *)title action:(SEL)action {
    NSColorWell *w = [[NSColorWell alloc] initWithFrame:NSMakeRect(0, 0, 44, 22)];
    w.target = self;
    w.action = action;
    [w.widthAnchor constraintEqualToConstant:44].active = YES;
    [w.heightAnchor constraintEqualToConstant:22].active = YES;
    NSStackView *row = [self rowWithTitle:title control:w];
    [row addArrangedSubview:[NSView new]];   // spacer, keeps the well at its natural size
    return w;
}

- (void)addNote:(NSString *)text {
    NSTextField *note = [self label:text bold:NO];
    note.textColor = NSColor.tertiaryLabelColor;
    [_target addArrangedSubview:note];
}

// The colour to show in a light's colour well.  A light can be brighter than
// any colour a picker can show, so above full brightness only the hue is shown.
static NSColor *LightWellColor(SceneState *scene, int i) {
    f4 c = scene->cb.g_light_col[i];
    float m = MAX(1.0f, MAX(c.x, MAX(c.y, c.z)));
    return [NSColor colorWithSRGBRed:MAX(c.x, 0) / m green:MAX(c.y, 0) / m blue:MAX(c.z, 0) / m alpha:1];
}

static NSColor *ColorFrom(f4 c) {
    return [NSColor colorWithSRGBRed:MIN(MAX(c.x, 0), 1) green:MIN(MAX(c.y, 0), 1) blue:MIN(MAX(c.z, 0), 1) alpha:1];
}

static void ColorInto(NSColor *color, f4 *out) {
    NSColor *c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!c) return;
    out->x = (float)c.redComponent;
    out->y = (float)c.greenComponent;
    out->z = (float)c.blueComponent;
}

#pragma mark - Layout

- (void)build {
    _stack = [self verticalStack];
    _stack.edgeInsets = NSEdgeInsetsMake(12, kSideMargin, 16, kSideMargin);
    _target = _stack;

    FlippedView *doc = [FlippedView new];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:_stack];

    NSScrollView *scroll = [NSScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    scroll.documentView = doc;
    [self addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:kSidebarWidth],
        [scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [doc.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [doc.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [_stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [_stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [_stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [_stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
    ]];

    __weak Sidebar *weakSelf = self;
    __weak Renderer *renderer = _renderer;
    #define SCENE_VALUE(expr) \
        get:^float { return weakSelf.scene->expr; } set:^(float v) { weakSelf.scene->expr = v; }

    // ---- Shape (filled in by -syncShapeParams) ----
    _shapeSection = [self verticalStack];
    [self addRow:_shapeSection];
    _shapeSection.hidden = YES;

    // ---- View ----
    [self addSection:@"View"];
    NSMutableArray *vizNames = [NSMutableArray array];
    for (int i = 0; i < kNumVizModes; i++) [vizNames addObject:kVizModeNames[i]];
    _vizPopup = [self addPopup:@"Show" items:vizNames action:@selector(vizChanged:)];
    [self addSlider:@"Brightness" min:0 max:5 kind:ChangeRelight SCENE_VALUE(cb.kLightScale)];
    [self addSlider:@"Saturation" min:0 max:4 kind:ChangeRelight SCENE_VALUE(cb.kLightSat)];

    // ---- Quality ----
    [self addSection:@"Quality"];
    [self addSlider:@"Geometry passes" min:8 max:200 kind:ChangeNothing
                get:^float { return renderer.autoGeomPasses; }
                set:^(float v) { renderer.autoGeomPasses = (int)v; }].integer = YES;
    [self addSlider:@"Shading passes" min:4 max:256 kind:ChangeNothing
                get:^float { return renderer.autoAmboPasses; }
                set:^(float v) { renderer.autoAmboPasses = (int)v; }].integer = YES;
    [self addNote:@"Used the next time the picture restarts."];

    // ---- Lights ----
    [self addSection:@"Lights"];

    // The ball: a stand-in for the scene, with a dot where each light shines from.
    _ball = [[LightBallView alloc] initWithFrame:NSMakeRect(0, 0, 132, 132)];
    _ball.renderer = _renderer;
    _ball.onSelect = ^(int light) { weakSelf.selectedLight = light; };
    _ball.onWillChange = ^{ [weakSelf noteChange:@"Light direction"]; };
    _ball.onChanged = ^{ [weakSelf syncLights]; };
    NSTextField *ballHelp = [NSTextField wrappingLabelWithString:
        @"Each dot is a light, placed where it shines from as you look at the scene.\n\n"
         "Solid: lights the front.\nHollow: shines from behind.\n\n"
         "Drag a dot to move a light. Double-click to flip it front or behind."];
    ballHelp.selectable = NO;   // (wrapping labels are selectable by default, which would steal key presses)
    ballHelp.font = [NSFont systemFontOfSize:10];
    ballHelp.textColor = NSColor.tertiaryLabelColor;
    NSStackView *ballRow = [NSStackView stackViewWithViews:@[_ball, ballHelp]];
    ballRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    ballRow.alignment = NSLayoutAttributeCenterY;
    ballRow.spacing = 8;
    [self addRow:ballRow];

    // One row per light.
    _lightRows = [NSMutableArray array];
    _lightToggles = [NSMutableArray array];
    _lightSwatches = [NSMutableArray array];
    _lightNames = [NSMutableArray array];
    for (int i = 0; i < kNumEditableLights; i++) {
        NSButton *toggle = [NSButton checkboxWithTitle:@"" target:self action:@selector(lightToggled:)];
        toggle.controlSize = NSControlSizeSmall;
        toggle.tag = i;
        toggle.toolTip = @"Switch this light on or off";

        NSView *swatch = [NSView new];
        swatch.wantsLayer = YES;
        swatch.layer.cornerRadius = 4;
        swatch.layer.borderWidth = 1;
        swatch.layer.borderColor = [NSColor colorWithWhite:0.5 alpha:0.6].CGColor;
        [swatch.widthAnchor constraintEqualToConstant:18].active = YES;
        [swatch.heightAnchor constraintEqualToConstant:14].active = YES;

        NSButton *name = [NSButton buttonWithTitle:@"" target:self action:@selector(lightRowClicked:)];
        name.bordered = NO;
        name.alignment = NSTextAlignmentLeft;
        name.font = [NSFont systemFontOfSize:11];
        name.tag = i;
        [name setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];

        NSStackView *row = [NSStackView stackViewWithViews:@[toggle, swatch, name]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 6;
        row.edgeInsets = NSEdgeInsetsMake(2, 4, 2, 4);
        row.wantsLayer = YES;
        row.layer.cornerRadius = 5;
        [self addRow:row];
        [_lightRows addObject:row];
        [_lightToggles addObject:toggle];
        [_lightSwatches addObject:swatch];
        [_lightNames addObject:name];
    }

    // Settings for whichever light is selected.
    _selectedLightTitle = [self label:@"" bold:NO];
    _selectedLightTitle.textColor = NSColor.labelColor;
    [_stack setCustomSpacing:10 afterView:_lightRows.lastObject];
    [_target addArrangedSubview:_selectedLightTitle];
    _lightColor = [self addColorWell:@"Colour" action:@selector(lightColorChanged:)];
    [self addSlider:@"Brightness" min:0 max:2 kind:ChangeRelight
                get:^float { return LightBrightness(weakSelf.scene, weakSelf.selectedLight); }
                set:^(float v) { [weakSelf setSelectedLightBrightness:v]; }].name = @"Light brightness";
    [self addSlider:@"Wrap" min:0 max:1 kind:ChangeRelight
                get:^float { return weakSelf.scene->cb.g_light_wrap[weakSelf.selectedLight].x; }
                set:^(float v) { weakSelf.scene->cb.g_light_wrap[weakSelf.selectedLight].x = v; }];
    _lightSpec = [self addCheckbox:@"Adds a shiny highlight" action:@selector(lightSpecChanged:)];
    [self addButtons:@[
        [self button:@"Random colour" action:@selector(randomLightColor:)],
        [self button:@"Random direction" action:@selector(randomLightDir:)],
    ]];
    HoldButton *solo = [HoldButton buttonWithTitle:@"Hold to see this light alone" target:nil action:nil];
    solo.controlSize = NSControlSizeSmall;
    solo.font = [NSFont systemFontOfSize:11];
    solo.onPress = ^{ GCLog(@"solo pressed"); renderer.soloLight = weakSelf.selectedLight; };
    solo.onRelease = ^{ GCLog(@"solo released"); renderer.soloLight = -1; };
    [_target addArrangedSubview:solo];
    [_stack setCustomSpacing:12 afterView:solo];

    [self addButtons:@[
        [self button:@"Randomize all lighting" action:@selector(randomAll:)],
        [self button:@"Keep current" action:@selector(keepLighting:)],
    ]];

    // Recent lightings, as small pictures to click.
    [self addNote:@"Recent lighting (click one to go back to it):"];
    _historyButtons = [NSMutableArray array];
    for (int row = 0; row < kHistorySlots / kHistoryPerRow; row++) {
        NSMutableArray *buttons = [NSMutableArray array];
        for (int col = 0; col < kHistoryPerRow; col++) {
            NSButton *b = [NSButton buttonWithTitle:@"" target:self action:@selector(historyClicked:)];
            b.bordered = NO;
            b.imagePosition = NSImageOnly;
            b.imageScaling = NSImageScaleProportionallyUpOrDown;
            b.tag = (NSInteger)_historyButtons.count;
            b.hidden = YES;
            [b.widthAnchor constraintEqualToConstant:63].active = YES;
            [b.heightAnchor constraintEqualToConstant:42].active = YES;
            [_historyButtons addObject:b];
            [buttons addObject:b];
        }
        NSStackView *r = [NSStackView stackViewWithViews:buttons];
        r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        r.spacing = 6;
        r.detachesHiddenViews = YES;
        [_target addArrangedSubview:r];
    }

    // ---- Ambient occlusion ----
    [self addSection:@"Ambient occlusion"];
    [self addSlider:@"Dark below" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDiffuseUnLitThresh)];
    [self addSlider:@"Bright above" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDiffuseFullyLitThresh)];
    [self addSlider:@"Contrast" min:0 max:4 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDiffuseExponent)];
    _amboDirectional = [self addCheckbox:@"Directional shadowing" action:@selector(amboDirectionalChanged:)];
    [self addButtons:@[[self button:@"Randomize" action:@selector(randomAmbo:)]]];

    // ---- Shiny highlights ----
    [self addSection:@"Shiny highlights"];
    [self addSlider:@"Strength" min:0 max:1.5 kind:ChangeRelight SCENE_VALUE(cb.kLightSpecStr)];
    [self addSlider:@"Sharpness" min:0 max:8 kind:ChangeRelight SCENE_VALUE(cb.kLightSpecPow)];
    [self addButtons:@[[self button:@"Randomize" action:@selector(randomSpec:)]]];

    // ---- Fog ----
    [self addSection:@"Fog"];
    _fogColor = [self addColorWell:@"Colour" action:@selector(fogColorChanged:)];
    [self addSlider:@"Density" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.g_fog_params.x)];
    [self addSlider:@"Falloff" min:0 max:4 kind:ChangeRelight SCENE_VALUE(cb.g_fog_params.y)];
    [self addButtons:@[
        [self button:@"Random colour" action:@selector(randomFogColor:)],
        [self button:@"Random fog" action:@selector(randomFog:)],
    ]];

    // ---- Surface ----
    [self addSection:@"Surface"];
    [self addSlider:@"Reflectivity" min:0 max:2 kind:ChangeRelight SCENE_VALUE(cb.kReflectivity)];
    [self addSlider:@"Surface colour" min:0 max:2 kind:ChangeRelight SCENE_VALUE(cb.kSurfaceColorAmount)];
    [self addNote:@"Reflections are drawn when reflectivity is above zero."];

    // ---- Advanced (hidden until asked for) ----
    [self beginDisclosure:@"Advanced"];
    [self addNote:@"Where shiny highlights fade in, by ambient level:"];
    [self addSlider:@"Highlights from" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboSpecLo)];
    [self addSlider:@"Highlights to" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboSpecHi)];
    [self addNote:@"Directional shadowing:"];
    [self addSlider:@"Shadow scale" min:0 max:8 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDirScale)];
    [self addSlider:@"Shadow bias" min:-2 max:2 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDirBias)];
    [self endDisclosure];

    // ---- Experimental (hidden until asked for) ----
    [self beginDisclosure:@"Experimental"];
    [self addWrappedNote:@"Options that are off by default: most trade a little accuracy for speed. They are remembered between launches but are not saved in scenes. Large exports ignore them and always render at full detail and full accuracy, so you can design with them on and export the finished picture."];
    _speedLabel = [self label:@"Speed: not measured yet" bold:NO];
    _speedLabel.textColor = NSColor.labelColor;
    _speedLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    [_target addArrangedSubview:_speedLabel];
    _halfDetail = [self addCheckbox:@"Half detail" action:@selector(halfDetailChanged:)];
    [self addWrappedNote:@"Draws a quarter of the pixels and enlarges the result. About four times faster; the picture is softer."];
    _sharpUpscale = [self addCheckbox:@"Sharpen Half detail with MetalFX" action:@selector(sharpUpscaleChanged:)];
    [self addWrappedNote:@"Enlarges the half-size picture with Apple's upscaler. Crisper edges than plain enlargement; fine noisy detail can look harsher."];
    _skipSky = [self addCheckbox:@"Skip empty sky" action:@selector(skipSkyChanged:)];
    [self addWrappedNote:@"After 16 geometry passes, stops testing parts of the picture where nothing has been found. Faster when there is a lot of empty background; a thin feature not yet found by then is missed."];
    _edr = [self addCheckbox:@"Extended brightness" action:@selector(edrChanged:)];
    [self addWrappedNote:@"On displays that can go brighter than white (such as recent MacBook Pro screens), shows very bright parts of the picture as brighter, instead of clipping them to white. Only what you see changes; saved images are the same."];
    _fastMath = [self addCheckbox:@"Fast math" action:@selector(fastMathChanged:)];
    [self addWrappedNote:@"Lets the graphics card take shortcuts in arithmetic. Much faster for some shapes (three to four times for the Mandelbox and Blobs), little different for others. In tests the picture was almost identical, but it can differ. The shaders are recompiled when this changes."];
    [self endDisclosure];
    #undef SCENE_VALUE
}

// Rebuilds the Shape section when the shape, or its list of adjustable values, changes.
- (void)syncShapeParams {
    if (_shapeParamsSeen == _renderer.shapeParamsVersion) return;
    _shapeParamsSeen = _renderer.shapeParamsVersion;

    for (NSView *v in [_shapeSection.arrangedSubviews copy]) {
        [_shapeSection removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_shapeEntries removeAllObjects];

    NSArray<ShapeParam *> *params = _renderer.shapeParams;
    _shapeSection.hidden = (params.count == 0);
    if (params.count == 0) return;

    __weak Renderer *renderer = _renderer;
    _target = _shapeSection;
    [_shapeSection addArrangedSubview:[self label:[Renderer displayNameForShape:_renderer.shapePath] bold:YES]];
    for (ShapeParam *param in params) {
        SliderEntry *e = [self addSlider:param.label min:param.minValue max:param.maxValue kind:ChangeNothing
                                     get:^float { return [renderer valueOfParam:param]; }
                                     set:^(float v) { [renderer setValue:v ofParam:param]; }];
        e.integer = param.integer;
        // (Shape sliders are kept in their own list, because they come and go.)
        [_entries removeLastObject];
        e.slider.tag = kShapeTagBase + (NSInteger)_shapeEntries.count;
        [_shapeEntries addObject:e];
        [e refresh];
    }
    [self addButtons:@[[self button:@"Reset to defaults" action:@selector(resetShapeParams:)]]];
    [_stack setCustomSpacing:16 afterView:_shapeSection];
    _target = _stack;
}

- (void)resetShapeParams:(id)sender {
    [self noteChange:nil];
    [_renderer resetShapeParams];
    [self refresh];
}

- (void)setLightingHistory:(NSArray<NSImage *> *)images {
    for (NSUInteger i = 0; i < _historyButtons.count; i++) {
        NSButton *b = _historyButtons[i];
        b.hidden = (i >= images.count);
        if (i < images.count) b.image = images[i];
    }
}

- (void)historyClicked:(NSButton *)b {
    if (self.onPickLighting) self.onPickLighting(b.tag);
}

- (void)keepLighting:(id)sender {
    if (self.onKeepLighting) self.onKeepLighting();
}

- (void)collectControlsIn:(NSView *)view into:(NSMutableArray<NSControl *> *)out {
    for (NSView *sub in view.subviews) {
        if ([sub isKindOfClass:[NSSlider class]] || [sub isKindOfClass:[NSButton class]] ||
            [sub isKindOfClass:[NSPopUpButton class]] || [sub isKindOfClass:[NSColorWell class]])
            [out addObject:(NSControl *)sub];
        else
            [self collectControlsIn:sub into:out];
    }
}

- (NSString *)checkControls {
    NSMutableString *report = [NSMutableString string];
    int problems = 0;

    // 1. Each slider, driven the way a drag drives it.
    NSArray<SliderEntry *> *all = [_entries arrayByAddingObjectsFromArray:_shapeEntries];
    for (SliderEntry *e in all) {
        float old = e.get();
        float lo = (float)e.slider.minValue, hi = (float)e.slider.maxValue;
        float v = lo + 0.37f * (hi - lo);
        if (e.integer) v = roundf(v);
        e.slider.floatValue = v;
        [self sliderMoved:e.slider];
        float got = e.get();
        float shown = e.slider.floatValue;
        BOOL ok = fabsf(got - v) < 1e-3f * MAX(1.0f, fabsf(hi - lo)) && fabsf(shown - v) < 1e-3f * MAX(1.0f, fabsf(hi - lo));
        if (!ok) {
            problems++;
            [report appendFormat:@"PROBLEM slider \"%@\": set %.3f, scene has %.3f, slider shows %.3f\n", e.name, v, got, shown];
        }
        e.slider.floatValue = old;
        [self sliderMoved:e.slider];
    }
    [report appendFormat:@"%d sliders driven\n", (int)all.count];

    // 1a. Brightness and Wrap for each light in turn: the value must stick
    // after the app's regular housekeeping has run, and the picture must change.
    {
        auto spin = ^(double seconds) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; };
        auto picture = ^NSData * {
            std::vector<Lighting> one;
            one.push_back(self.scene->GetLighting());
            return [[self->_renderer thumbnailsForLightings:one width:160].firstObject TIFFRepresentation];
        };
        for (int light = 0; light < kNumEditableLights; light++) {
            self.selectedLight = light;
            spin(0.1);
            for (SliderEntry *e in _entries) {
                if (![e.name isEqualToString:@"Light brightness"] && ![e.name isEqualToString:@"Wrap"]) continue;
                float old = e.get();
                NSData *before = picture();
                float hi = (float)e.slider.maxValue;
                float v = (old > 0.5f * hi) ? 0.1f * hi : 0.9f * hi;
                e.slider.floatValue = v;
                [self sliderMoved:e.slider];
                spin(0.6);
                float got = e.get(), shown = e.slider.floatValue;
                BOOL changed = ![before isEqualToData:picture()];
                BOOL lit = LightBrightness(self.scene, light) >= 0.002f;
                [report appendFormat:@"light %d %@: %.2f -> %.2f, scene %.2f, slider %.2f, picture %@\n", light + 1, e.name, old, v, got,
                                     shown, changed ? @"changed" : @"UNCHANGED"];
                if (fabsf(got - v) > 0.01f * hi || fabsf(shown - v) > 0.01f * hi || (lit && !changed)) {
                    problems++;
                    [report appendFormat:@"PROBLEM light %d slider \"%@\" did not take effect\n", light + 1, e.name];
                }
                e.slider.floatValue = old;
                [self sliderMoved:e.slider];
            }
        }
        self.selectedLight = 0;
    }

    // 1b. With the colour picker open on the light's colour: one change in the
    // picker should be reported once, the light should take that colour, and
    // the Brightness and Wrap sliders should still work.
    {
        auto spin = ^(double seconds) { [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]]; };
        [_lightColor activate:YES];
        spin(0.3);
        _colorActionCount = 0;
        NSColor *picked = [NSColor colorWithSRGBRed:0.2 green:0.4 blue:0.3 alpha:1];
        [NSColorPanel sharedColorPanel].color = picked;
        spin(0.7);
        f4 c = self.scene->cb.g_light_col[_selectedLight];
        NSColor *panelNow = [[NSColorPanel sharedColorPanel].color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        [report appendFormat:@"colour picker: %d change reports; light colour now (%.2f %.2f %.2f); picker shows (%.2f %.2f %.2f)\n",
                             _colorActionCount, c.x, c.y, c.z, panelNow.redComponent, panelNow.greenComponent, panelNow.blueComponent];
        if (_colorActionCount < 1 || _colorActionCount > 2) { problems++; [report appendString:@"PROBLEM one change in the colour picker should be reported once\n"]; }
        if (fabsf(c.x - 0.2f) > 0.02f || fabsf(c.y - 0.4f) > 0.02f || fabsf(c.z - 0.3f) > 0.02f) {
            problems++;
            [report appendString:@"PROBLEM the light did not take the colour chosen in the picker\n"];
        }
        if (fabs(panelNow.redComponent - 0.2) > 0.02 || fabs(panelNow.greenComponent - 0.4) > 0.02 || fabs(panelNow.blueComponent - 0.3) > 0.02) {
            problems++;
            [report appendString:@"PROBLEM the picker did not keep the colour that was chosen in it\n"];
        }
        // A second, different pick straight afterwards must also arrive (the echo guard must not swallow it).
        spin(0.3);
        [NSColorPanel sharedColorPanel].color = [NSColor colorWithSRGBRed:0.9 green:0.1 blue:0.5 alpha:1];
        spin(0.5);
        c = self.scene->cb.g_light_col[_selectedLight];
        if (fabsf(c.x - 0.9f) > 0.02f || fabsf(c.y - 0.1f) > 0.02f || fabsf(c.z - 0.5f) > 0.02f) {
            problems++;
            [report appendFormat:@"PROBLEM a second pick did not arrive: light colour is (%.2f %.2f %.2f)\n", c.x, c.y, c.z];
        }
        for (SliderEntry *e in _entries) {
            if (![e.name isEqualToString:@"Light brightness"] && ![e.name isEqualToString:@"Wrap"]) continue;
            float hi = (float)e.slider.maxValue;
            float v = 0.81f * hi;
            e.slider.floatValue = v;
            [self sliderMoved:e.slider];
            spin(0.4);
            float got = e.get(), shown = e.slider.floatValue;
            if (fabsf(got - v) > 0.01f * hi || fabsf(shown - v) > 0.01f * hi) {
                problems++;
                [report appendFormat:@"PROBLEM with the picker open, slider \"%@\": set %.3f, scene has %.3f, slider shows %.3f\n", e.name, v, got, shown];
            }
        }
        [_lightColor deactivate];
        [[NSColorPanel sharedColorPanel] orderOut:nil];
    }

    // 2. Each visible, enabled control must be what a click on it reaches.
    NSMutableArray<NSControl *> *controls = [NSMutableArray array];
    [self collectControlsIn:self into:controls];
    int visible = 0;
    for (NSControl *c in controls) {
        NSRect r = NSIntersectionRect(c.bounds, c.visibleRect);   // the part not scrolled out of sight
        if (c.hiddenOrHasHiddenAncestor || r.size.width < 2 || r.size.height < 2) continue;
        visible++;
        // Try several points across the control, not only its centre.
        for (double f : {0.1, 0.3, 0.5, 0.7, 0.9}) {
            NSPoint inWindow = [c convertPoint:NSMakePoint(NSMinX(r) + f * r.size.width, NSMidY(r)) toView:nil];
            NSView *hit = [self.window.contentView hitTest:inWindow];
            if (hit && (hit == c || [hit isDescendantOf:c])) continue;
            problems++;
            NSString *what = [c isKindOfClass:[NSButton class]] ? ((NSButton *)c).title : NSStringFromClass([c class]);
            [report appendFormat:@"PROBLEM a click %.0f%% of the way across %@ \"%@\" (y %.0f) lands on %@ instead\n", f * 100,
                                 NSStringFromClass([c class]), what, inWindow.y, hit ? NSStringFromClass([hit class]) : @"nothing"];
            break;
        }
    }
    [report appendFormat:@"%d visible controls hit-tested, %d problems\n", visible, problems];
    return report;
}

// Shows a colour in a well.  If the colour picker is open on that well it is
// updated too, and the "colour changed" message that comes back is ignored,
// so the app and the picker never push colours back and forth.
- (void)showColor:(NSColor *)color inWell:(NSColorWell *)well {
    _ignoreWellsUntil = CACurrentMediaTime() + 0.2;
    well.color = color;
    if (well.isActive) [NSColorPanel sharedColorPanel].color = color;
}

// Starts a collapsible group at the bottom of the sidebar: a heading with an
// arrow, and controls that stay hidden until the arrow is clicked.  Rows added
// before -endDisclosure go inside it.
- (void)beginDisclosure:(NSString *)title {
    if (!_disclosures) _disclosures = [NSMutableArray array];
    NSView *previous = _stack.arrangedSubviews.lastObject;
    if (previous) [_stack setCustomSpacing:16 afterView:previous];
    NSButton *arrow = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleDisclosure:)];
    arrow.bezelStyle = NSBezelStyleDisclosure;
    [arrow setButtonType:NSButtonTypePushOnPushOff];
    arrow.tag = (NSInteger)_disclosures.count;
    NSStackView *header = [NSStackView stackViewWithViews:@[arrow, [self label:title bold:YES]]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.spacing = 4;
    [_stack addArrangedSubview:header];

    NSStackView *content = [self verticalStack];
    [self addRow:content];
    content.hidden = YES;
    [_disclosures addObject:content];
    _target = content;
}

- (void)endDisclosure { _target = _stack; }

// For checking the layout without a person: opens every collapsible group and
// scrolls to the bottom, where they are.
- (void)expandAllForSnapshot {
    for (NSStackView *group in _disclosures) group.hidden = NO;
    [self layoutSubtreeIfNeeded];
    NSView *doc = _stack.superview;
    [doc scrollPoint:NSMakePoint(0, NSMaxY(doc.bounds))];
}

- (void)toggleDisclosure:(NSButton *)b {
    _disclosures[(NSUInteger)b.tag].hidden = (b.state != NSControlStateValueOn);
}

// A note that wraps onto several lines to fit the sidebar.
- (void)addWrappedNote:(NSString *)text {
    NSTextField *note = [NSTextField wrappingLabelWithString:text];
    note.selectable = NO;
    note.font = [NSFont systemFontOfSize:10];
    note.textColor = NSColor.tertiaryLabelColor;
    [self addRow:note];
}

static NSString *const kPrefHalfDetail = @"HalfDetail";
static NSString *const kPrefFastMath = @"FastMath";
static NSString *const kPrefSharpUpscale = @"SharpUpscale";
static NSString *const kPrefSkipSky = @"SkipEmptySky";

static NSString *const kPrefEDR = @"ExtendedBrightness";

- (void)edrChanged:(NSButton *)b {
    BOOL on = (b.state == NSControlStateValueOn);
    _renderer.edrOutput = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefEDR];
}

- (void)sharpUpscaleChanged:(NSButton *)b {
    BOOL on = (b.state == NSControlStateValueOn);
    _renderer.sharpUpscale = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefSharpUpscale];
}

- (void)skipSkyChanged:(NSButton *)b {
    BOOL on = (b.state == NSControlStateValueOn);
    _renderer.skipEmptySky = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefSkipSky];
    [_renderer clearAll];   // start again, so the picture shows what the option does
}

- (void)halfDetailChanged:(NSButton *)b {
    BOOL on = (b.state == NSControlStateValueOn);
    _renderer.detailDivisor = on ? 2 : 1;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefHalfDetail];
}

- (void)fastMathChanged:(NSButton *)b {
    BOOL on = (b.state == NSControlStateValueOn);
    _renderer.fastMath = on;
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kPrefFastMath];
}

- (void)applySavedExperimentalOptions {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    // (Environment variables override, for measuring each option from the command line.)
    BOOL half = getenv("GPUCASTER_HALF") ? atoi(getenv("GPUCASTER_HALF")) != 0 : [d boolForKey:kPrefHalfDetail];
    BOOL fast = getenv("GPUCASTER_FASTMATH") ? atoi(getenv("GPUCASTER_FASTMATH")) != 0 : [d boolForKey:kPrefFastMath];
    BOOL sharp = getenv("GPUCASTER_SHARP") ? atoi(getenv("GPUCASTER_SHARP")) != 0 : [d boolForKey:kPrefSharpUpscale];
    BOOL skip = getenv("GPUCASTER_SKIPSKY") ? atoi(getenv("GPUCASTER_SKIPSKY")) != 0 : [d boolForKey:kPrefSkipSky];
    _renderer.detailDivisor = half ? 2 : 1;
    _renderer.fastMath = fast;
    _renderer.sharpUpscale = sharp;
    _renderer.skipEmptySky = skip;
    _renderer.edrOutput = getenv("GPUCASTER_EDR") ? atoi(getenv("GPUCASTER_EDR")) != 0 : [d boolForKey:kPrefEDR];
    [self syncExperimental];
}

// Keeps the Experimental group's ticks and speed reading up to date.
- (void)syncExperimental {
    _halfDetail.state = (_renderer.detailDivisor > 1) ? NSControlStateValueOn : NSControlStateValueOff;
    _fastMath.state = _renderer.fastMath ? NSControlStateValueOn : NSControlStateValueOff;
    _sharpUpscale.state = _renderer.sharpUpscale ? NSControlStateValueOn : NSControlStateValueOff;
    _sharpUpscale.enabled = (_renderer.detailDivisor > 1) && _renderer.sharpUpscaleAvailable;   // only means something at Half detail
    _skipSky.state = _renderer.skipEmptySky ? NSControlStateValueOn : NSControlStateValueOff;
    _edr.state = _renderer.edrOutput ? NSControlStateValueOn : NSControlStateValueOff;
    _edr.enabled = _renderer.edrAvailable || _renderer.edrOutput;
    // (MetalFX works on the ordinary picture only.)
    if (_renderer.edrOutput) _sharpUpscale.enabled = NO;
    double rate = _renderer.passesPerSecond;
    if (rate > 0) {
        double megapixels = _renderer.imageWidth * _renderer.imageHeight * 1e-6;
        _speedLabel.stringValue = [NSString stringWithFormat:@"Speed: %.1f passes/s at %.1f MP", rate, megapixels];
    } else if (_renderer.finished && ![_speedLabel.stringValue hasSuffix:@"(last run)"] && ![_speedLabel.stringValue hasPrefix:@"Speed: not"]) {
        _speedLabel.stringValue = [_speedLabel.stringValue stringByAppendingString:@"  (last run)"];
    }
}

#pragma mark - Refresh

- (void)refresh {
    GCLog(@"sidebar refresh (selected light %d)", _selectedLight + 1);
    SceneState *s = self.scene;
    [self syncShapeParams];
    for (SliderEntry *e in _entries) [e refresh];
    for (SliderEntry *e in _shapeEntries) [e refresh];
    [_vizPopup selectItemAtIndex:(NSInteger)s->cb.g_viz_mode];
    [self syncLights];
    [self showColor:LightWellColor(s, _selectedLight) inWell:_lightColor];
    _lightSpec.state = s->cb.g_light_spec_enabled[_selectedLight].x ? NSControlStateValueOn : NSControlStateValueOff;
    [self showColor:ColorFrom(s->cb.g_fog_color) inWell:_fogColor];
    _amboDirectional.state = s->cb.kLightUseDirectionalAmbo ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setSelectedLight:(int)selectedLight {
    GCLog(@"select light %d (was %d)", selectedLight + 1, _selectedLight + 1);
    _selectedLight = MIN(MAX(selectedLight, 0), kNumEditableLights - 1);
    if (_renderer.mouseTarget >= 0 && _renderer.mouseTarget < MAX_LIGHTS) _renderer.mouseTarget = _selectedLight;
    [self refresh];
}

- (void)changed {
    [_renderer relight];
    [self refresh];
}

#pragma mark - Actions

- (void)vizChanged:(NSPopUpButton *)p { [_renderer setVizMode:(int)p.indexOfSelectedItem]; }

// Brings the ball and the list of lights up to date.  Cheap; called often,
// because the descriptions change as the camera moves.
- (void)syncLights {
    SceneState *s = self.scene;
    for (int i = 0; i < kNumEditableLights; i++) {
        BOOL on = LightBrightness(s, i) >= 0.002f;
        NSString *where = DescribeLightDirection(LightDirectionInView(s, i));
        NSString *title = on ? where : [where stringByAppendingString:@"  (off)"];
        if (![_lightNames[(NSUInteger)i].title isEqualToString:title]) _lightNames[(NSUInteger)i].title = title;
        _lightNames[(NSUInteger)i].contentTintColor = on ? NSColor.labelColor : NSColor.tertiaryLabelColor;
        _lightToggles[(NSUInteger)i].state = on ? NSControlStateValueOn : NSControlStateValueOff;
        _lightSwatches[(NSUInteger)i].layer.backgroundColor = LightDisplayColor(s, i).CGColor;
        _lightRows[(NSUInteger)i].layer.backgroundColor =
            (i == _selectedLight) ? [NSColor.selectedContentBackgroundColor colorWithAlphaComponent:0.35].CGColor : NSColor.clearColor.CGColor;
    }
    _selectedLightTitle.stringValue = [NSString stringWithFormat:@"Selected: %@",
        [DescribeLightDirection(LightDirectionInView(s, _selectedLight)) lowercaseString]];
    if (_ball.selectedLight != _selectedLight) _ball.selectedLight = _selectedLight;
    _ball.needsDisplay = YES;
}

- (void)lightRowClicked:(NSButton *)b { self.selectedLight = (int)b.tag; }

// Brightness is the strongest colour channel; changing it keeps the hue.
- (void)setSelectedLightBrightness:(float)v {
    f4 &c = self.scene->cb.g_light_col[_selectedLight];
    float m = LightBrightness(self.scene, _selectedLight);
    if (m < 0.002f) c = simd_make_float4(v, v, v, c.w);   // was off: comes back white
    else c = simd_make_float4(c.x * v / m, c.y * v / m, c.z * v / m, c.w);
    [self syncLights];
    [self showColor:LightWellColor(self.scene, _selectedLight) inWell:_lightColor];
}

- (void)lightToggled:(NSButton *)b {
    int i = (int)b.tag;
    GCLog(@"light %d switched %@", i + 1, b.state == NSControlStateValueOn ? @"on" : @"off");
    [self noteChange:nil];
    f4 &c = self.scene->cb.g_light_col[i];
    if (b.state == NSControlStateValueOn) {
        f4 back = _colorBeforeOff[i];
        if (MAX(back.x, MAX(back.y, back.z)) < 0.002f) back = simd_make_float4(0.6f, 0.6f, 0.6f, 1);
        c = back;
    } else {
        _colorBeforeOff[i] = c;
        c = simd_make_float4(0, 0, 0, c.w);
    }
    _selectedLight = i;
    [self changed];
}

// The colour picker sets the light's colour exactly as picked, brightness
// included.  The Brightness slider can then push it brighter than a picker can.
- (void)lightColorChanged:(NSColorWell *)w {
    if (CACurrentMediaTime() < _ignoreWellsUntil) {   // the echo of a colour the app itself just showed
        GCLog(@"light colour well: change ignored (echo)");
        return;
    }
    GCLog(@"light colour well: new colour for light %d", _selectedLight + 1);
    _colorActionCount++;
    [self noteChange:@"Light colour"];
    ColorInto(w.color, &self.scene->cb.g_light_col[_selectedLight]);
    [_renderer relight];
    // Update what depends on the colour - but not the well or the picker, which the person is using.
    [self syncLights];
    for (SliderEntry *e in _entries) {
        if ([e.name isEqualToString:@"Light brightness"]) [e refresh];
    }
}

- (void)lightSpecChanged:(NSButton *)b {
    [self noteChange:nil];
    self.scene->cb.g_light_spec_enabled[_selectedLight].x = (b.state == NSControlStateValueOn) ? 1 : 0;
    [_renderer relight];
}

- (void)fogColorChanged:(NSColorWell *)w {
    if (CACurrentMediaTime() < _ignoreWellsUntil) return;
    [self noteChange:@"Fog colour"];
    ColorInto(w.color, &self.scene->cb.g_fog_color);
    [_renderer relight];
}

- (void)amboDirectionalChanged:(NSButton *)b {
    [self noteChange:nil];
    self.scene->cb.kLightUseDirectionalAmbo = (b.state == NSControlStateValueOn) ? 1 : 0;
    [_renderer relight];
}

- (void)randomLightColor:(id)sender { [self noteChange:nil]; self.scene->RandomizeLightColor(_selectedLight); [self changed]; }
- (void)randomLightDir:(id)sender   { [self noteChange:nil]; self.scene->RandomizeLightDir(_selectedLight); [self changed]; }
- (void)randomAll:(id)sender {
    [self noteChange:nil];
    self.scene->RandomizeLights();
    [self changed];
    if (self.didRandomizeLighting) self.didRandomizeLighting();
}
- (void)randomAmbo:(id)sender       { [self noteChange:nil]; self.scene->RandomizeAmboParams(); [self changed]; }
- (void)randomSpec:(id)sender       { [self noteChange:nil]; self.scene->RandomizeSpecParams(); [self changed]; }
- (void)randomFogColor:(id)sender   { [self noteChange:nil]; self.scene->RandomizeFogColor(); [self changed]; }
- (void)randomFog:(id)sender        { [self noteChange:nil]; self.scene->RandomizeFog(); [self changed]; }

@end
