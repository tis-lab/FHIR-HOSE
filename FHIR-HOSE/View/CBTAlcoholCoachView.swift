//
//  CBTAlcoholCoachView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 6/9/25.
//

import SwiftUI
import WebKit
import OSLog

struct CBTAlcoholCoachView: View {
    @StateObject private var cbtCoach = CBTAlcoholCoach()
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var applicationUrl: String?
    @State private var sessionId: String?
    @State private var showingUrgentDialog = false
    @State private var urgentContext = ""
    
    let records: [HealthRecord]
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "CBTAlcoholCoachView")
    
    var body: some View {
        Group {
            if let url = applicationUrl, let sessionId = sessionId {
                CBTWebView(url: url, sessionId: sessionId)
            } else if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    
                    Text("🧠 Starting CBT Session")
                        .font(.headline)
                    
                    Text("Preparing your personalized cognitive-behavioral therapy session...")
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
                    
                    Text("Session Error")
                        .font(.headline)
                    
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Try Again") {
                        startSession(sessionType: "long_term")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            } else {
                VStack(spacing: 30) {
                    VStack(spacing: 15) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 60))
                            .foregroundColor(.mint)
                        
                        Text("CBT Alcohol Recovery Coach")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text("AI-powered cognitive-behavioral therapy support for alcohol recovery")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("This coach provides:")
                            .font(.headline)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Evidence-based CBT techniques", systemImage: "brain")
                            Label("Craving management strategies", systemImage: "heart.circle")
                            Label("Relapse prevention skills", systemImage: "shield.checkered")
                            Label("24/7 urgent intervention support", systemImage: "phone.badge.plus")
                            Label("Structured practice exercises", systemImage: "list.clipboard")
                        }
                        .font(.subheadline)
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    VStack(spacing: 15) {
                        Text("⚠️ Important Disclaimer")
                            .font(.headline)
                            .foregroundColor(.red)
                        
                        Text("This AI coach supplements but does not replace professional treatment. For immediate crisis support, call 988 (Suicide & Crisis Lifeline) or 911.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                    .padding()
                    .background(Color(.systemRed).opacity(0.1))
                    .cornerRadius(12)
                    
                    VStack(spacing: 10) {
                        Button("🚨 Start Urgent Session") {
                            showingUrgentDialog = true
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.large)
                        
                        Button("📚 Start Structured Session") {
                            startSession(sessionType: "long_term")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.mint)
                        .controlSize(.large)
                        
                        Text("Using \(records.count) health record\(records.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("CBT Recovery Coach")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Urgent Session", isPresented: $showingUrgentDialog) {
            Button("Cancel", role: .cancel) { }
            Button("Start Session") {
                startSession(sessionType: "urgent", urgentContext: urgentContext.isEmpty ? "Experiencing craving or high-risk situation" : urgentContext)
            }
        } message: {
            VStack {
                Text("Are you experiencing a craving or high-risk situation? This will start an immediate intervention session.")
                
                // Note: SwiftUI alert doesn't support custom views, so we'll use a simple approach
                Text("Describe your situation briefly (optional):")
            }
        }
    }
    
    private func startSession(sessionType: String, urgentContext: String? = nil) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                logger.info("🧠 Starting CBT session with \(records.count) records (type: \(sessionType))")
                
                let session: CBTAlcoholCoach.CBTSession
                if sessionType == "urgent", let context = urgentContext {
                    session = try await cbtCoach.createUrgentSession(from: records, urgentContext: context)
                } else {
                    session = try await cbtCoach.createCBTSession(from: records, sessionType: sessionType)
                }
                
                await MainActor.run {
                    self.applicationUrl = session.applicationUrl
                    self.sessionId = session.sessionId
                    self.isLoading = false
                }
                
                logger.info("✅ CBT session created successfully: \(session.sessionId)")
                
            } catch {
                logger.error("❌ Failed to create CBT session: \(error.localizedDescription)")
                
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }
}

struct CBTWebView: UIViewRepresentable {
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
        let parent: CBTWebView
        private let logger = Logger(subsystem: "com.fhirhose.app", category: "CBTWebView")
        
        init(_ parent: CBTWebView) {
            self.parent = parent
        }
        
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            logger.info("🌐 Started loading CBT coaching session: \(self.parent.sessionId)")
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            logger.info("✅ Finished loading CBT coaching session")
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            logger.error("❌ Failed to load CBT coaching session: \(error.localizedDescription)")
        }
    }
}

#Preview {
    NavigationView {
        CBTAlcoholCoachView(records: [])
    }
}