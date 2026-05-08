//
//  ClinicalTrialView.swift
//  FHIR-HOSE
//
//  Created by Claude on 6/8/25.
//

import SwiftUI
import WebKit
import OSLog

struct ClinicalTrialView: View {
    @ObservedObject var recordStore: HealthRecordStore
    @StateObject private var clinicalTrialMatcher = ClinicalTrialMatcher()
    @State private var showingWebView = false
    @State private var webViewURL: URL?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var nctNumber = ""
    @State private var generatedMedicalText = ""
    @State private var showingMedicalText = false
    
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "ClinicalTrialView")
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                recordsSection
                nctInputSection
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
        .navigationTitle("Clinical Trial Matcher")
        .sheet(isPresented: $showingWebView) {
            if let url = webViewURL {
                ClinicalTrialWebView(url: url)
            }
        }
        .sheet(isPresented: $showingMedicalText) {
            MedicalTextView(text: generatedMedicalText)
        }
    }
    
    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "stethoscope")
                .font(.system(size: 50))
                .foregroundColor(.blue)
            
            Text("Clinical Trial Matcher")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Match your health records against clinical trial eligibility criteria using AI-powered analysis.")
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
                Image(systemName: "doc.text")
                    .foregroundColor(.blue)
                Text("Available Records")
                    .font(.headline)
                Spacer()
                Text("\(recordStore.records.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.1))
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
                        Text("\(processedCount) processed records")
                        Spacer()
                    }
                    
                    if unprocessedCount > 0 {
                        HStack {
                            Image(systemName: "clock.circle")
                                .foregroundColor(.orange)
                            Text("\(unprocessedCount) unprocessed documents")
                            Spacer()
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
    
    private var nctInputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "number")
                    .foregroundColor(.blue)
                Text("NCT Number (Optional)")
                    .font(.headline)
            }
            
            TextField("e.g., NCT06038474", text: $nctNumber)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .autocapitalization(.allCharacters)
                .autocorrectionDisabled()
            
            Text("Enter a specific clinical trial NCT number, or leave blank to manually enter trial criteria.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: startClinicalTrialMatching) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "play.circle.fill")
                    }
                    Text(isLoading ? "Creating Session..." : "Start Clinical Trial Matching")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(recordStore.records.isEmpty ? Color.gray : Color.blue)
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
    
    private func startClinicalTrialMatching() {
        guard !recordStore.records.isEmpty else { return }
        
        Task {
            await performClinicalTrialMatching()
        }
    }
    
    @MainActor
    private func performClinicalTrialMatching() async {
        isLoading = true
        errorMessage = nil
        
        do {
            logger.info("Starting clinical trial matching process")
            
            // Generate medical text if not already done
            if generatedMedicalText.isEmpty {
                generateMedicalText()
            }
            
            // Create session with Charmonator
            let trimmedNCT = nctNumber.trimmingCharacters(in: .whitespacesAndNewlines)
            let nct = trimmedNCT.isEmpty ? nil : trimmedNCT
            
            let sessionResponse = try await clinicalTrialMatcher.createClinicalTrialSession(
                medicalRecord: generatedMedicalText,
                nctNumber: nct
            )
            
            // Generate URL for the web interface
            if let url = clinicalTrialMatcher.generateClinicalTrialURL(sessionId: sessionResponse.sessionId) {
                logger.info("Opening clinical trial matcher at: \(url.absoluteString)")
                webViewURL = url
                showingWebView = true
            } else {
                errorMessage = "Failed to generate clinical trial matcher URL"
            }
            
        } catch {
            logger.error("Clinical trial matching failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}

// MARK: - WebView Component

struct ClinicalTrialWebView: UIViewRepresentable {
    let url: URL
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
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
            print("WebView failed to load: \(error.localizedDescription)")
        }
    }
}

// MARK: - Medical Text View

struct MedicalTextView: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .padding()
            }
            .navigationTitle("Medical Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        UIPasteboard.general.string = text
                    }) {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}