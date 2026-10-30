PROJECT_NAME ?= Pantrified
DESTINATION ?= platform=iOS Simulator,name=$(shell ./Scripts/select-simulator.sh)
ARCHIVE_PATH ?= build/$(PROJECT_NAME).xcarchive

.PHONY: generate build test test-package archive-unsigned

# The Xcode project is generated from project.yml and not tracked.
generate:
	xcodegen generate

build:
	xcodebuild -project $(PROJECT_NAME).xcodeproj -scheme $(PROJECT_NAME) -destination '$(DESTINATION)' build

test:
	xcodebuild -project $(PROJECT_NAME).xcodeproj -scheme $(PROJECT_NAME) -destination '$(DESTINATION)' test

# The package tests run on Linux and on macOS; on macOS they use Apple's Foundation.
test-package:
	swift test

# A Release build for a device with signing off, which a simulator Debug build does not compile.
archive-unsigned:
	xcodebuild archive -project $(PROJECT_NAME).xcodeproj -scheme $(PROJECT_NAME) -configuration Release \
		-destination 'generic/platform=iOS' -archivePath '$(ARCHIVE_PATH)' CODE_SIGNING_ALLOWED=NO
