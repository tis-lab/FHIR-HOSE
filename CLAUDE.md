# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Building and Running
- **Build app**: Use Xcode build commands (`⌘+B`) or `xcodebuild -project FHIR-HOSE.xcodeproj -scheme FHIR-HOSE -configuration Debug build`
- **Run tests**: Use Xcode test commands (`⌘+U`) or `xcodebuild test -project FHIR-HOSE.xcodeproj -scheme FHIR-HOSE -destination 'platform=iOS Simulator,name=iPhone 15'`
- **Run app**: Launch from Xcode (`⌘+R`) targeting iOS Simulator, macOS, or visionOS

### Platform Support
- iOS 18.1+, macOS 14.6+, visionOS 2.1+
- Universal app supporting iPhone, iPad, Mac, and Apple Vision Pro

## Architecture

### Core Components

**FHIR-HOSE** is a SwiftUI health records processing app that integrates with the Charmonizer service to convert medical documents (PDFs/images) into structured FHIR data.

#### Data Models (`Model/`)
- `HealthRecord`: Core data structure representing medical documents (PDF/image) with processing status and FHIR data storage
- `ServerConfig`: Configuration for Charmonizer API endpoints (loaded from `server-config.json`)
- `CharmonizerModels`: API models for document conversion jobs, status polling, and FHIR summarization

#### View Layer (`View/`)
- `ContentView`: Main tabbed interface with Records and Settings tabs
- `RecordsListView`: Displays health records with processing status
- `ProcessedRecordView` & `UnprocessedRecordView`: Different views based on processing state
- `RecordDetailView`: Detailed view of individual records with FHIR data display

#### Business Logic (`ViewModel/`)
- `HealthRecordStore`: Central ObservableObject managing records and Charmonizer API integration
- `DocumentPicker` & `ImagePicker`: File import functionality
- `FetchHealthKit`: HealthKit integration for user data

### Processing Workflow

1. **Document Upload**: Users import PDFs or images via DocumentPicker/ImagePicker
2. **Charmonizer Processing**: 
   - Upload to `/conversions/documents` endpoint
   - Poll for conversion completion
   - Submit for FHIR summarization via `/summaries` endpoint
   - Poll for summary completion
3. **FHIR Data Storage**: Processed documents store structured FHIR data in `HealthRecord.fhirData`

### Configuration Files

- `server-config.json`: Charmonizer API configuration (serverBase, baseUrlPrefix)
- `inlined-minimum-fhir.json`: FHIR JSON schema for document summarization
- `Info.plist`: App permissions for Documents, HealthKit, and Photo Library access

### API Integration

The app communicates with Charmonizer service for:
- Document conversion (PDFs → structured text)
- AI-powered summarization using FHIR schema
- Asynchronous job processing with polling

### Development Notes

- Uses SwiftUI with iOS 18.1+ features
- ObservableObject pattern for state management
- Async/await for API calls with proper error handling
- Logger integration for debugging API interactions
- Multi-platform deployment (iOS, macOS, visionOS)

## Workflow Preferences

- **Do NOT run xcodebuild**: Do not attempt to build or verify builds using xcodebuild commands. The user will build and test in Xcode manually.