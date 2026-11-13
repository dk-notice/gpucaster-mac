#import "Sidebar.h"

static const CGFloat kSidebarWidth = 300;
static const int kNumEditableLights = 5;   // the shaders light the scene with the first five

// A view whose origin is at the top-left, so scrolled content starts at the top.
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

typedef float (^FloatGetter)(void);
typedef void (^FloatSetter)(float);

@implementation Sidebar {
    Renderer *_renderer;
    NSStackView *_stack;
    NSMutableArray<void (^)(void)> *_refreshers;   // one per control: copies the scene's value into it
    NSMutableArray<FloatSetter> *_sliderSetters;   // indexed by slider tag
    NSMutableArray<NSTextField *> *_sliderValueLabels;
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
        _refreshers = [NSMutableArray array];
        _sliderSetters = [NSMutableArray array];
        _sliderValueLabels = [NSMutableArray array];
        [self build];
        [self refresh];
    }
    return self;
}

- (SceneState *)scene { return _renderer.scene; }

#pragma mark - Building blocks

- (NSTextField *)label:(NSString *)text bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = bold ? [NSFont boldSystemFontOfSize:12] : [NSFont systemFontOfSize:11];
    l.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    return l;
}

- (void)addSection:(NSString *)title {
    NSView *previous = _stack.arrangedSubviews.lastObject;
    if (previous) [_stack setCustomSpacing:16 afterView:previous];
    [_stack addArrangedSubview:[self label:title bold:YES]];
}

- (NSStackView *)rowWithTitle:(NSString *)title control:(NSView *)control {
    NSTextField *l = [self label:title bold:NO];
    [l.widthAnchor constraintEqualToConstant:104].active = YES;
    NSStackView *row = [NSStackView stackViewWithViews:@[l, control]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.spacing = 6;
    [_stack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor constant:-24].active = YES;   // minus the side margins
    return row;
}

- (void)addSlider:(NSString *)title min:(float)min max:(float)max get:(FloatGetter)get set:(FloatSetter)set {
    NSSlider *slider = [NSSlider sliderWithValue:min minValue:min maxValue:max target:self action:@selector(sliderMoved:)];
    slider.continuous = YES;
    slider.controlSize = NSControlSizeSmall;
    slider.tag = (NSInteger)_sliderSetters.count;
    [_sliderSetters addObject:[set copy]];

    NSTextField *value = [self label:@"0.00" bold:NO];
    value.alignment = NSTextAlignmentRight;
    value.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    [value.widthAnchor constraintEqualToConstant:34].active = YES;
    [_sliderValueLabels addObject:value];

    NSStackView *row = [self rowWithTitle:title control:slider];
    [row addArrangedSubview:value];

    [_refreshers addObject:[^{
        float v = get();
        slider.floatValue = v;
        value.stringValue = [NSString stringWithFormat:@"%.2f", v];
    } copy]];
}

- (void)sliderMoved:(NSSlider *)slider {
    _sliderSetters[(NSUInteger)slider.tag](slider.floatValue);
    _sliderValueLabels[(NSUInteger)slider.tag].stringValue = [NSString stringWithFormat:@"%.2f", slider.floatValue];
    [_renderer relight];
}

- (NSButton *)addCheckbox:(NSString *)title action:(SEL)action {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:action];
    b.controlSize = NSControlSizeSmall;
    b.font = [NSFont systemFontOfSize:11];
    [_stack addArrangedSubview:b];
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
    [_stack addArrangedSubview:row];
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
    _stack = [NSStackView new];
    _stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    _stack.alignment = NSLayoutAttributeLeading;
    _stack.spacing = 5;
    _stack.edgeInsets = NSEdgeInsetsMake(12, 12, 16, 12);
    _stack.translatesAutoresizingMaskIntoConstraints = NO;

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
    #define SCENE_VALUE(expr) \
        get:^float { return weakSelf.scene->expr; } set:^(float v) { weakSelf.scene->expr = v; }

    // ---- View ----
    [self addSection:@"View"];
    NSMutableArray *vizNames = [NSMutableArray array];
    for (int i = 0; i < kNumVizModes; i++) [vizNames addObject:kVizModeNames[i]];
    _vizPopup = [self addPopup:@"Show" items:vizNames action:@selector(vizChanged:)];
    _mousePopup = [self addPopup:@"Mouse moves" items:@[@"Camera", @"Selected light", @"All lights"]
                          action:@selector(mouseTargetChanged:)];
    [self addSlider:@"Brightness" min:0 max:5 SCENE_VALUE(cb.kLightScale)];
    [self addSlider:@"Saturation" min:0 max:4 SCENE_VALUE(cb.kLightSat)];

    // ---- Lights ----
    [self addSection:@"Lights"];
    NSMutableArray *lightNames = [NSMutableArray array];
    for (int i = 0; i < kNumEditableLights; i++) [lightNames addObject:[NSString stringWithFormat:@"Light %d", i + 1]];
    _lightPopup = [self addPopup:@"Selected light" items:lightNames action:@selector(lightSelected:)];
    _lightColor = [self addColorWell:@"Colour" action:@selector(lightColorChanged:)];
    [self addSlider:@"Wrap"
                min:0
                max:1
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
    [self addSlider:@"Dark below" min:0 max:1 SCENE_VALUE(cb.kLightAmboDiffuseUnLitThresh)];
    [self addSlider:@"Bright above" min:0 max:1 SCENE_VALUE(cb.kLightAmboDiffuseFullyLitThresh)];
    [self addSlider:@"Contrast" min:0 max:4 SCENE_VALUE(cb.kLightAmboDiffuseExponent)];
    [self addSlider:@"Highlights from" min:0 max:1 SCENE_VALUE(cb.kLightAmboSpecLo)];
    [self addSlider:@"Highlights to" min:0 max:1 SCENE_VALUE(cb.kLightAmboSpecHi)];
    _amboDirectional = [self addCheckbox:@"Directional shadowing" action:@selector(amboDirectionalChanged:)];
    [self addSlider:@"Shadow scale" min:0 max:8 SCENE_VALUE(cb.kLightAmboDirScale)];
    [self addSlider:@"Shadow bias" min:-2 max:2 SCENE_VALUE(cb.kLightAmboDirBias)];
    [self addButtons:@[[self button:@"Randomize" action:@selector(randomAmbo:)]]];

    // ---- Shiny highlights ----
    [self addSection:@"Shiny highlights"];
    [self addSlider:@"Strength" min:0 max:1.5 SCENE_VALUE(cb.kLightSpecStr)];
    [self addSlider:@"Sharpness" min:0 max:8 SCENE_VALUE(cb.kLightSpecPow)];
    [self addButtons:@[[self button:@"Randomize" action:@selector(randomSpec:)]]];

    // ---- Fog ----
    [self addSection:@"Fog"];
    _fogColor = [self addColorWell:@"Colour" action:@selector(fogColorChanged:)];
    [self addSlider:@"Density" min:0 max:1 SCENE_VALUE(cb.g_fog_params.x)];
    [self addSlider:@"Falloff" min:0 max:4 SCENE_VALUE(cb.g_fog_params.y)];
    [self addButtons:@[
        [self button:@"Random colour" action:@selector(randomFogColor:)],
        [self button:@"Random fog" action:@selector(randomFog:)],
    ]];

    // ---- Surface ----
    [self addSection:@"Surface"];
    [self addSlider:@"Reflectivity" min:0 max:2 SCENE_VALUE(cb.kReflectivity)];
    [self addSlider:@"Surface colour" min:0 max:2 SCENE_VALUE(cb.kSurfaceColorAmount)];
    #undef SCENE_VALUE
}

#pragma mark - Refresh

- (void)refresh {
    SceneState *s = self.scene;
    for (void (^r)(void) in _refreshers) r();
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
    ColorInto(w.color, &self.scene->cb.g_light_col[_selectedLight]);
    [_renderer relight];
}

- (void)lightSpecChanged:(NSButton *)b {
    self.scene->cb.g_light_spec_enabled[_selectedLight].x = (b.state == NSControlStateValueOn) ? 1 : 0;
    [_renderer relight];
}

- (void)fogColorChanged:(NSColorWell *)w {
    ColorInto(w.color, &self.scene->cb.g_fog_color);
    [_renderer relight];
}

- (void)amboDirectionalChanged:(NSButton *)b {
    self.scene->cb.kLightUseDirectionalAmbo = (b.state == NSControlStateValueOn) ? 1 : 0;
    [_renderer relight];
}

- (void)randomLightColor:(id)sender { self.scene->RandomizeLightColor(_selectedLight); [self changed]; }
- (void)randomLightDir:(id)sender   { self.scene->RandomizeLightDir(_selectedLight); [self changed]; }
- (void)randomAll:(id)sender        { self.scene->RandomizeLights(); [self changed]; }
- (void)randomAmbo:(id)sender       { self.scene->RandomizeAmboParams(); [self changed]; }
- (void)randomSpec:(id)sender       { self.scene->RandomizeSpecParams(); [self changed]; }
- (void)randomFogColor:(id)sender   { self.scene->RandomizeFogColor(); [self changed]; }
- (void)randomFog:(id)sender        { self.scene->RandomizeFog(); [self changed]; }

@end
