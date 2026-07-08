APP     = build/Trapps.app
BINARY  = build/trapps
SOURCES = $(wildcard Sources/trapps/*.swift)
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
ZIP     = build/Trapps-$(VERSION).zip
CASK_TMPL = packaging/trapps.cask.tmpl
CASK     = build/trapps.rb
MACOS_TARGET = apple-macos13.0

# -O for release; complete concurrency checking to match the SwiftPM build and
# catch Sendable/isolation regressions before the Swift 6 language-mode switch.
SWIFT_FLAGS = -O -strict-concurrency=complete

# Bundle resources. The .icns is generated from the 1024px master; the menu
# bar glyph is the 54px art loaded as a template image and sized to 18pt at
# runtime (crisp across 1x/2x/3x, so a single high-res file suffices).
ICON_SRC = Assets/png/traps-app-icon-1024.png
ICONSET  = build/AppIcon.iconset
GLYPH    = Assets/png/traps-glyph-black-54.png

# Stage icon + glyph into an assembled bundle. Must run before codesign, which
# seals the bundle. Referenced as $(STAGE_RESOURCES) from bundle and release.
define STAGE_RESOURCES
	mkdir -p $(APP)/Contents/Resources
	cp build/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	cp $(GLYPH) $(APP)/Contents/Resources/trapps-glyph.png
endef

# Prefer a real signing identity so the Accessibility grant survives rebuilds;
# fall back to ad-hoc. Override with: make IDENTITY="Apple Development: ..."
IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Apple Development|Developer ID Application|trapps-codesign/ {print $$2; exit}')
ifeq ($(strip $(IDENTITY)),)
IDENTITY = -
endif

# Release builds must be Developer ID-signed or notarization rejects them.
RELEASE_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null \
	| awk -F'"' '/Developer ID Application/ {print $$2; exit}')

# Notarization auth: a notarytool keychain profile by default, created once with
#   xcrun notarytool store-credentials trapps-notary --key <p8> --key-id <id> --issuer <uuid>
# CI overrides this with explicit --key/--key-id/--issuer flags.
NOTARY_AUTH ?= --keychain-profile trapps-notary

.PHONY: build bundle run release notarize cask reset-ax clean

build: $(BINARY)

$(BINARY): $(SOURCES)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) $(SOURCES) -o $(BINARY)

# App icon: build a full .iconset from the 1024px master and pack it into .icns.
build/AppIcon.icns: $(ICON_SRC)
	rm -rf $(ICONSET)
	mkdir -p $(ICONSET)
	sips -z 16 16     $(ICON_SRC) --out $(ICONSET)/icon_16x16.png >/dev/null
	sips -z 32 32     $(ICON_SRC) --out $(ICONSET)/icon_16x16@2x.png >/dev/null
	sips -z 32 32     $(ICON_SRC) --out $(ICONSET)/icon_32x32.png >/dev/null
	sips -z 64 64     $(ICON_SRC) --out $(ICONSET)/icon_32x32@2x.png >/dev/null
	sips -z 128 128   $(ICON_SRC) --out $(ICONSET)/icon_128x128.png >/dev/null
	sips -z 256 256   $(ICON_SRC) --out $(ICONSET)/icon_128x128@2x.png >/dev/null
	sips -z 256 256   $(ICON_SRC) --out $(ICONSET)/icon_256x256.png >/dev/null
	sips -z 512 512   $(ICON_SRC) --out $(ICONSET)/icon_256x256@2x.png >/dev/null
	sips -z 512 512   $(ICON_SRC) --out $(ICONSET)/icon_512x512.png >/dev/null
	cp $(ICON_SRC)    $(ICONSET)/icon_512x512@2x.png
	iconutil -c icns $(ICONSET) -o $@

bundle: build build/AppIcon.icns
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/trapps
	cp Support/Info.plist $(APP)/Contents/Info.plist
	$(STAGE_RESOURCES)
	codesign --force --sign "$(IDENTITY)" $(APP)

run: bundle
	open $(APP)

# --- Distribution ---
# Universal binary, hardened runtime, Developer ID signature. `make release`
# then `make notarize` produces a Gatekeeper-clean zip in build/.

build/trapps-arm64: $(SOURCES)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) -target arm64-$(MACOS_TARGET) $(SOURCES) -o $@

build/trapps-x86_64: $(SOURCES)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) -target x86_64-$(MACOS_TARGET) $(SOURCES) -o $@

release: build/trapps-arm64 build/trapps-x86_64 build/AppIcon.icns
	@test -n "$(strip $(RELEASE_IDENTITY))" || { \
		echo "error: no 'Developer ID Application' identity in the keychain."; \
		echo "Notarization requires one (Apple Developer Program membership)."; \
		exit 1; }
	rm -rf $(APP) $(ZIP)
	mkdir -p $(APP)/Contents/MacOS
	lipo -create -output $(APP)/Contents/MacOS/trapps build/trapps-arm64 build/trapps-x86_64
	cp Support/Info.plist $(APP)/Contents/Info.plist
	$(STAGE_RESOURCES)
	codesign --force --options runtime --timestamp --sign "$(RELEASE_IDENTITY)" $(APP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Built $(ZIP); next: make notarize"

notarize:
	xcrun notarytool submit $(ZIP) $(NOTARY_AUTH) --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Notarized, stapled, and re-zipped $(ZIP)"

# Render the Homebrew cask from the template, filling in the current version and
# the sha256 of the built zip. Run after `make release && make notarize`; the
# resulting build/trapps.rb goes into the homebrew-tap repo. See packaging/README.md.
cask: $(CASK_TMPL)
	@test -f $(ZIP) || { echo "error: $(ZIP) not found - run 'make release && make notarize' first."; exit 1; }
	@sha=$$(shasum -a 256 $(ZIP) | awk '{print $$1}'); \
	sed -e 's/@@VERSION@@/$(VERSION)/' -e "s/@@SHA256@@/$$sha/" $(CASK_TMPL) > $(CASK); \
	echo "Rendered $(CASK) (version $(VERSION), sha256 $$sha)"

reset-ax:
	tccutil reset Accessibility com.gregthegreek.trapps

clean:
	rm -rf .build build
