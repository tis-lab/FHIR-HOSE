#!/bin/bash

# FHIR-HOSE Build Script
# Simple script to build and run the FHIR-HOSE app from command line

set -e  # Exit on any error

# Configuration
PROJECT_NAME="FHIR-HOSE"
SCHEME="FHIR-HOSE"
PROJECT_FILE="${PROJECT_NAME}.xcodeproj"
XCODEBUILD="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"

# Default values
PLATFORM="ios"
CONFIGURATION="Debug"
DEVICE="iPhone 15"
ACTION="build"

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to show usage
show_usage() {
    echo "FHIR-HOSE Build Script"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "OPTIONS:"
    echo "  -p, --platform <ios|macos>     Target platform (default: ios)"
    echo "  -c, --config <Debug|Release>   Build configuration (default: Debug)"
    echo "  -d, --device <device_name>     iOS device/simulator name (default: iPhone 15)"
    echo "  -a, --action <build|test|run|archive|clean>  Action to perform (default: build)"
    echo "  -h, --help                     Show this help message"
    echo ""
    echo "EXAMPLES:"
    echo "  $0                             # Build for iOS Debug"
    echo "  $0 -p macos -c Release         # Build for macOS Release"
    echo "  $0 -a test                     # Run tests on iOS"
    echo "  $0 -a run -d 'iPad Pro'        # Build and run on iPad Pro simulator"
    echo "  $0 -a clean                    # Clean build artifacts"
    echo "  $0 -a archive -c Release       # Create release archive"
    echo ""
}

# Function to check if Xcode is available
check_xcode() {
    if [ ! -f "$XCODEBUILD" ]; then
        print_error "Xcode not found at $XCODEBUILD"
        print_info "Please install Xcode from the Mac App Store"
        exit 1
    fi
}

# Function to get destination string
get_destination() {
    case $PLATFORM in
        ios)
            echo "platform=iOS Simulator,name=$DEVICE"
            ;;
        macos)
            echo "platform=macOS"
            ;;
        *)
            print_error "Unknown platform: $PLATFORM"
            exit 1
            ;;
    esac
}

# Function to build the project
build_project() {
    local destination=$(get_destination)
    
    print_info "Building $PROJECT_NAME for $PLATFORM ($CONFIGURATION)..."
    
    $XCODEBUILD build \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "$destination" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "build/DerivedData"
    
    print_success "Build completed successfully"
}

# Function to run tests
run_tests() {
    local destination=$(get_destination)
    
    print_info "Running tests for $PROJECT_NAME on $PLATFORM..."
    
    $XCODEBUILD test \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME" \
        -destination "$destination" \
        -derivedDataPath "build/DerivedData"
    
    print_success "Tests completed successfully"
}

# Function to run the app
run_app() {
    # First build
    build_project
    
    case $PLATFORM in
        ios)
            print_info "Note: Use Xcode or Simulator.app to launch the app on iOS"
            print_info "The app has been built and is ready to run"
            ;;
        macos)
            print_info "Finding and launching app on macOS..."
            APP_PATH=$(find build/DerivedData -name "${PROJECT_NAME}.app" -path "*/Build/Products/${CONFIGURATION}/*" | head -1)
            if [ -n "$APP_PATH" ]; then
                print_success "Launching: $APP_PATH"
                open "$APP_PATH"
            else
                print_error "Could not find built app"
                exit 1
            fi
            ;;
    esac
}

# Function to create archive
create_archive() {
    print_info "Creating archive for $PLATFORM..."
    
    mkdir -p archives
    
    case $PLATFORM in
        ios)
            $XCODEBUILD archive \
                -project "$PROJECT_FILE" \
                -scheme "$SCHEME" \
                -destination "generic/platform=iOS" \
                -archivePath "archives/${PROJECT_NAME}-iOS.xcarchive" \
                -configuration "$CONFIGURATION"
            print_success "iOS archive created: archives/${PROJECT_NAME}-iOS.xcarchive"
            ;;
        macos)
            $XCODEBUILD archive \
                -project "$PROJECT_FILE" \
                -scheme "$SCHEME" \
                -destination "platform=macOS" \
                -archivePath "archives/${PROJECT_NAME}-macOS.xcarchive" \
                -configuration "$CONFIGURATION"
            print_success "macOS archive created: archives/${PROJECT_NAME}-macOS.xcarchive"
            ;;
    esac
}

# Function to clean build artifacts
clean_project() {
    print_info "Cleaning build artifacts..."
    
    rm -rf build archives
    
    $XCODEBUILD clean \
        -project "$PROJECT_FILE" \
        -scheme "$SCHEME"
    
    print_success "Clean completed"
}

# Function to list available devices
list_devices() {
    print_info "Available devices and simulators:"
    $XCODEBUILD -showdestinations -project "$PROJECT_FILE" -scheme "$SCHEME"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--platform)
            PLATFORM="$2"
            shift 2
            ;;
        -c|--config)
            CONFIGURATION="$2"
            shift 2
            ;;
        -d|--device)
            DEVICE="$2"
            shift 2
            ;;
        -a|--action)
            ACTION="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

# Validate inputs
case $PLATFORM in
    ios|macos) ;;
    *)
        print_error "Invalid platform: $PLATFORM. Use 'ios' or 'macos'"
        exit 1
        ;;
esac

case $CONFIGURATION in
    Debug|Release) ;;
    *)
        print_error "Invalid configuration: $CONFIGURATION. Use 'Debug' or 'Release'"
        exit 1
        ;;
esac

case $ACTION in
    build|test|run|archive|clean|devices) ;;
    *)
        print_error "Invalid action: $ACTION. Use 'build', 'test', 'run', 'archive', 'clean', or 'devices'"
        exit 1
        ;;
esac

# Check prerequisites
check_xcode

# Ensure we're in the right directory
if [ ! -f "$PROJECT_FILE" ]; then
    print_error "Project file $PROJECT_FILE not found. Please run this script from the project root directory."
    exit 1
fi

# Execute the requested action
print_info "Starting $ACTION for $PROJECT_NAME..."
print_info "Platform: $PLATFORM, Configuration: $CONFIGURATION"
if [ "$PLATFORM" = "ios" ]; then
    print_info "Device: $DEVICE"
fi
echo ""

case $ACTION in
    build)
        build_project
        ;;
    test)
        run_tests
        ;;
    run)
        run_app
        ;;
    archive)
        create_archive
        ;;
    clean)
        clean_project
        ;;
    devices)
        list_devices
        ;;
esac

print_success "Script completed successfully!"