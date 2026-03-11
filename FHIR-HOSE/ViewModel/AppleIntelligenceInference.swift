//
//  AppleIntelligenceInference.swift
//  FHIR-HOSE
//

import Foundation
import FoundationModels
import os

private let logger = Logger(subsystem: "com.fhirhose", category: "AppleIntelligence")

@available(iOS 26, macOS 26, visionOS 26, *)
@MainActor
class AppleIntelligenceInference: ObservableObject {
    @Published var isModelAvailable = false
    @Published var isGenerating = false
    @Published var currentResponse = ""
    @Published var statusMessage = "Checking availability..."
    @Published var isWaitingForDownload = false

    private var session: LanguageModelSession?
    private var generationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    var systemPrompt: String = "You are a helpful assistant." {
        didSet { resetSession() }
    }

    func checkAvailability() {
        pollingTask?.cancel()
        pollingTask = nil

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            isModelAvailable = true
            isWaitingForDownload = false
            statusMessage = "Ready"
            createSession()
        case .unavailable(.deviceNotEligible):
            isModelAvailable = false
            isWaitingForDownload = false
            statusMessage = "This device doesn't support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            isModelAvailable = false
            isWaitingForDownload = false
            statusMessage = "Please enable Apple Intelligence in Settings"
        case .unavailable(.modelNotReady):
            isModelAvailable = false
            isWaitingForDownload = true
            statusMessage = "Apple Intelligence model is downloading…"
            startPollingForAvailability()
        case .unavailable(_):
            isModelAvailable = false
            isWaitingForDownload = false
            statusMessage = "Apple Intelligence is unavailable"
        @unknown default:
            isModelAvailable = false
            isWaitingForDownload = false
            statusMessage = "Unable to check model availability"
        }

        if !isModelAvailable {
            logger.warning("Model unavailable: \(self.statusMessage)")
        }
    }

    private func startPollingForAvailability() {
        pollingTask?.cancel()
        pollingTask = Task {
            var elapsed = 0
            while !Task.isCancelled && !isModelAvailable {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }

                elapsed += 5
                let model = SystemLanguageModel.default
                if case .available = model.availability {
                    logger.info("Model became available after ~\(elapsed)s of polling")
                    isModelAvailable = true
                    isWaitingForDownload = false
                    statusMessage = "Ready"
                    createSession()
                    return
                }

                let mins = elapsed / 60
                let secs = elapsed % 60
                if mins > 0 {
                    statusMessage = "Apple Intelligence model is downloading… (\(mins)m \(secs)s)"
                } else {
                    statusMessage = "Apple Intelligence model is downloading… (\(secs)s)"
                }
            }
        }
    }

    private func createSession() {
        session = LanguageModelSession(instructions: systemPrompt)
        logger.info("Session created (\(self.systemPrompt.count) chars of instructions)")
    }

    func resetSession() {
        generationTask?.cancel()
        isGenerating = false
        session = nil
        if isModelAvailable {
            createSession()
        }
    }

    func generate(userMessage: String) {
        guard isModelAvailable, !isGenerating, let session else { return }

        logger.info("=== USER SENT MESSAGE ===")
        logger.info("[user]: \(userMessage)")
        logger.info("Instructions prefix: \(self.systemPrompt.prefix(200))...")

        isGenerating = true
        currentResponse = ""

        generationTask = Task {
            do {
                let stream = session.streamResponse(to: userMessage)
                for try await partial in stream {
                    self.currentResponse = partial.content
                }
                logger.info("=== GENERATION COMPLETE ===")
                logger.info("Response (\(self.currentResponse.count) chars): \(self.currentResponse.prefix(500))")
            } catch is CancellationError {
                logger.info("Generation cancelled by user")
            } catch {
                logger.error("Generation error: \(error)")
                let desc = error.localizedDescription
                if desc.contains("contextWindow") || desc.contains("ContextWindow") {
                    self.currentResponse = "The conversation got too long. Please start a new chat."
                    self.resetSession()
                } else if self.currentResponse.isEmpty {
                    self.currentResponse = "[Error: \(desc)]"
                }
            }
            self.isGenerating = false
        }
    }

    func stopGeneration() {
        generationTask?.cancel()
    }
}
