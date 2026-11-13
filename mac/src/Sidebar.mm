#import "Sidebar.h"

static const CGFloat kSidebarWidth = 300;
static const CGFloat kSideMargin = 12;
static const int kNumEditableLights = 5;   // the shaders light the scene with the first five

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
    NSStackView *_advanced;       // rarely needed controls, hidden until asked for
    NSPopUpButton *_vizPopup;
    NSPopUpButton *_mousePopup;
    NSPopUpButton *_lightPopup;
    NSColorWell *_lightColor;
    NSButton *_lightSpec;
    NSColorWell *_fogColor;
    NSButton *_amboDirectional;
}

- (instancetype)initWithRenderer:(Renderer *)renderer {
    if ((self = [super initWithFrame:NSMakeRect(0, 0, kSidebarWidth, 600)])) {
        _renderer = renderer;
        _entries = [NSMutableArray array];
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

- (void)sliderMoved:(NSSlider *)slider {
    SliderEntry *e = _entries[(NSUInteger)slider.tag];
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

    // ---- View ----
    [self addSection:@"View"];
    NSMutableArray *vizNames = [NSMutableArray array];
    for (int i = 0; i < kNumVizModes; i++) [vizNames addObject:kVizModeNames[i]];
    _vizPopup = [self addPopup:@"Show" items:vizNames action:@selector(vizChanged:)];
    _mousePopup = [self addPopup:@"Mouse moves" items:@[@"Camera", @"Selected light", @"All lights"]
                          action:@selector(mouseTargetChanged:)];
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
    NSMutableArray *lightNames = [NSMutableArray array];
    for (int i = 0; i < kNumEditableLights; i++) [lightNames addObject:[NSString stringWithFormat:@"Light %d", i + 1]];
    _lightPopup = [self addPopup:@"Selected light" items:lightNames action:@selector(lightSelected:)];
    _lightColor = [self addColorWell:@"Colour" action:@selector(lightColorChanged:)];
    [self addSlider:@"Wrap" min:0 max:1 kind:ChangeRelight
                get:^float { return weakSelf.scene->cb.g_light_wrap[weakSelf.selectedLight].x; }
                set:^(float v) { weakSelf.scene->cb.g_light_wrap[weakSelf.selectedLight].x = v; }];
    _lightSpec = [self addCheckbox:@"Adds a shiny highlight" action:@selector(lightSpecChanged:)];
    [self addButtons:@[
        [self button:@"Random colour" action:@selector(randomLightColor:)],
        [self button:@"Random direction" action:@selector(randomLightDir:)],
    ]];
    [self addButtons:@[[self button:@"Randomize all lighting" action:@selector(randomAll:)]]];

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
    NSView *previous = _stack.arrangedSubviews.lastObject;
    if (previous) [_stack setCustomSpacing:16 afterView:previous];
    NSButton *toggle = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleAdvanced:)];
    toggle.bezelStyle = NSBezelStyleDisclosure;
    [toggle setButtonType:NSButtonTypePushOnPushOff];
    NSStackView *header = [NSStackView stackViewWithViews:@[toggle, [self label:@"Advanced" bold:YES]]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.spacing = 4;
    [_stack addArrangedSubview:header];

    _advanced = [self verticalStack];
    [self addRow:_advanced];
    _target = _advanced;
    [self addNote:@"Where shiny highlights fade in, by ambient level:"];
    [self addSlider:@"Highlights from" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboSpecLo)];
    [self addSlider:@"Highlights to" min:0 max:1 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboSpecHi)];
    [self addNote:@"Directional shadowing:"];
    [self addSlider:@"Shadow scale" min:0 max:8 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDirScale)];
    [self addSlider:@"Shadow bias" min:-2 max:2 kind:ChangeRelight SCENE_VALUE(cb.kLightAmboDirBias)];
    _target = _stack;
    _advanced.hidden = YES;
    #undef SCENE_VALUE
}

- (void)toggleAdvanced:(NSButton *)b {
    _advanced.hidden = (b.state != NSControlStateValueOn);
}

#pragma mark - Refresh

- (void)refresh {
    SceneState *s = self.scene;
    for (SliderEntry *e in _entries) [e refresh];
    [_vizPopup selectItemAtIndex:(NSInteger)s->cb.g_viz_mode];
    [_lightPopup selectItemAtIndex:_selectedLight];
    int target = _renderer.mouseTarget;
    [_mousePopup selectItemAtIndex:(target == -1) ? 0 : (target == 9) ? 2 : 1];
    _lightColor.color = ColorFrom(s->cb.g_light_col[_selectedLight]);
    _lightSpec.state = s->cb.g_light_spec_enabled[_selectedLight].x ? NSControlStateValueOn : NSControlStateValueOff;
    _fogColor.color = ColorFrom(s->cb.g_fog_color);
    _amboDirectional.state = s->cb.kLightUseDirectionalAmbo ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)setSelectedLight:(int)selectedLight {
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

- (void)mouseTargetChanged:(NSPopUpButton *)p {
    NSInteger i = p.indexOfSelectedItem;
    _renderer.mouseTarget = (i == 0) ? -1 : (i == 2) ? 9 : _selectedLight;
}

- (void)lightSelected:(NSPopUpButton *)p { self.selectedLight = (int)p.indexOfSelectedItem; }

- (void)lightColorChanged:(NSColorWell *)w {
    [self noteChange:@"Light colour"];
    ColorInto(w.color, &self.scene->cb.g_light_col[_selectedLight]);
    [_renderer relight];
}

- (void)lightSpecChanged:(NSButton *)b {
    [self noteChange:nil];
    self.scene->cb.g_light_spec_enabled[_selectedLight].x = (b.state == NSControlStateValueOn) ? 1 : 0;
    [_renderer relight];
}

- (void)fogColorChanged:(NSColorWell *)w {
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
