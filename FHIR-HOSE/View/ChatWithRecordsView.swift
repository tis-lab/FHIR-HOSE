//
//  ChatWithRecordsView.swift
//  FHIR-HOSE
//
//  Created by Claude on 6/8/25.
//

import SwiftUI
import WebKit
import OSLog

struct ChatWithRecordsView: View {
    @ObservedObject var recordStore: HealthRecordStore
    @StateObject private var clinicalTrialMatcher = ClinicalTrialMatcher()
    @State private var showingWebView = false
    @State private var webViewURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var generatedMedicalText = ""
    @State private var showingMedicalText = false
    
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "ChatWithRecordsView")
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                recordsSection
                actionButtons
                
                if !generatedMedicalText.isEmpty {
                    medicalTextPreview
                }
                
                if let error = errorMessage {
                    errorSection(error)
                }
            }
            .padding()
        }
        .navigationTitle("Chat with Records")
        .sheet(isPresented: $showingWebView) {
            if let url = webViewURL {
                ChatWebView(url: url)
            }
        }
        .sheet(isPresented: $showingMedicalText) {
            MedicalTextView(text: generatedMedicalText)
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "message.circle")
                .font(.system(size: 50))
                .foregroundColor(.green)
            
            Text("Chat with Your Records")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Have natural conversations about your health data with AI. Ask questions, explore patterns, and gain insights from your medical records.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding(.bottom)
    }
    
    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.text.below.ecg")
                    .foregroundColor(.green)
                Text("Available Records")
                    .font(.headline)
                Spacer()
                Text("\(recordStore.records.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(8)
            }
            
            if recordStore.records.isEmpty {
                Text("No health records available. Go to the Records tab to add some documents or HealthKit data.")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let processedCount = recordStore.records.filter { $0.processed }.count
                    let unprocessedCount = recordStore.records.count - processedCount
                    
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(processedCount) processed records available for chat")
                        Spacer()
                    }
                    
                    if unprocessedCount > 0 {
                        HStack {
                            Image(systemName: "clock.circle")
                                .foregroundColor(.orange)
                            Text("\(unprocessedCount) unprocessed documents (will be included)")
                            Spacer()
                        }
                    }
                    
                    // Sample conversation starters
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Example questions you can ask:")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.top, 8)
                        
                        ForEach([
                            "What medications am I currently taking?",
                            "Show me trends in my recent lab results",
                            "What allergies are documented in my records?",
                            "Summarize my medical history",
                            "Are there any patterns in my symptoms?"
                        ], id: \.self) { question in
                            HStack {
                                Text("•")
                                    .foregroundColor(.green)
                                Text(question)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .font(.subheadline)
            }
            
            Button(action: generateMedicalText) {
                HStack {
                    Image(systemName: "doc.text.magnifyingglass")
                    Text("Preview Medical Summary")
                }
            }
            .buttonStyle(.bordered)
            .disabled(recordStore.records.isEmpty)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: startChatWithRecords) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                    }
                    Text(isLoading ? "Creating Chat Session..." : "Start Conversation")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(recordStore.records.isEmpty ? Color.gray : Color.green)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .disabled(recordStore.records.isEmpty || isLoading)
            
            if !generatedMedicalText.isEmpty {
                Button(action: { showingMedicalText = true }) {
                    HStack {
                        Image(systemName: "eye")
                        Text("View Full Medical Summary")
                    }
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    private var medicalTextPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Medical Summary Preview")
                .font(.headline)
            
            Text(String(generatedMedicalText.prefix(200)) + (generatedMedicalText.count > 200 ? "..." : ""))
                .font(.system(.caption, design: .monospaced))
                .padding()
                .background(Color(.systemGray6))
                .cornerRadius(8)
            
            Text("\(generatedMedicalText.count) characters total")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray5))
        .cornerRadius(12)
    }
    
    private func errorSection(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Error")
                    .font(.headline)
                    .foregroundColor(.red)
            }
            
            Text(error)
                .font(.body)
                .foregroundColor(.primary)
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(12)
    }
    
    // MARK: - Actions
    
    private func generateMedicalText() {
        logger.info("Generating medical text from \(recordStore.records.count) records")
        generatedMedicalText = clinicalTrialMatcher.convertRecordsToMedicalText(recordStore.records)
    }
    
    private func startChatWithRecords() {
        guard !recordStore.records.isEmpty else { return }
        
        Task {
            await performChatSessionCreation()
        }
    }
    
    @MainActor
    private func performChatSessionCreation() async {
        isLoading = true
        errorMessage = nil
        
        do {
            logger.info("Starting chat session creation process")
            
            // Generate medical text if not already done
            if generatedMedicalText.isEmpty {
                generateMedicalText()
            }
            
            // Create chat context
            let processedCount = recordStore.records.filter { $0.processed }.count
            let chatContext = ChatContext(
                patientName: "Patient", // Could be extracted from HealthKit data
                recordCount: processedCount,
                lastUpdated: recordStore.records.first?.date.formatted(date: .abbreviated, time: .omitted)
            )
            
            // Create session with chat service
            let sessionResponse = try await clinicalTrialMatcher.createChatSession(
                medicalRecord: generatedMedicalText,
                chatContext: chatContext
            )
            
            // Generate URL for the chat interface
            if let url = clinicalTrialMatcher.generateChatURL(sessionId: sessionResponse.sessionId) {
                logger.info("Opening chat interface at: \(url.absoluteString)")
                webViewURL = url
                showingWebView = true
            } else {
                errorMessage = "Failed to generate chat URL"
            }
            
        } catch {
            logger.error("Chat session creation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - Chat WebView Component

struct ChatWebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("ChatWebView failed to load: \(error.localizedDescription)")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("ChatWebView finished loading")
        }
    }
}