# Builds with Command Line Tools only (no Xcode). See docs/design.md#distribution.
CLT ?= $(shell xcode-select -p)
APP_NAME := Tokenjar
INSTALL_DIR ?= $(HOME)/Applications
SCRATCH ?= .build
# Extra flags for the release build. Homebrew passes --disable-sandbox (SwiftPM's sandbox cannot nest in
# Homebrew's) and --manifest-cache local (keeps the build out of ~/Library/Caches).
SWIFT_FLAGS ?=

# SwiftPM's default build system stamps the deployment target as the SDK version, which makes macOS run
# the app in compatibility mode. Stamp the real SDK generation instead.
LINK_SDK := -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 26.0

# Swift Testing ships its macro plugin and framework outside the default search paths under CLT.
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(CLT)/usr/lib/swift/host/plugins/testing \
	-Xswiftc -F -Xswiftc $(CLT)/Library/Developer/Frameworks \
	-Xlinker -F -Xlinker $(CLT)/Library/Developer/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT)/Library/Developer/Frameworks

.PHONY: build release test app install run clean

build:
	swift build --scratch-path $(SCRATCH)

release:
	swift build -c release --scratch-path $(SCRATCH) $(SWIFT_FLAGS) $(LINK_SDK)

test:
	swift test --scratch-path $(SCRATCH) $(TEST_FLAGS)

app: release
	SCRATCH=$(SCRATCH) ./Scripts/bundle.sh

# Cleared so that a TOKENJAR_APP exported in the shell cannot replace this build with another app.
install: app
	TOKENJAR_APP= ./Scripts/install.sh "$(INSTALL_DIR)"

run: app
	open build/$(APP_NAME).app

clean:
	rm -rf $(SCRATCH) build
