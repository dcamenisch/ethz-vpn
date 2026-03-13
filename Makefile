APP_NAME   = ETH VPN
APP_BUNDLE = $(HOME)/Applications/$(APP_NAME).app
BINARY     = ETHVPNMenuBar
PKG_PATH   = MenuBar
BUILD_DIR  = $(PKG_PATH)/.build/release
RESOURCES_DIR = $(PKG_PATH)/Sources/ETHVPNMenuBar/Resources

OPENCONNECT_BREW_PATH ?= $(shell command -v openconnect 2>/dev/null || echo /opt/homebrew/bin/openconnect)

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
	echo "Copied openconnect from $$OC_PATH"
	xattr -d com.apple.quarantine $(RESOURCES_DIR)/openconnect 2>/dev/null || true
	dylibbundler -od -b -x $(RESOURCES_DIR)/openconnect \
		-d $(RESOURCES_DIR)/lib/ \
		-p @executable_path/../Resources/lib/
	@echo "Done: $(RESOURCES_DIR)/openconnect + lib/"

build:
	swift build -c release --package-path $(PKG_PATH)

bundle: build
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	cp "$(BUILD_DIR)/$(BINARY)" "$(APP_BUNDLE)/Contents/MacOS/$(BINARY)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@# Copy bundled openconnect + dylibs from the SPM build output (SPM copies Resources/)
	@if [ -d "$(BUILD_DIR)/$(BINARY)_$(BINARY).resources/Resources" ]; then \
		cp -R "$(BUILD_DIR)/$(BINARY)_$(BINARY).resources/Resources" "$(APP_BUNDLE)/Contents/Resources/"; \
		echo "Bundled openconnect from SPM resources."; \
	elif [ -f "$(RESOURCES_DIR)/openconnect" ]; then \
		cp -R "$(RESOURCES_DIR)" "$(APP_BUNDLE)/Contents/Resources/"; \
		echo "Bundled openconnect from source Resources/."; \
	elif [ -f "$(OPENCONNECT_BREW_PATH)" ]; then \
		cp "$(OPENCONNECT_BREW_PATH)" "$(APP_BUNDLE)/Contents/Resources/openconnect"; \
		echo "Bundled openconnect from $(OPENCONNECT_BREW_PATH) (no dylibs — developer machine only)."; \
	else \
		echo "Warning: openconnect not found. App will rely on system PATH."; \
	fi

install: bundle
	@echo "Installing $(APP_NAME) to ~/Applications..."
	@echo "Done. Launch \"$(APP_NAME)\" from ~/Applications. Setup wizard will run on first launch."

dist: bundle
	mkdir -p dist
	ditto -c -k --keepParent "$(APP_BUNDLE)" "dist/ETH VPN.zip"
	@echo "Created dist/ETH VPN.zip"

uninstall:
	rm -rf "$(APP_BUNDLE)"
	sudo rm -f /etc/sudoers.d/eth-vpn
	@echo "Uninstalled."

clean:
	rm -rf $(PKG_PATH)/.build
