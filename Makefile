APP_NAME   = ETHZ VPN
APP_BUNDLE = $(HOME)/Applications/$(APP_NAME).app
BINARY     = ETHZVPNMenuBar
PKG_PATH   = MenuBar
BUILD_DIR  = $(PKG_PATH)/.build/release
RESOURCES_DIR = $(PKG_PATH)/Sources/ETHZVPNMenuBar/Resources

.PHONY: build bundle install uninstall clean fetch-openconnect dist

fetch-openconnect:
	@echo "Bundling openconnect from Homebrew installation..."
	which dylibbundler >/dev/null || (echo "Run: brew install dylibbundler" && exit 1)
	@# Require openconnect to be installed (not just fetched) so dylib paths are real
	@OC_PATH=$$(brew --prefix openconnect 2>/dev/null)/bin/openconnect; \
	if [ ! -f "$$OC_PATH" ]; then echo "Run: brew install openconnect" && exit 1; fi; \
	mkdir -p $(RESOURCES_DIR)/lib; \
	cp "$$OC_PATH" $(RESOURCES_DIR)/openconnect; \
	chmod 755 $(RESOURCES_DIR)/openconnect; \
	echo "Copied openconnect from $$OC_PATH"; \
	VPNC=$$(brew --prefix)/etc/vpnc/vpnc-script; \
	if [ ! -f "$$VPNC" ]; then echo "Run: brew install vpnc-script" && exit 1; fi; \
	cp "$$VPNC" $(RESOURCES_DIR)/vpnc-script; \
	chmod 755 $(RESOURCES_DIR)/vpnc-script
	xattr -d com.apple.quarantine $(RESOURCES_DIR)/openconnect 2>/dev/null || true
	dylibbundler -od -b -x $(RESOURCES_DIR)/openconnect \
		-d $(RESOURCES_DIR)/lib/ \
		-p @executable_path/../Resources/lib/
	@echo "Done: $(RESOURCES_DIR)/openconnect + lib/ + vpnc-script"

build:
	swift build -c release --package-path $(PKG_PATH)

bundle: build
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	cp -R "$(RESOURCES_DIR)/." "$(APP_BUNDLE)/Contents/Resources/"
	rm -f "$(APP_BUNDLE)/Contents/Resources/.gitkeep"
	@[ -f "$(RESOURCES_DIR)/openconnect" ] || echo "Note: openconnect not bundled; the helper installer will use Homebrew's."

install: bundle
	@echo "Installing $(APP_NAME) to ~/Applications..."
	@echo "Done. Launch \"$(APP_NAME)\" from ~/Applications. Setup wizard will run on first launch."

dist: bundle
	mkdir -p dist
	@# Ad-hoc codesign all binaries and the app bundle
	codesign --force --deep -s - "$(APP_BUNDLE)"
	@# Create DMG
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(APP_BUNDLE)" \
		-ov -format UDZO "dist/ETHZ VPN.dmg"
	@echo "Created dist/ETHZ VPN.dmg"

uninstall:
	rm -rf "$(APP_BUNDLE)"
	sudo rm -rf /etc/sudoers.d/ethz-vpn /Library/PrivilegedHelperTools/ethz-vpn
	@echo "Uninstalled."

clean:
	rm -rf $(PKG_PATH)/.build
