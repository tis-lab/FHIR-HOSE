//
//  UndiagnosedDiseasesView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 6/9/25.
//

import SwiftUI
import WebKit
import OSLog

struct UndiagnosedDiseasesView: View {
    @StateObject private var undiagnosedDiseases = UndiagnosedDiseases()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var applicationUrl: String?
    @State private var sessionId: String?
    
    let records: [HealthRecord]
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "UndiagnosedDiseasesView")
    
    var body: some View {
        Group {
            if let url = applicationUrl, let sessionId = sessionId {
                UDNWebView(url: url, sessionId: sessionId)
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("🧬 Preparing UDN Application")
                        .font(.headline)
                    
                    Text("Analyzing your medical records for Undiagnosed Diseases Network application...")
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
                    
                    Text("Application Error")
                        .font(.headline)
                    
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Again") {
                        startApplication()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                VStack(spacing: 30) {
                    VStack(spacing: 15) {
                        Image(systemName: "cross.case")
                            .font(.system(size: 60))
                            .foregroundColor(.purple)
                        
                        Text("Undiagnosed Diseases Network")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text("AI-powered application assistance for the NIH Undiagnosed Diseases Network")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("This application will help you:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Analyze your complete medical history", systemImage: "doc.text.magnifyingglass")
                            Label("Identify diagnostic patterns and gaps", systemImage: "puzzlepiece")
                            Label("Prepare structured UDN application materials", systemImage: "list.clipboard")
                            Label("Organize your diagnostic journey timeline", systemImage: "clock.arrow.circlepath")
                            Label("Format clinical phenotyping data", systemImage: "chart.bar.doc.horizontal")
                        }
                        .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    VStack(spacing: 15) {
                        Text("About the UDN")
                            .font(.headline)
                        
                        Text("The Undiagnosed Diseases Network is a research study funded by the NIH that brings together clinical and research experts to solve challenging medical mysteries for patients with conditions that have defied diagnosis.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                    .background(Color(.systemBlue).opacity(0.1))
                    .cornerRadius(12)
                    
                    VStack(spacing: 10) {
                        Button("Start UDN Application") {
                            startApplication()
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
        .navigationTitle("UDN Application")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func startApplication() {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                logger.info("🧬 Starting UDN application with \(records.count) records")
                
                let session = try await undiagnosedDiseases.createUDNSession(from: records)
                
                await MainActor.run {
                    self.applicationUrl = session.applicationUrl
                    self.sessionId = session.sessionId
                    self.isLoading = false
                }
                
                logger.info("✅ UDN application session created successfully: \(session.sessionId)")
                
            } catch {
                logger.error("❌ Failed to create UDN application session: \(error.localizedDescription)")
                
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct UDNWebView: UIViewRepresentable {
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
        let parent: UDNWebView
        private let logger = Logger(subsystem: "com.fhirhose.app", category: "UDNWebView")
        
        init(_ parent: UDNWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            logger.info("🌐 Started loading UDN application for session: \(self.parent.sessionId)")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("✅ Finished loading UDN application")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("❌ Failed to load UDN application: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationView {
        UndiagnosedDiseasesView(records: [])
    }
}