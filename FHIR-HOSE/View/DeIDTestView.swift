//
//  DeIDTestView.swift
//  FHIR-HOSE
//
//  Test module: select one record, view full FHIR-JSON, run de-identification, compare with tabs.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct DeIDTestView: View {
    @ObservedObject var recordStore: HealthRecordStore
    @StateObject private var qwenInference = QwenInference()

    /// Records that have FHIR-JSON (document pipeline or HealthKit fhirResource).
    private var recordsWithFHIR: [HealthRecord] {
        recordStore.records.filter { fhirJSON(for: $0) != nil }
    }

    @State private var selectedRecord: HealthRecord?
    @State private var deidentifiedJSON: [String: Any]?
    @State private var selectedTab: DeIDTab = .original
    @State private var isRunning = false
    @State private var useQwen = false
    @State private var pendingDeIDWithQwen: [String: Any]?
    /// When non-nil, show an alert that Qwen was not used or its output was rejected.
    @State private var deIDFallbackMessage: String?

    private enum DeIDTab: String, CaseIterable {
        case original = "Original"
        case deidentified = "De-identified"
    }

    var body: some View {
        Group {
            if recordsWithFHIR.isEmpty {
                emptyStateView
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 20) {
                        recordPickerSection
                        if let record = selectedRecord, let fhir = fhirJSON(for: record) {
                            tabAndContent(fhir: fhir, record: record)
                        }
                    }
                    .padding()
                    Spacer(minLength: 0)
                }
            }
        }
        .navigationTitle("FHIR De-ID Test")
        .alert("De-identification notice", isPresented: Binding(
            get: { deIDFallbackMessage != nil },
            set: { if !$0 { deIDFallbackMessage = nil } }
        )) {
            Button("OK", role: .cancel) { deIDFallbackMessage = nil }
        } message: {
            if let msg = deIDFallbackMessage {
                Text(msg)
            }
        }
        .onChange(of: qwenInference.isModelLoaded) { _, loaded in
            guard loaded, let fhir = pendingDeIDWithQwen else { return }
            pendingDeIDWithQwen = nil
            FHIRDeIdentifier.deidentifyWithQwen(fhir, qwen: qwenInference) { result, fallbackMessage in
                deidentifiedJSON = result
                deIDFallbackMessage = fallbackMessage
                selectedTab = .deidentified
                isRunning = false
            }
        }
    }

    private var recordPickerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Record")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Picker("Record", selection: $selectedRecord) {
                Text("Choose one…").tag(nil as HealthRecord?)
                ForEach(recordsWithFHIR) { record in
                    Text(friendlyRecordLabel(record))
                        .tag(record as HealthRecord?)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: selectedRecord) { _, _ in
                deidentifiedJSON = nil
                selectedTab = .original
            }
        }
    }

    private func tabAndContent(fhir: [String: Any], record: HealthRecord) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("View", selection: $selectedTab) {
                ForEach(DeIDTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            Text("Original = full FHIR. De-identification redacts PHI (names, IDs, dates). Run it below, then switch to De-identified to compare.")
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Use Qwen (on-device)", isOn: $useQwen)
                .onChange(of: useQwen) { _, on in
                    if on, !qwenInference.isModelLoaded { qwenInference.loadModel() }
                }

            Button(action: runDeID) {
                HStack {
                    if isRunning {
                        ProgressView()
                            .scaleEffect(0.9)
                            .tint(.white)
                    } else {
                        Image(systemName: "lock.shield.fill")
                    }
                    Text(isRunning ? "Running…" : "Run de-identification")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            switch selectedTab {
                case .original:
                    DeIDJSONCard(data: fhir)
                case .deidentified:
                    if let deid = deidentifiedJSON {
                        DeIDJSONCard(data: deid)
                    } else {
                        Text("Tap “Run de-identification” above, then switch to this tab to see redacted FHIR.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 32)
                    }
                }
        }
    }

    private func runDeID() {
        guard let record = selectedRecord, let fhir = fhirJSON(for: record) else { return }
        isRunning = true
        deIDFallbackMessage = nil
        if useQwen {
            if qwenInference.isModelLoaded {
                FHIRDeIdentifier.deidentifyWithQwen(fhir, qwen: qwenInference) { result, fallbackMessage in
                    deidentifiedJSON = result
                    deIDFallbackMessage = fallbackMessage
                    selectedTab = .deidentified
                    isRunning = false
                }
            } else {
                pendingDeIDWithQwen = fhir
                qwenInference.loadModel()
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = FHIRDeIdentifier.deidentify(fhir)
                DispatchQueue.main.async {
                    deidentifiedJSON = result
                    selectedTab = .deidentified
                    isRunning = false
                }
            }
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No FHIR records", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Add HealthKit data in the Records tab or process a document to see records here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func friendlyRecordLabel(_ record: HealthRecord) -> String {
        let name = friendlyTypeName(record.healthKitType) ?? record.filename
        if let date = record.healthKitData?["startDate"] as? String ?? record.healthKitData?["endDate"] as? String {
            return "\(name) · \(shortDate(date))"
        }
        return name
    }

    private func shortDate(_ iso: String) -> String {
        let end = iso.prefix(10)
        if end.count == 10 {
            return String(end)
        }
        return String(iso.prefix(16))
    }

    private func friendlyTypeName(_ type: String?) -> String? {
        guard let type = type, !type.isEmpty else { return nil }
        let mapping: [String: String] = [
            "HKClinicalTypeIdentifierConditionRecord": "Condition",
            "HKClinicalTypeIdentifierAllergyRecord": "Allergy",
            "HKClinicalTypeIdentifierMedicationRecord": "Medication",
            "HKClinicalTypeIdentifierProcedureRecord": "Procedure",
            "HKClinicalTypeIdentifierLabResultRecord": "Lab Result",
            "HKClinicalTypeIdentifierVitalSignRecord": "Vital Sign",
            "HKClinicalTypeIdentifierImmunizationRecord": "Immunization",
            "HKQuantityTypeIdentifierHeartRate": "Heart Rate",
            "HKQuantityTypeIdentifierBloodPressureSystolic": "Blood Pressure (Systolic)",
            "HKQuantityTypeIdentifierBloodPressureDiastolic": "Blood Pressure (Diastolic)",
            "HKQuantityTypeIdentifierBodyTemperature": "Body Temperature",
            "HKQuantityTypeIdentifierHeight": "Height",
            "HKQuantityTypeIdentifierBodyMass": "Weight",
            "HKQuantityTypeIdentifierBodyMassIndex": "BMI",
            "HKQuantityTypeIdentifierStepCount": "Step Count",
            "HKQuantityTypeIdentifierDistanceWalkingRunning": "Walking/Running",
            "HKQuantityTypeIdentifierActiveEnergyBurned": "Active Energy",
            "HKQuantityTypeIdentifierBloodGlucose": "Blood Glucose",
            "HKQuantityTypeIdentifierOxygenSaturation": "Oxygen Saturation",
            "BloodType": "Blood Type",
            "BiologicalSex": "Biological Sex",
            "DateOfBirth": "Date of Birth",
        ]
        if let mapped = mapping[type] { return mapped }
        return type
            .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
            .replacingOccurrences(of: "Record", with: "")
    }

    /// FHIR-JSON for this record: from document pipeline (fhirData) or HealthKit (decode fhirResource).
    private func fhirJSON(for record: HealthRecord) -> [String: Any]? {
        if let fhir = record.fhirData { return fhir }
        guard let b64 = record.healthKitData?["fhirResource"] as? String, !b64.isEmpty else { return nil }
        let cleaned = b64
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        guard let data = Data(base64Encoded: cleaned), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

// MARK: - JSON card for De-ID screen (scrollable; copyable)
private struct DeIDJSONCard: View {
    let data: [String: Any]
    @State private var copyFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button {
                    copyJSONToPasteboard(prettyJSON(data))
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyFeedback = false }
                } label: {
                    Label(copyFeedback ? "Copied" : "Copy JSON", systemImage: copyFeedback ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.caption)
                }
                .disabled(prettyJSON(data).isEmpty)
            }
            ScrollView(.vertical, showsIndicators: true) {
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(prettyJSON(data))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(alignment: .topLeading)
                        .padding()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 500)
        }
        .padding(10)
        .background(Color(UIColor.secondarySystemFill))
        .cornerRadius(12)
    }

    private func copyJSONToPasteboard(_ string: String) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    private func prettyJSON(_ dict: [String: Any]) -> String {
        let sanitized = makeJSONSerializable(dict)
        guard let data = try? JSONSerialization.data(withJSONObject: sanitized, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "Unable to format JSON"
        }
        return str
    }

    private func makeJSONSerializable(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            return Dictionary(uniqueKeysWithValues: d.map { ($0.key, makeJSONSerializable($0.value)) })
        case let a as [Any]:
            return a.map { makeJSONSerializable($0) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case is String, is Int, is Double, is Float, is Bool:
            return value
        default:
            return String(describing: value)
        }
    }
}
