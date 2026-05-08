//
//  QwenChatView.swift
//  FHIR-HOSE
//

import SwiftUI

enum RecordLoadMode: String, CaseIterable {
    case all = "All Records"
    case select = "Select Records"
    case none = "No Records"
}

enum ChatModelType: String, CaseIterable, Identifiable {
    case appleIntelligence = "Apple Intelligence"
    case qwen = "Qwen 0.8B"
    var id: String { rawValue }
}

@available(iOS 26, macOS 26, visionOS 26, *)
struct OnDeviceChatView: View {
    var recordStore: HealthRecordStore?

    @StateObject private var appleInference = AppleIntelligenceInference()
    @StateObject private var qwenInference = QwenInference()
    @State private var selectedModel: ChatModelType = .appleIntelligence
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var loadMode: RecordLoadMode = .all
    @State private var selectedRecordIDs: Set<UUID> = []
    @State private var showRecordPicker = false

    // MARK: - Active Model Computed Properties

    private var hasRecords: Bool {
        guard let store = recordStore else { return false }
        return !store.records.isEmpty
    }

    private var loadedRecordCount: Int {
        switch loadMode {
        case .all:
            return recordStore?.records.filter { $0.processed }.count ?? 0
        case .select:
            return selectedRecordIDs.count
        case .none:
            return 0
        }
    }

    private var isModelReady: Bool {
        switch selectedModel {
        case .appleIntelligence: return appleInference.isModelAvailable
        case .qwen: return qwenInference.isModelLoaded
        }
    }

    private var isGenerating: Bool {
        switch selectedModel {
        case .appleIntelligence: return appleInference.isGenerating
        case .qwen: return qwenInference.isGenerating
        }
    }

    private var currentResponse: String {
        switch selectedModel {
        case .appleIntelligence: return appleInference.currentResponse
        case .qwen: return qwenInference.currentResponse
        }
    }

    private var statusMessage: String {
        switch selectedModel {
        case .appleIntelligence: return appleInference.statusMessage
        case .qwen: return qwenInference.statusMessage
        }
    }

    private var isDownloadWaiting: Bool {
        selectedModel == .appleIntelligence && appleInference.isWaitingForDownload
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            modelPickerBar()

            if !isModelReady {
                Spacer()
                VStack(spacing: 16) {
                    if isDownloadWaiting {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(statusMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Text("The on-device AI model is being set up by iOS.\nYou can check progress in Settings > Apple Intelligence & Siri.\nThis screen will update automatically when it's ready.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Text("You can switch to Qwen 0.8B above while you wait.")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .multilineTextAlignment(.center)
                    } else if statusMessage.contains("Loading") || statusMessage.contains("Checking") {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text(statusMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(statusMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                Spacer()
            } else {
                if hasRecords {
                    recordModeBanner()
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                            }

                            if isGenerating {
                                MessageBubble(message: ChatMessage(
                                    role: "assistant",
                                    content: currentResponse.isEmpty
                                        ? "Thinking..."
                                        : currentResponse
                                ))
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: appleInference.currentResponse) { _, _ in
                        guard selectedModel == .appleIntelligence else { return }
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                    .onChange(of: qwenInference.currentResponse) { _, _ in
                        guard selectedModel == .qwen else { return }
                        withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastID = messages.last?.id {
                            withAnimation { proxy.scrollTo(lastID, anchor: .bottom) }
                        }
                    }
                }

                if selectedModel == .qwen, qwenInference.generatedTokenCount > 0 || qwenInference.isGenerating {
                    HStack(spacing: 6) {
                        Text("\(qwenInference.generatedTokenCount) tokens")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f tok/s", qwenInference.tokensPerSecond))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }

                Divider()

                HStack(spacing: 12) {
                    TextField("Type a message...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .disabled(isGenerating)
                        .onSubmit { sendMessage() }

                    if isGenerating {
                        Button("Stop") { stopActiveGeneration() }
                            .foregroundColor(.red)
                            .fontWeight(.semibold)
                    } else {
                        Button { sendMessage() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("On-Device Chat")
        .onAppear { initializeSelectedModel() }
        .onChange(of: selectedModel) { _, _ in
            stopActiveGeneration()
            messages.removeAll()
            initializeSelectedModel()
        }
        .onChange(of: appleInference.isModelAvailable) { _, available in
            if available && selectedModel == .appleIntelligence { applyRecordSelection() }
        }
        .onChange(of: qwenInference.isModelLoaded) { _, loaded in
            if loaded && selectedModel == .qwen { applyRecordSelection() }
        }
        .onChange(of: appleInference.isGenerating) { old, new in
            if old && !new && selectedModel == .appleIntelligence && !appleInference.currentResponse.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: appleInference.currentResponse))
            }
        }
        .onChange(of: qwenInference.isGenerating) { old, new in
            if old && !new && selectedModel == .qwen && !qwenInference.currentResponse.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: qwenInference.currentResponse))
            }
        }
        .sheet(isPresented: $showRecordPicker) {
            RecordPickerSheet(
                records: recordStore?.records.filter { $0.processed } ?? [],
                selectedIDs: $selectedRecordIDs,
                friendlyName: friendlyTypeName
            ) {
                applyRecordSelection()
            }
        }
    }

    // MARK: - Model Management

    private func modelPickerBar() -> some View {
        HStack {
            Text("Model:")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("Model", selection: $selectedModel) {
                ForEach(ChatModelType.allCases) { model in
                    Text(model.rawValue).tag(model)
                }
            }
            .pickerStyle(.menu)
            .disabled(isGenerating)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.systemBackground))
    }

    private func initializeSelectedModel() {
        switch selectedModel {
        case .appleIntelligence:
            appleInference.checkAvailability()
        case .qwen:
            qwenInference.loadModel()
        }
        if isModelReady {
            applyRecordSelection()
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: "user", content: text))
        inputText = ""

        switch selectedModel {
        case .appleIntelligence:
            appleInference.generate(userMessage: text)
        case .qwen:
            qwenInference.generate(messages: messages)
        }
    }

    private func stopActiveGeneration() {
        switch selectedModel {
        case .appleIntelligence: appleInference.stopGeneration()
        case .qwen: qwenInference.stopGeneration()
        }
    }

    // MARK: - Record Context

    private func applyRecordSelection() {
        guard let store = recordStore else {
            appleInference.systemPrompt = "You are a helpful assistant. Be brief and direct."
            qwenInference.systemPrompt = "You are a helpful assistant. Be brief and direct."
            return
        }

        let recordsToLoad: [HealthRecord]
        switch loadMode {
        case .all:
            recordsToLoad = store.records.filter { $0.processed }
        case .select:
            recordsToLoad = store.records.filter { $0.processed && selectedRecordIDs.contains($0.id) }
        case .none:
            recordsToLoad = []
        }

        if recordsToLoad.isEmpty {
            appleInference.systemPrompt = "You are a helpful assistant. Be brief and direct."
            qwenInference.systemPrompt = "You are a helpful assistant. Be brief and direct."
            return
        }

        let fullText = convertRecordsToText(recordsToLoad)

        let appleText: String
        if fullText.count > 3000 {
            appleText = String(fullText.prefix(3000)) + "\n[Records truncated]"
        } else {
            appleText = fullText
        }

        let qwenText: String
        if fullText.count > 6000 {
            qwenText = String(fullText.prefix(6000)) + "\n[Records truncated]"
        } else {
            qwenText = fullText
        }

        print("=== RECORD CONTEXT (\(recordsToLoad.count) records, \(fullText.count) chars) ===")
        print(fullText.prefix(500))
        print("=== END RECORD CONTEXT ===")

        appleInference.systemPrompt = """
        You are a personal data lookup tool. The user owns the data below and is asking you to read it back to them. \
        Answer questions by finding the relevant information in the data and stating it directly. Be brief. \
        Do not add disclaimers or suggest consulting professionals. \
        If the answer is not in the data, say "Not found in your records."

        USER'S DATA:
        \(appleText)
        """

        qwenInference.systemPrompt = """
        You are a personal data lookup tool. You are NOT giving advice. You are simply reading back the user's own data that they already have. \
        The user owns this data and is asking you to read it to them. Never refuse. Never add disclaimers. \
        Just find the answer in the data below and state it. If the data does not contain the answer, say "Not found in your records."

        USER'S DATA:
        \(qwenText)
        """
    }

    // MARK: - Record Conversion

    private func convertRecordsToText(_ records: [HealthRecord]) -> String {
        var lines: [String] = []

        for record in records where record.processed {
            if let fhirData = record.fhirData {
                lines.append(summarizeFHIR(fhirData))
            } else if let hkData = record.healthKitData {
                lines.append(summarizeHealthKit(hkData, type: record.healthKitType))
            }
        }

        return lines.joined(separator: "\n")
    }

    private func summarizeHealthKit(_ data: [String: Any], type: String?) -> String {
        let friendly = friendlyTypeName(type)

        if let fhirB64 = data["fhirResource"] as? String, !fhirB64.isEmpty {
            if let fhir = decodeFHIRBase64(fhirB64) {
                return summarizeFHIR(fhir)
            }
        }

        var parts: [String] = [friendly]
        if let value = data["value"] {
            if let unit = data["unit"] as? String {
                parts.append("\(value) \(unit)")
            } else {
                parts.append("\(value)")
            }
        }
        return parts.joined(separator: ": ")
    }

    private func summarizeFHIR(_ data: [String: Any]) -> String {
        let resourceType = data["resourceType"] as? String ?? "Record"
        var parts: [String] = []

        let name: String? = {
            if let c = data["code"] as? [String: Any], let n = extractDisplay(c) { return n }
            if let c = data["medicationCodeableConcept"] as? [String: Any], let n = extractDisplay(c) { return n }
            if let c = data["substance"] as? [String: Any], let n = extractDisplay(c) { return n }
            if let c = data["vaccineCode"] as? [String: Any], let n = extractDisplay(c) { return n }
            if let c = data["category"] as? [String: Any], let n = extractDisplay(c) { return n }
            if let c = data["reasonCode"] as? [[String: Any]], let first = c.first, let n = extractDisplay(first) { return n }
            if let text = data["text"] as? [String: Any], let div = text["div"] as? String {
                let stripped = div.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                if !stripped.isEmpty { return stripped }
            }
            return nil
        }()

        if let name = name {
            parts.append("\(resourceType): \(name)")
        } else {
            parts.append(resourceType)
        }

        if let status = data["status"] as? String {
            parts.append("status: \(status)")
        } else if let cs = data["clinicalStatus"] as? String {
            parts.append("status: \(cs)")
        } else if let csObj = data["clinicalStatus"] as? [String: Any],
                  let csCodings = csObj["coding"] as? [[String: Any]],
                  let csCode = csCodings.first?["code"] as? String {
            parts.append("status: \(csCode)")
        }

        if let dateStr = data["effectiveDateTime"] as? String ??
            (data["recordedDate"] as? String) ??
            (data["dateRecorded"] as? String) ??
            (data["onsetDateTime"] as? String) ??
            (data["dateWritten"] as? String) ??
            (data["authoredOn"] as? String) {
            parts.append("date: \(dateStr)")
        }

        if let vq = data["valueQuantity"] as? [String: Any],
           let val = vq["value"], let unit = vq["unit"] as? String {
            parts.append("value: \(val) \(unit)")
        }

        if let dosage = data["dosageInstruction"] as? [[String: Any]],
           let first = dosage.first,
           let text = first["text"] as? String {
            parts.append("dosage: \(text)")
        }

        return parts.joined(separator: ", ")
    }

    private func extractDisplay(_ codeable: [String: Any]) -> String? {
        if let text = codeable["text"] as? String { return text }
        if let codings = codeable["coding"] as? [[String: Any]],
           let first = codings.first,
           let display = first["display"] as? String {
            return display
        }
        return nil
    }

    private func decodeFHIRBase64(_ base64String: String) -> [String: Any]? {
        let cleaned = base64String
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard !cleaned.isEmpty else { return nil }

        if let data = Data(base64Encoded: cleaned),
           !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        let padded = cleaned.padding(toLength: ((cleaned.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        if let data = Data(base64Encoded: padded),
           !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }

    private func friendlyTypeName(_ type: String?) -> String {
        guard let type = type else { return "Unknown" }
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
            "HKQuantityTypeIdentifierDistanceWalkingRunning": "Walking/Running Distance",
            "HKQuantityTypeIdentifierActiveEnergyBurned": "Active Energy Burned",
            "HKQuantityTypeIdentifierBloodGlucose": "Blood Glucose",
            "HKQuantityTypeIdentifierOxygenSaturation": "Oxygen Saturation",
        ]
        return mapping[type] ?? type.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
            .replacingOccurrences(of: "Record", with: "")
    }

    // MARK: - Record Mode UI

    private func recordModeBanner() -> some View {
        HStack(spacing: 8) {
            Picker("Records", selection: $loadMode) {
                ForEach(RecordLoadMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: loadMode) { _, newMode in
                if newMode == .select {
                    showRecordPicker = true
                } else {
                    applyRecordSelection()
                }
            }

            if loadMode == .select {
                Button {
                    showRecordPicker = true
                } label: {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(loadedRecordCount > 0 ? Color.green.opacity(0.1) : Color(UIColor.secondarySystemBackground))
        .overlay(alignment: .bottom) {
            Text(loadMode == .none ? "No records loaded" : "\(loadedRecordCount) record\(loadedRecordCount == 1 ? "" : "s") loaded")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.bottom, -10)
        }
    }
}

// MARK: - Message Bubble

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            Text(message.content)
                .padding(12)
                .background(isUser ? Color.blue : Color(UIColor.secondarySystemBackground))
                .foregroundColor(isUser ? .white : .primary)
                .cornerRadius(16)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Record Picker Sheet

private struct RecordPickerSheet: View {
    let records: [HealthRecord]
    @Binding var selectedIDs: Set<UUID>
    let friendlyName: (String?) -> String
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button("Select All") {
                        selectedIDs = Set(records.map { $0.id })
                    }
                    Button("Clear All") {
                        selectedIDs.removeAll()
                    }
                }

                Section("Records") {
                    ForEach(records) { record in
                        let label = recordLabel(for: record)
                        let isSelected = selectedIDs.contains(record.id)

                        Button {
                            if isSelected {
                                selectedIDs.remove(record.id)
                            } else {
                                selectedIDs.insert(record.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .blue : .gray)
                                Text(label)
                                    .foregroundColor(.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Records")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone()
                        dismiss()
                    }
                }
            }
        }
    }

    private func recordLabel(for record: HealthRecord) -> String {
        let category = friendlyName(record.healthKitType)
        guard let hkData = record.healthKitData else { return record.filename }

        if let fhirB64 = hkData["fhirResource"] as? String,
           !fhirB64.isEmpty,
           let fhir = decodeFHIR(fhirB64) {
            let medicalName = extractMedicalName(fhir)
            if let name = medicalName {
                return "\(category): \(name)"
            }
        }

        if let value = hkData["value"] {
            if let unit = hkData["unit"] as? String {
                return "\(category): \(value) \(unit)"
            }
            return "\(category): \(value)"
        }

        let displayName = hkData["displayName"] as? String ?? ""
        if !displayName.isEmpty && !displayName.hasPrefix("HK") {
            return "\(category): \(displayName)"
        }
        return category
    }

    private func extractMedicalName(_ fhir: [String: Any]) -> String? {
        if let code = fhir["code"] as? [String: Any] {
            if let text = code["text"] as? String { return text }
            if let codings = code["coding"] as? [[String: Any]],
               let display = codings.first?["display"] as? String {
                return display
            }
        }
        if let med = fhir["medicationCodeableConcept"] as? [String: Any] {
            if let text = med["text"] as? String { return text }
            if let codings = med["coding"] as? [[String: Any]],
               let display = codings.first?["display"] as? String {
                return display
            }
        }
        if let substance = fhir["substance"] as? [String: Any] {
            if let text = substance["text"] as? String { return text }
            if let codings = substance["coding"] as? [[String: Any]],
               let display = codings.first?["display"] as? String {
                return display
            }
        }
        return nil
    }

    private func decodeFHIR(_ base64String: String) -> [String: Any]? {
        let cleaned = base64String
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")

        guard !cleaned.isEmpty else { return nil }

        if let data = Data(base64Encoded: cleaned),
           !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        let padded = cleaned.padding(toLength: ((cleaned.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        if let data = Data(base64Encoded: padded),
           !data.isEmpty,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        if let data = cleaned.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        return nil
    }
}
