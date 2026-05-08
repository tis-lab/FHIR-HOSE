# FHIR-HOSE Build Instructions

This document explains how to build the FHIR-HOSE app from the command line.

## Prerequisites

- Xcode installed from the Mac App Store
- Command Line Tools for Xcode
- Make (usually pre-installed on macOS)

## Quick Start

### Using Makefile (Recommended)

```bash
# View all available commands
make help

# Build for iOS Simulator
make build-ios

# Build for macOS
make build-macos

# Run tests
make test-ios

# Build and run on macOS
make run-macos

# Clean build artifacts
make clean
```

### Using Build Script

```bash
# Build for iOS (default)
./build.sh

# Build for macOS Release
./build.sh --platform macos --config Release

# Run tests
./build.sh --action test

# Build and run on specific iOS simulator
./build.sh --action run --device "iPad Pro"

# Clean project
./build.sh --action clean

# Show help
./build.sh --help
```

## Available Commands

### Makefile Commands

| Command | Description |
|---------|-------------|
| `make build-ios` | Build for iOS Simulator |
| `make build-macos` | Build for macOS |
| `make build-all` | Build for all platforms |
| `make test-ios` | Run tests on iOS Simulator |
| `make test-macos` | Run tests on macOS |
| `make test-all` | Run tests on all platforms |
| `make run-ios` | Build and prepare to run on iOS |
| `make run-macos` | Build and run on macOS |
| `make archive-ios` | Create iOS archive |
| `make archive-macos` | Create macOS archive |
| `make clean` | Clean all build artifacts |
| `make list-devices` | List available devices/simulators |
| `make debug` | Build debug configuration |
| `make release` | Build release configuration |

### Build Script Options

| Option | Description | Default |
|--------|-------------|---------|
| `-p, --platform` | Target platform (ios/macos) | ios |
| `-c, --config` | Build configuration (Debug/Release) | Debug |
| `-d, --device` | iOS device/simulator name | iPhone 15 |
| `-a, --action` | Action (build/test/run/archive/clean) | build |
| `-h, --help` | Show help message | - |

## Examples

### Development Workflow

```bash
# Clean and build for development
make clean build-ios

# Run quick tests
make quick-test

# Build and run on macOS
make run-macos
```

### Release Workflow

```bash
# Build release version for all platforms
make release

# Create archives for distribution
make archive-ios archive-macos
```

### Custom Device Testing

```bash
# List available simulators
make list-simulators

# Build for specific device
./build.sh --device "iPhone 15 Pro Max" --action run
```

## Supported Platforms

- **iOS**: iPhone and iPad simulators, iOS 18.1+
- **macOS**: Native macOS apps, macOS 14.6+
- **visionOS**: Apple Vision Pro (via Xcode)

## Build Artifacts

- **Build directory**: `build/`
- **Archives**: `archives/`
- **Derived Data**: `build/DerivedData/`

## Troubleshooting

### Common Issues

1. **Xcode not found**: Ensure Xcode is installed and command line tools are configured
   ```bash
   sudo xcode-select --install
   ```

2. **Simulator not available**: List available simulators and use exact name
   ```bash
   make list-simulators
   ```

3. **Build failures**: Clean and retry
   ```bash
   make clean
   make build-ios
   ```

4. **Permission errors**: Ensure scripts are executable
   ```bash
   chmod +x build.sh
   ```

### Environment Variables

You can customize the build by setting environment variables:

```bash
# Use different iOS device
export IOS_DEVICE="iPad Pro"
make build-ios

# Use custom build configuration
make build-ios CONFIGURATION=Release
```

## Integration with CI/CD

Both the Makefile and build script are designed to work in CI/CD environments:

```bash
# GitHub Actions example
- name: Build iOS
  run: make build-ios

# Jenkins example
sh './build.sh --platform ios --config Release --action build'
```

## Performance Tips

- Use `make build-all` to build all platforms in sequence
- Use `make test-all` for comprehensive testing
- Clean builds when switching between Debug/Release: `make clean`
- Archive builds are optimized for distribution