APP     = build/Trapps.app
BINARY  = build/trapps
SOURCES = $(wildcard Sources/trapps/*.swift)
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
ZIP     = build/Trapps-$(VERSION).zip
MACOS_TARGET = apple-macos13.0

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

# This machine's CommandLineTools contains an orphaned modulemap (leftover
# from an older CLT) that duplicates the SwiftBridging module and breaks all
# compilation. Mask it with a VFS overlay when present. SwiftPM is similarly
# broken (mixed llbuild), hence direct swiftc instead of swift build.
STALE_MODULEMAP = /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
OVERLAY         = build/clt-fix-overlay.yaml
OVERLAY_FLAG    = $(shell [ -f $(STALE_MODULEMAP) ] && echo "-vfsoverlay $(OVERLAY)")

.PHONY: build bundle run release notarize reset-ax clean

build: $(BINARY)

$(OVERLAY): Support/clt-fix-overlay.yaml
	mkdir -p build
	sed "s|SUPPORT_DIR|$(CURDIR)/Support|" $< > $@

$(BINARY): $(SOURCES) $(OVERLAY)
	swiftc -O $(OVERLAY_FLAG) $(SOURCES) -o $(BINARY)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/trapps
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(IDENTITY)" $(APP)

run: bundle
	open $(APP)

# --- Distribution ---
# Universal binary, hardened runtime, Developer ID signature. `make release`
# then `make notarize` produces a Gatekeeper-clean zip in build/.

build/trapps-arm64: $(SOURCES) $(OVERLAY)
	swiftc -O $(OVERLAY_FLAG) -target arm64-$(MACOS_TARGET) $(SOURCES) -o $@

build/trapps-x86_64: $(SOURCES) $(OVERLAY)
	swiftc -O $(OVERLAY_FLAG) -target x86_64-$(MACOS_TARGET) $(SOURCES) -o $@

release: build/trapps-arm64 build/trapps-x86_64
	@test -n "$(strip $(RELEASE_IDENTITY))" || { \
		echo "error: no 'Developer ID Application' identity in the keychain."; \
		echo "Notarization requires one (Apple Developer Program membership)."; \
		exit 1; }
	rm -rf $(APP) $(ZIP)
	mkdir -p $(APP)/Contents/MacOS
	lipo -create -output $(APP)/Contents/MacOS/trapps build/trapps-arm64 build/trapps-x86_64
	cp Support/Info.plist $(APP)/Contents/Info.plist
	codesign --force --options runtime --timestamp --sign "$(RELEASE_IDENTITY)" $(APP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Built $(ZIP); next: make notarize"

notarize:
	xcrun notarytool submit $(ZIP) $(NOTARY_AUTH) --wait
	xcrun stapler staple $(APP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@echo "Notarized, stapled, and re-zipped $(ZIP)"

reset-ax:
	tccutil reset Accessibility com.gregthegreek.trapps

clean:
	rm -rf .build build
