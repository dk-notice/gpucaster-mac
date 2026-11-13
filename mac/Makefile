# Builds Gpucaster.app using only Apple's Command Line Tools (no Xcode needed).
#
#   make        build the app into build/Gpucaster.app
#   make run    build, then open the app
#   make test   build, then render test scenes off-screen into build/selftest/
#   make dist   build, then zip the app as build/Gpucaster-<version>.zip
#   make icon   re-create Gpucaster.icns by rendering a fractal with the app
#   make clean  delete the build folder
#
# The built app is self-contained: it carries a copy of the shaders folder.
# When run from here, it uses the shaders folder beside it instead, so the
# originals can be edited.

VERSION := 1.3

APP := build/Gpucaster.app
BIN := $(APP)/Contents/MacOS/Gpucaster
RES := $(APP)/Contents/Resources
SRC := src/main.mm src/Renderer.mm src/Sidebar.mm src/LightControls.mm src/SceneState.cpp
HDR := src/Renderer.h src/Sidebar.h src/LightControls.h src/SceneState.h shaders/shared_types.h

CXXFLAGS   := -std=c++17 -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=15.0
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit \
              -framework QuartzCore -framework ImageIO -framework CoreGraphics \
              -framework UniformTypeIdentifiers -framework MetalFX

all: bundle

$(BIN): $(SRC) $(HDR)
	mkdir -p $(APP)/Contents/MacOS
	clang++ $(CXXFLAGS) $(SRC) $(FRAMEWORKS) -o $(BIN)

# Everything in the app besides the program itself, then the signature.
# (Signing is "ad hoc": enough to run on this Mac.  The attributes that the
# Documents folder's file syncing adds have to be stripped first.)
bundle: $(BIN)
	mkdir -p $(RES)/shaders
	cp Info.plist $(APP)/Contents/Info.plist
	cp Gpucaster.icns $(RES)/Gpucaster.icns
	rsync -a --delete shaders/ $(RES)/shaders/
	xattr -cr $(APP)
	codesign --force --sign - $(APP)

run: bundle
	open $(APP)

test: bundle
	$(BIN) --selftest build/selftest

dist: bundle
	cd build && ditto -c -k --keepParent Gpucaster.app Gpucaster-$(VERSION).zip
	@ls -lh build/Gpucaster-$(VERSION).zip

# The icon is a picture of the fractal dodecahedron, drawn by the app itself.
icon: bundle
	mkdir -p build/icon/Gpucaster.iconset
	clang -fobjc-arc tools/make_icon.m -framework Cocoa -o build/icon/make_icon
	$(BIN) --render build/icon/fractal.png --shape fractal_dodecahedron --size 1024x1024 --geometry 60 --shading 64
	build/icon/make_icon build/icon/fractal.png build/icon/icon_1024.png
	for s in 16 32 128 256 512; do \
	  sips -z $$s $$s build/icon/icon_1024.png --out build/icon/Gpucaster.iconset/icon_$${s}x$${s}.png >/dev/null; \
	  d=$$((s * 2)); \
	  sips -z $$d $$d build/icon/icon_1024.png --out build/icon/Gpucaster.iconset/icon_$${s}x$${s}@2x.png >/dev/null; \
	done
	iconutil -c icns build/icon/Gpucaster.iconset -o Gpucaster.icns

clean:
	rm -rf build

.PHONY: all bundle run test dist icon clean
