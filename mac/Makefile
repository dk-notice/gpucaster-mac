# Builds Gpucaster.app using only Apple's Command Line Tools (no Xcode needed).
#
#   make        build the app into build/Gpucaster.app
#   make run    build, then open the app
#   make test   build, then render one frame off-screen to build/selftest.png
#   make clean  delete the build folder

APP := build/Gpucaster.app
BIN := $(APP)/Contents/MacOS/Gpucaster
SRC := src/main.mm src/Renderer.mm
HDR := src/Renderer.h

CXXFLAGS   := -std=c++17 -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=13.0
FRAMEWORKS := -framework Cocoa -framework Metal -framework MetalKit \
              -framework QuartzCore -framework ImageIO -framework CoreGraphics

all: $(BIN)

$(BIN): $(SRC) $(HDR) Info.plist
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	clang++ $(CXXFLAGS) $(SRC) $(FRAMEWORKS) -o $(BIN)
	xattr -cr $(APP)
	codesign --force --sign - $(APP)

run: all
	open $(APP)

test: all
	$(BIN) --selftest build/selftest.png

clean:
	rm -rf build

.PHONY: all run test clean
