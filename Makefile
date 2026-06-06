.PHONY: build package run clean install-deps app test test-swift test-live test-url help

APP_NAME    := VideoDownloader
PROJECT_DIR := $(shell pwd)
APP_VERSION := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(PROJECT_DIR)/VideoDownloader/Resources/Info.plist 2>/dev/null || echo 0.0.0)
SOURCES     := $(wildcard $(PROJECT_DIR)/VideoDownloader/Sources/*.swift)
BACKEND     := $(PROJECT_DIR)/backend/downloader.py \
               $(PROJECT_DIR)/backend/network_sniffer.py \
               $(PROJECT_DIR)/backend/capture_proxy.py \
               $(PROJECT_DIR)/backend/self_test.py \
               $(PROJECT_DIR)/backend/live_site_test.py \
               $(PROJECT_DIR)/backend/site_tests.json
PLIST       := $(PROJECT_DIR)/VideoDownloader/Resources/Info.plist
ICON        := $(PROJECT_DIR)/VideoDownloader/Resources/AppIcon.icns
BUILD_DIR   := $(PROJECT_DIR)/build
DIST_DIR    := $(PROJECT_DIR)/dist
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
APP_EXEC    := $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
PACKAGE_BASE := $(APP_NAME)-$(APP_VERSION)-macos-arm64
PACKAGE_ZIP  := $(DIST_DIR)/$(PACKAGE_BASE).zip
VENV_DIR    := $(PROJECT_DIR)/venv
SWIFT       := /usr/bin/swift
SDK_PATH    := $(shell xcrun --show-sdk-path --sdk macosx)
TARGET      := arm64-apple-macosx14.0

# Default target
help:
	@echo "🎬  Video Downloader"
	@echo ""
	@echo "  make install-deps    Install Python + yt-dlp dependencies"
	@echo "  make build           Build the macOS .app bundle"
	@echo "  make package         Build a distributable zip + sha256"
	@echo "  make run             Build and launch the app"
	@echo "  make test            Run backend CLI tests"
	@echo "  make test-swift      Run Swift state/persistence tests"
	@echo "  make test-live       Run live website smoke tests"
	@echo "  make test-url URL=…  Run one ad-hoc live URL smoke test"
	@echo "  make clean           Remove build artifacts"
	@echo ""

# ── Dependencies ────────────────────────────────────────────

install-deps: $(VENV_DIR)/bin/python3
	@echo "✅ Dependencies ready"

$(VENV_DIR)/bin/python3:
	@echo "📦 Setting up Python virtual environment..."
	python3 -m venv $(VENV_DIR)
	@echo "📦 Installing backend dependencies..."
	@. $(VENV_DIR)/bin/activate && pip install --quiet --trusted-host pypi.org --trusted-host files.pythonhosted.org -r backend/requirements.txt certifi
	@echo "✅ Python dependencies installed"

# ── Build ───────────────────────────────────────────────────

build: $(APP_EXEC)
	@echo "✅ Build complete: $(APP_BUNDLE)"

package: build
	@echo "📦 Packaging $(PACKAGE_BASE)..."
	@mkdir -p $(DIST_DIR)
	@rm -f $(PACKAGE_ZIP) $(PACKAGE_ZIP).sha256
	@ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl $(APP_BUNDLE) $(PACKAGE_ZIP)
	@shasum -a 256 $(PACKAGE_ZIP) > $(PACKAGE_ZIP).sha256
	@echo "   Package size: $$(du -sh $(PACKAGE_ZIP) | cut -f1)"
	@echo "   Checksum: $$(cut -d ' ' -f1 $(PACKAGE_ZIP).sha256)"
	@echo "✅ Package complete: $(PACKAGE_ZIP)"

$(APP_EXEC): $(SOURCES) $(PLIST) $(ICON) $(BACKEND) Makefile | $(VENV_DIR)/bin/python3
	@echo "🔨 Building $(APP_NAME)..."
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources/backend
	@# Compile SwiftUI app
	$(SWIFT)c \
		-o $(APP_EXEC) \
		-sdk $(SDK_PATH) \
		-target $(TARGET) \
		-module-cache-path $(BUILD_DIR)/ModuleCache \
		-framework SwiftUI \
		-framework AppKit \
		-framework Foundation \
		-framework Combine \
		-framework UserNotifications \
		$(SOURCES)
	@# Bundle resources
	cp $(PLIST) $(APP_BUNDLE)/Contents/
	-cp $(PROJECT_DIR)/VideoDownloader/Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/ 2>/dev/null
	cp $(PROJECT_DIR)/backend/downloader.py $(APP_BUNDLE)/Contents/Resources/backend/
	cp $(PROJECT_DIR)/backend/network_sniffer.py $(APP_BUNDLE)/Contents/Resources/backend/
	cp $(PROJECT_DIR)/backend/capture_proxy.py $(APP_BUNDLE)/Contents/Resources/backend/
	cp $(PROJECT_DIR)/backend/self_test.py $(APP_BUNDLE)/Contents/Resources/backend/
	cp $(PROJECT_DIR)/backend/live_site_test.py $(APP_BUNDLE)/Contents/Resources/backend/
	cp $(PROJECT_DIR)/backend/site_tests.json $(APP_BUNDLE)/Contents/Resources/backend/
	@# Bundle venv (Python + yt-dlp) - use -RL to dereference symlinks
	mkdir -p $(APP_BUNDLE)/Contents/Resources/venv
	cp -RL $(VENV_DIR)/* $(APP_BUNDLE)/Contents/Resources/venv/
	@echo "   App size: $$(du -sh $(APP_BUNDLE) | cut -f1)"

# ── Run ─────────────────────────────────────────────────────

run: build
	@echo "🚀 Launching $(APP_NAME)..."
	open $(APP_BUNDLE)

# ── Test ────────────────────────────────────────────────────

test: test-swift $(VENV_DIR)/bin/python3
	@echo "🧪 Running backend tests..."
	@. $(VENV_DIR)/bin/activate && python3 backend/self_test.py
	@echo "✅ All tests passed"

test-swift:
	@echo "🧪 Running Swift state tests..."
	@mkdir -p $(BUILD_DIR)/tests
	@$(SWIFT)c \
		-o $(BUILD_DIR)/tests/QueuePersistenceSelfTest \
		-sdk $(SDK_PATH) \
		-target $(TARGET) \
		-module-cache-path $(BUILD_DIR)/ModuleCache \
		-framework AppKit \
		-framework Foundation \
		-framework Combine \
		-framework UserNotifications \
		$(PROJECT_DIR)/VideoDownloader/Sources/Models.swift \
		$(PROJECT_DIR)/VideoDownloader/Sources/ViewModel.swift \
		$(PROJECT_DIR)/tests/QueuePersistenceSelfTest.swift
	@$(BUILD_DIR)/tests/QueuePersistenceSelfTest

test-live: $(VENV_DIR)/bin/python3
	@echo "🌐 Running live website smoke tests..."
	@. $(VENV_DIR)/bin/activate && python3 backend/live_site_test.py --probe-media $(LIVE_ARGS)

test-url: $(VENV_DIR)/bin/python3
	@test -n "$(URL)" || (echo "Usage: make test-url URL=https://example.com/watch" && exit 2)
	@echo "🌐 Testing $(URL)"
	@. $(VENV_DIR)/bin/activate && python3 backend/live_site_test.py --url "$(URL)" --probe-media $(LIVE_ARGS)

# ── Clean ───────────────────────────────────────────────────

clean:
	@echo "🧹 Cleaning build artifacts..."
	rm -rf $(BUILD_DIR) $(DIST_DIR)
	@echo "✅ Clean"
