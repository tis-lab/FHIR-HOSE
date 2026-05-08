//
//  OutliveChecklistView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 6/9/25.
//

import SwiftUI
import WebKit
import OSLog

struct OutliveChecklistView: View {
    @StateObject private var outliveChecklist = OutliveChecklist()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var assessmentUrl: String?
    @State private var sessionId: String?
    
    let records: [HealthRecord]
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "OutliveChecklistView")
    
    var body: some View {
        Group {
            if let url = assessmentUrl, let sessionId = sessionId {
                WebView(url: url, sessionId: sessionId)
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("🧬 Preparing Outlive Assessment")
                        .font(.headline)
                    
                    Text("Analyzing your health records against Dr. Peter Attia's longevity checklist...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding()
            } else if let error = errorMessage {
                VStack(spacing: 20) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    
                    Text("Assessment Error")
                        .font(.headline)
                    
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Again") {
                        startAssessment()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                VStack(spacing: 30) {
                    VStack(spacing: 15) {
                        Image(systemName: "heart.text.square")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("Outlive Longevity Checklist")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text("Based on Dr. Peter Attia's comprehensive health assessment framework")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("This assessment will analyze your health records against:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Metabolic Health markers", systemImage: "waveform.path.ecg")
                            Label("Cardiovascular Risk factors", systemImage: "heart.circle")
                            Label("Cancer Screening compliance", systemImage: "scope")
                            Label("Neurodegeneration indicators", systemImage: "brain.head.profile")
                            Label("Physical Fitness metrics", systemImage: "figure.run")
                        }
                        .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    VStack(spacing: 10) {
                        Button("Start Assessment") {
                            startAssessment()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        
                        Text("Using \(records.count) health record\(records.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Outlive Checklist")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func startAssessment() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                logger.info("🧬 Starting Outlive assessment with \(records.count) records")
                
                let session = try await outliveChecklist.createOutliveSession(from: records)
                
                await MainActor.run {
                    self.assessmentUrl = session.assessmentUrl
                    self.sessionId = session.sessionId
                    self.isLoading = false
                }
                
                logger.info("✅ Assessment session created successfully: \(session.sessionId)")
                
            } catch {
                logger.error("❌ Failed to create assessment session: \(error.localizedDescription)")
                
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: String
    let sessionId: String
    
    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        if let url = URL(string: url) {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView
        private let logger = Logger(subsystem: "com.fhirhose.app", category: "WebView")
        
        init(_ parent: WebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            logger.info("🌐 Started loading Outlive assessment for session: \(self.parent.sessionId)")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("✅ Finished loading Outlive assessment")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("❌ Failed to load Outlive assessment: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationView {
        OutliveChecklistView(records: [])
    }
}