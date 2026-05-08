# FHIR-HOSE Build Makefile
# Build automation for the FHIR-HOSE iOS/macOS app

# Variables
PROJECT_NAME = FHIR-HOSE
SCHEME = FHIR-HOSE
PROJECT_FILE = $(PROJECT_NAME).xcodeproj
XCODEBUILD = /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild

# Default iOS simulator device
IOS_DEVICE = "iPhone 16"
IOS_VERSION = "latest"

# macOS destination
MACOS_DESTINATION = "platform=macOS"

# Build directories
BUILD_DIR = build
ARCHIVE_DIR = archives
DERIVED_DATA_PATH = $(BUILD_DIR)/DerivedData

# Colors for output
BLUE = \033[0;34m
GREEN = \033[0;32m
YELLOW = \033[0;33m
RED = \033[0;31m
NC = \033[0m # No Color

.PHONY: help clean build-ios build-macos test archive-ios archive-macos install-ios install-macos run-ios run-macos debug release list-devices list-simulators

# Default target
all: help

help:
	@echo "$(BLUE)FHIR-HOSE Build Commands$(NC)"
	@echo ""
	@echo "$(GREEN)Build Commands:$(NC)"
	@echo "  make build-ios        - Build for iOS Simulator"
	@echo "  make build-macos      - Build for macOS"
	@echo "  make build-all        - Build for all platforms"
	@echo ""
	@echo "$(GREEN)Test Commands:$(NC)"
	@echo "  make test-ios         - Run tests on iOS Simulator"
	@echo "  make test-macos       - Run tests on macOS"
	@echo "  make test-all         - Run tests on all platforms"
	@echo ""
	@echo "$(GREEN)Archive Commands:$(NC)"
	@echo "  make archive-ios      - Create iOS archive"
	@echo "  make archive-macos    - Create macOS archive"
	@echo ""
	@echo "$(GREEN)Run Commands:$(NC)"
	@echo "  make run-ios          - Build and run on iOS Simulator"
	@echo "  make run-macos        - Build and run on macOS"
	@echo ""
	@echo "$(GREEN)Utility Commands:$(NC)"
	@echo "  make clean            - Clean build artifacts"
	@echo "  make list-devices     - List available devices"
	@echo "  make list-simulators  - List available simulators"
	@echo "  make debug            - Build debug configuration"
	@echo "  make release          - Build release configuration"
	@echo ""
	@echo "$(YELLOW)Environment Variables:$(NC)"
	@echo "  IOS_DEVICE=$(IOS_DEVICE)"
	@echo "  Configuration: Debug (default), Release"

# Clean build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	rm -rf $(BUILD_DIR)
	rm -rf $(ARCHIVE_DIR)
	$(XCODEBUILD) clean -project $(PROJECT_FILE) -scheme $(SCHEME)
	@echo "$(GREEN)Clean completed$(NC)"

# Build for iOS Simulator
build-ios:
	@echo "$(BLUE)Building $(PROJECT_NAME) for iOS Simulator...$(NC)"
	$(XCODEBUILD) build \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.5' \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		-configuration Debug
	@echo "$(GREEN)iOS build completed$(NC)"

# Build for macOS
build-macos:
	@echo "$(BLUE)Building $(PROJECT_NAME) for macOS...$(NC)"
	$(XCODEBUILD) build \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination $(MACOS_DESTINATION) \
		-derivedDataPath $(DERIVED_DATA_PATH) \
		-configuration Debug
	@echo "$(GREEN)macOS build completed$(NC)"

# Build for all platforms
build-all: build-ios build-macos

# Run tests on iOS
test-ios:
	@echo "$(BLUE)Running tests on iOS Simulator...$(NC)"
	$(XCODEBUILD) test \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(IOS_DEVICE)" \
		-derivedDataPath $(DERIVED_DATA_PATH)
	@echo "$(GREEN)iOS tests completed$(NC)"

# Run tests on macOS
test-macos:
	@echo "$(BLUE)Running tests on macOS...$(NC)"
	$(XCODEBUILD) test \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination $(MACOS_DESTINATION) \
		-derivedDataPath $(DERIVED_DATA_PATH)
	@echo "$(GREEN)macOS tests completed$(NC)"

# Run tests on all platforms
test-all: test-ios test-macos

# Create iOS archive
archive-ios:
	@echo "$(BLUE)Creating iOS archive...$(NC)"
	@mkdir -p $(ARCHIVE_DIR)
	$(XCODEBUILD) archive \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-archivePath $(ARCHIVE_DIR)/$(PROJECT_NAME)-iOS.xcarchive \
		-configuration Release
	@echo "$(GREEN)iOS archive created: $(ARCHIVE_DIR)/$(PROJECT_NAME)-iOS.xcarchive$(NC)"

# Create macOS archive
archive-macos:
	@echo "$(BLUE)Creating macOS archive...$(NC)"
	@mkdir -p $(ARCHIVE_DIR)
	$(XCODEBUILD) archive \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination $(MACOS_DESTINATION) \
		-archivePath $(ARCHIVE_DIR)/$(PROJECT_NAME)-macOS.xcarchive \
		-configuration Release
	@echo "$(GREEN)macOS archive created: $(ARCHIVE_DIR)/$(PROJECT_NAME)-macOS.xcarchive$(NC)"

# Build and run on iOS Simulator
run-ios: build-ios
	@echo "$(BLUE)Launching $(PROJECT_NAME) on iOS Simulator...$(NC)"
	$(XCODEBUILD) test-without-building \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(IOS_DEVICE)" \
		-derivedDataPath $(DERIVED_DATA_PATH) || true
	@echo "$(YELLOW)Note: Use Xcode or Simulator.app to actually launch the app$(NC)"

# Build and run on macOS
run-macos: build-macos
	@echo "$(BLUE)Finding and launching $(PROJECT_NAME) on macOS...$(NC)"
	@APP_PATH=$$(find $(DERIVED_DATA_PATH) -name "$(PROJECT_NAME).app" -path "*/Build/Products/Debug/*" | head -1); \
	if [ -n "$$APP_PATH" ]; then \
		echo "$(GREEN)Launching: $$APP_PATH$(NC)"; \
		open "$$APP_PATH"; \
	else \
		echo "$(RED)Could not find built app$(NC)"; \
		exit 1; \
	fi

# Debug build (default)
debug:
	@echo "$(BLUE)Building Debug configuration...$(NC)"
	$(MAKE) build-all

# Release build
release:
	@echo "$(BLUE)Building Release configuration...$(NC)"
	$(XCODEBUILD) build \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination "platform=iOS Simulator,name=$(IOS_DEVICE)" \
		-configuration Release
	$(XCODEBUILD) build \
		-project $(PROJECT_FILE) \
		-scheme $(SCHEME) \
		-destination $(MACOS_DESTINATION) \
		-configuration Release
	@echo "$(GREEN)Release build completed$(NC)"

# List available devices
list-devices:
	@echo "$(BLUE)Available devices and simulators:$(NC)"
	$(XCODEBUILD) -showdestinations -project $(PROJECT_FILE) -scheme $(SCHEME)

# List iOS simulators
list-simulators:
	@echo "$(BLUE)Available iOS Simulators:$(NC)"
	xcrun simctl list devices available | grep -E "iPhone|iPad"

# Development convenience targets
dev-setup: clean build-ios
	@echo "$(GREEN)Development environment ready$(NC)"

quick-test: build-ios test-ios
	@echo "$(GREEN)Quick test cycle completed$(NC)"

# Export IPA (requires archive)
export-ipa: archive-ios
	@echo "$(BLUE)Exporting IPA...$(NC)"
	@mkdir -p $(BUILD_DIR)/export
	$(XCODEBUILD) -exportArchive \
		-archivePath $(ARCHIVE_DIR)/$(PROJECT_NAME)-iOS.xcarchive \
		-exportPath $(BUILD_DIR)/export \
		-exportOptionsPlist exportOptions.plist 2>/dev/null || \
		echo "$(YELLOW)IPA export requires exportOptions.plist configuration$(NC)"

# Show build settings
show-settings:
	@echo "$(BLUE)Build Settings:$(NC)"
	$(XCODEBUILD) -project $(PROJECT_FILE) -scheme $(SCHEME) -showBuildSettings

# Lint and format (if swiftlint is available)
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		echo "$(BLUE)Running SwiftLint...$(NC)"; \
		swiftlint; \
	else \
		echo "$(YELLOW)SwiftLint not installed. Install with: brew install swiftlint$(NC)"; \
	fi