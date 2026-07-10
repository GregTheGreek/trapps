APP     = build/Trapps.app
BINARY  = build/trapps
SOURCES = $(wildcard Sources/trapps/*.swift)
VERSION = $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)
DMG     = build/Trapps-$(VERSION).dmg
DMG_STAGING = build/dmg
VOLNAME = Trapps
CASK_TMPL = packaging/trapps.cask.tmpl
CASK     = build/trapps.rb
MACOS_TARGET = apple-macos13.0

# --- Sparkle auto-update ---
# Pinned + checksummed so the vendored binary can't drift. `make sparkle` (a
# prerequisite of every compile) fetches it into gitignored third_party/.
SPARKLE_VERSION = 2.9.4
SPARKLE_SHA256  = ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9
SPARKLE_DIR = third_party/Sparkle
SPARKLE_FW  = $(SPARKLE_DIR)/Sparkle.framework
SPARKLE_BIN = $(SPARKLE_DIR)/bin
SPARKLE_URL = https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz

# Appcast feed lives on a pinned, never-re-tagged GitHub release; enclosures
# point at each version's own release. SUFeedURL in Info.plist must match APPCAST_URL.
APPCAST_TAG = appcast
APPCAST_URL = https://github.com/GregTheGreek/trapps/releases/download/$(APPCAST_TAG)/appcast.xml
RELEASE_URL_PREFIX = https://github.com/GregTheGreek/trapps/releases/download/v$(VERSION)/

# -O for release; complete concurrency checking to match the SwiftPM build and
# catch Sendable/isolation regressions before the Swift 6 language-mode switch.
SWIFT_FLAGS = -O -strict-concurrency=complete

# Link Sparkle and bake the rpath so the embedded framework resolves at runtime
# (@rpath/Sparkle.framework -> Contents/Frameworks). `canImport(Sparkle)` in the
# Swift sources keys off this search path; the SwiftPM/test build omits it.
SPARKLE_FLAGS = -F $(SPARKLE_DIR) -framework Sparkle \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks

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

# Copy the vendored Sparkle.framework into the bundle before signing so the app's
# seal covers it. ditto preserves the framework's Versions/symlink layout.
define EMBED_SPARKLE
	mkdir -p $(APP)/Contents/Frameworks
	rm -rf $(APP)/Contents/Frameworks/Sparkle.framework
	ditto $(SPARKLE_FW) $(APP)/Contents/Frameworks/Sparkle.framework
endef

# Re-sign Sparkle's nested code inside-out with our identity (it ships ad-hoc
# signed). Must run after EMBED_SPARKLE and before the app is sealed.
# $(1) = signing identity, $(2) = extra flags (e.g. --options runtime --timestamp).
define SIGN_SPARKLE
	fw="$(APP)/Contents/Frameworks/Sparkle.framework/Versions/B"; \
	codesign --force $(2) --sign "$(1)" "$$fw/XPCServices/Downloader.xpc"; \
	codesign --force $(2) --sign "$(1)" "$$fw/XPCServices/Installer.xpc"; \
	codesign --force $(2) --sign "$(1)" "$$fw/Autoupdate"; \
	codesign --force $(2) --sign "$(1)" "$$fw/Updater.app"; \
	codesign --force $(2) --sign "$(1)" "$(APP)/Contents/Frameworks/Sparkle.framework"
endef

# Pack the signed .app into a compressed, read-only .dmg with a drag-to-Applications
# shortcut. ditto (not cp) preserves the code signature. Removes any prior staging
# dir and dmg first so nothing stale leaks in.
define MAKE_DMG
	rm -rf $(DMG_STAGING) "$(DMG)"
	mkdir -p $(DMG_STAGING)
	ditto $(APP) "$(DMG_STAGING)/Trapps.app"
	ln -s /Applications "$(DMG_STAGING)/Applications"
	hdiutil create -volname "$(VOLNAME)" -srcfolder $(DMG_STAGING) -ov -format UDZO "$(DMG)"
	rm -rf $(DMG_STAGING)
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

.PHONY: build bundle run release notarize cask sparkle sparkle-keys appcast reset-ax clean

build: $(BINARY)

# Fetch, verify, and unpack the vendored Sparkle framework + tools on demand.
sparkle: $(SPARKLE_FW)
$(SPARKLE_FW):
	@mkdir -p $(SPARKLE_DIR) build
	@echo "Fetching Sparkle $(SPARKLE_VERSION)…"
	@curl -fsSL -o build/sparkle.tar.xz "$(SPARKLE_URL)"
	@echo "$(SPARKLE_SHA256)  build/sparkle.tar.xz" | shasum -a 256 -c - \
		|| { echo "error: Sparkle checksum mismatch"; rm -f build/sparkle.tar.xz; exit 1; }
	@tar -xJf build/sparkle.tar.xz -C $(SPARKLE_DIR) ./Sparkle.framework ./bin
	@chmod +x $(SPARKLE_BIN)/* 2>/dev/null || true
	@rm -f build/sparkle.tar.xz
	@echo "Sparkle $(SPARKLE_VERSION) vendored in $(SPARKLE_DIR)"

$(BINARY): $(SOURCES) $(SPARKLE_FW)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) $(SPARKLE_FLAGS) $(SOURCES) -o $(BINARY)

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
	$(EMBED_SPARKLE)
	$(call SIGN_SPARKLE,$(IDENTITY),)
	codesign --force --sign "$(IDENTITY)" $(APP)

run: bundle
	open $(APP)

# --- Distribution ---
# Universal binary, hardened runtime, Developer ID signature. `make release`
# then `make notarize` produces a Gatekeeper-clean dmg in build/.

build/trapps-arm64: $(SOURCES) $(SPARKLE_FW)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) $(SPARKLE_FLAGS) -target arm64-$(MACOS_TARGET) $(SOURCES) -o $@

build/trapps-x86_64: $(SOURCES) $(SPARKLE_FW)
	mkdir -p build
	swiftc $(SWIFT_FLAGS) $(SPARKLE_FLAGS) -target x86_64-$(MACOS_TARGET) $(SOURCES) -o $@

release: build/trapps-arm64 build/trapps-x86_64 build/AppIcon.icns
	@test -n "$(strip $(RELEASE_IDENTITY))" || { \
		echo "error: no 'Developer ID Application' identity in the keychain."; \
		echo "Notarization requires one (Apple Developer Program membership)."; \
		exit 1; }
	rm -rf $(APP)
	rm -f build/Trapps-*.zip build/Trapps-*.dmg
	mkdir -p $(APP)/Contents/MacOS
	lipo -create -output $(APP)/Contents/MacOS/trapps build/trapps-arm64 build/trapps-x86_64
	cp Support/Info.plist $(APP)/Contents/Info.plist
	$(STAGE_RESOURCES)
	$(EMBED_SPARKLE)
	$(call SIGN_SPARKLE,$(RELEASE_IDENTITY),--options runtime --timestamp)
	codesign --force --options runtime --timestamp --sign "$(RELEASE_IDENTITY)" $(APP)
	$(MAKE_DMG)
	@echo "Built $(DMG); next: make notarize"

# A downloaded .dmg needs its own notarization ticket, and the app inside needs
# one too for offline first launch - so we notarize twice: first the app (staple
# it for offline Gatekeeper), then rebuild the dmg around the stapled app and
# notarize + staple the dmg itself.
notarize:
	ditto -c -k --keepParent $(APP) build/notarize.zip
	xcrun notarytool submit build/notarize.zip $(NOTARY_AUTH) --wait
	rm -f build/notarize.zip
	xcrun stapler staple $(APP)
	$(MAKE_DMG)
	xcrun notarytool submit $(DMG) $(NOTARY_AUTH) --wait
	xcrun stapler staple $(DMG)
	@echo "Notarized + stapled app and dmg: $(DMG)"

# Render the Homebrew cask from the template, filling in the current version and
# the sha256 of the built dmg. Run after `make release && make notarize`; the
# resulting build/trapps.rb goes into the homebrew-tap repo. See packaging/README.md.
cask: $(CASK_TMPL)
	@test -f $(DMG) || { echo "error: $(DMG) not found - run 'make release && make notarize' first."; exit 1; }
	@sha=$$(shasum -a 256 $(DMG) | awk '{print $$1}'); \
	sed -e 's/@@VERSION@@/$(VERSION)/' -e "s/@@SHA256@@/$$sha/" $(CASK_TMPL) > $(CASK); \
	echo "Rendered $(CASK) (version $(VERSION), sha256 $$sha)"

# One-time: create (or show) the EdDSA signing key in your login Keychain and
# print the SUPublicEDKey to paste into Support/Info.plist. Idempotent - re-running
# reuses the existing key. The private half never leaves the Keychain.
sparkle-keys: $(SPARKLE_FW)
	@$(SPARKLE_BIN)/generate_keys

# Regenerate the appcast for the current version. Pulls the existing feed from the
# pinned '$(APPCAST_TAG)' release, appends this version (enclosure -> this version's
# release dmg), signs everything with your Keychain EdDSA key, and writes
# build/appcast.xml. Run after `make release && make notarize`, then publish with:
#   gh release upload $(APPCAST_TAG) build/appcast.xml --clobber
appcast: $(SPARKLE_FW)
	@test -f $(DMG) || { echo "error: $(DMG) not found - run 'make release && make notarize' first."; exit 1; }
	@rm -rf build/appcast && mkdir -p build/appcast
	@cp $(DMG) build/appcast/
	@curl -fsSL -o build/appcast/appcast.xml "$(APPCAST_URL)" \
		&& echo "merged existing feed" || echo "no existing feed - starting fresh"
	$(SPARKLE_BIN)/generate_appcast \
		--download-url-prefix "$(RELEASE_URL_PREFIX)" \
		--link "https://github.com/GregTheGreek/trapps" \
		build/appcast
	@cp build/appcast/appcast.xml build/appcast.xml
	@echo "Wrote build/appcast.xml; publish: gh release upload $(APPCAST_TAG) build/appcast.xml --clobber"

reset-ax:
	tccutil reset Accessibility com.gregthegreek.trapps

clean:
	rm -rf .build build
