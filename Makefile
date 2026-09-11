APP=build/ZoomBuddy.app

build:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp .build/release/ZoomBuddy $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	codesign -fs - $(APP)

run: build
	open $(APP)

test:
	swift test

.PHONY: build run test
