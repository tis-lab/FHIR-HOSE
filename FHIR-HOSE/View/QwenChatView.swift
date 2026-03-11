//
//  QwenChatView.swift
//  FHIR-HOSE
//

import SwiftUI

struct QwenChatView: View {
    var recordStore: HealthRecordStore?
    @StateObject private var inference = QwenInference()
    @State private var inputText = ""
    @State private var messages: [ChatMessage] = []
    @State private var recordsLoaded = false

    var body: some View {
        VStack(spacing: 0) {
            if !inference.isModelLoaded {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(inference.statusMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            } else if let store = recordStore, !store.records.isEmpty {
                recordsBanner(store)
            }

            if inference.isModelLoaded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                            }

                            if inference.isGenerating {
                                MessageBubble(message: ChatMessage(
                                    role: "assistant",
                                    content: inference.currentResponse.isEmpty
                                        ? "Thinking..."
                                        : inference.currentResponse
                                ))
                                .id("streaming")
                            }
                        }
                        .padding()
                    }
                    .onChange(of: inference.currentResponse) { _, _ in
                        withAnimation {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        }
                    }
                    .onChange(of: messages.count) { _, _ in
                        if let lastID = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    TextField("Type a message...", text: $inputText, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...5)
                        .disabled(inference.isGenerating)
                        .onSubmit {
                            sendMessage()
                        }

                    if inference.isGenerating {
                        Button("Stop") {
                            inference.stopGeneration()
                        }
                        .foregroundColor(.red)
                        .fontWeight(.semibold)
                    } else {
                        Button {
                            sendMessage()
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding()
            }
        }
        .navigationTitle(recordStore != nil ? "Qwen Records Chat" : "Qwen Chat")
        .onAppear {
            inference.loadModel()
            loadRecordsContext()
        }
        .onChange(of: inference.isGenerating) { oldValue, newValue in
            if oldValue == true && newValue == false && !inference.currentResponse.isEmpty {
                messages.append(ChatMessage(role: "assistant", content: inference.currentResponse))
            }
        }
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(ChatMessage(role: "user", content: text))
        inputText = ""

        inference.generate(messages: messages)
    }

    private func loadRecordsContext() {
        guard !recordsLoaded, let store = recordStore, !store.records.isEmpty else { return }
        recordsLoaded = true

        let fullText = convertRecordsToText(store.records)

        let maxChars = 6000
        let medicalText: String
        if fullText.count > maxChars {
            medicalText = String(fullText.prefix(maxChars)) + "\n\n[Records truncated to fit context window. Increase n_ctx for full records.]"
        } else {
            medicalText = fullText
        }

        inference.systemPrompt = """
        You are a medical records assistant with access to the patient's health data. \
        Answer questions about their records accurately based on the data provided below. \
        If the answer is not in the records, say so.

        \(medicalText)
        """
    }

    private func convertRecordsToText(_ records: [HealthRecord]) -> String {
        var text = "PATIENT HEALTH RECORDS:\n"
        text += String(repeating: "=", count: 40) + "\n\n"

        for record in records where record.processed {
            text += "--- \(record.filename) (\(record.date.formatted(date: .abbreviated, time: .omitted))) ---\n"

            if let fhirData = record.fhirData {
                text += formatData(fhirData, indent: "  ")
            } else if let hkData = record.healthKitData {
                text += "Type: \(record.healthKitType ?? "Unknown")\n"
                text += formatData(hkData, indent: "  ")
            }
            text += "\n"
        }

        return text
    }

    private func formatData(_ data: [String: Any], indent: String) -> String {
        var result = ""
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            if let dict = value as? [String: Any] {
                result += "\(indent)\(key):\n"
                result += formatData(dict, indent: indent + "  ")
            } else if let array = value as? [[String: Any]] {
                result += "\(indent)\(key): [\n"
                for item in array {
                    result += formatData(item, indent: indent + "  ")
                }
                result += "\(indent)]\n"
            } else {
                result += "\(indent)\(key): \(value)\n"
            }
        }
        return result
    }

    private func recordsBanner(_ store: HealthRecordStore) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.fill")
                .foregroundColor(.green)
            Text("\(store.records.filter { $0.processed }.count) records loaded")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.green.opacity(0.1))
    }
}

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
