//
//  QwenInference.swift
//  FHIR-HOSE
//

import Foundation
import LlamaSwift
import os

private let logger = Logger(subsystem: "com.fhirhose", category: "QwenInference")

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    var content: String
}

class QwenInference: ObservableObject, @unchecked Sendable {
    @Published var isModelLoaded = false
    @Published var isGenerating = false
    @Published var currentResponse = ""
    @Published var statusMessage = "Model not loaded"

    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private var shouldStop = false
    var systemPrompt = "You are a helpful assistant."

    private let queue = DispatchQueue(label: "com.fhirhose.qwen", qos: .userInitiated)
    private static var backendInitialized = false

    init() {
        if !Self.backendInitialized {
            llama_backend_init()
            Self.backendInitialized = true
        }
    }

    func loadModel() {
        guard !isModelLoaded, model == nil else { return }
        statusMessage = "Loading model..."

        queue.async {
            guard let path = Bundle.main.path(forResource: "qwen3.5-0.8b-Q4_K_M", ofType: "gguf") else {
                DispatchQueue.main.async {
                    self.statusMessage = "Model not found in bundle. Drag qwen3.5-0.8b-Q4_K_M.gguf into Xcode and add to FHIR-HOSE target."
                }
                return
            }

            var modelParams = llama_model_default_params()
            #if targetEnvironment(simulator)
            modelParams.n_gpu_layers = 0
            #endif
            guard let model = llama_model_load_from_file(path, modelParams) else {
                DispatchQueue.main.async { self.statusMessage = "Failed to load model" }
                return
            }

            var ctxParams = llama_context_default_params()
            ctxParams.n_ctx = 8192
            ctxParams.n_batch = 8192

            guard let ctx = llama_init_from_model(model, ctxParams) else {
                llama_model_free(model)
                DispatchQueue.main.async { self.statusMessage = "Failed to create context" }
                return
            }

            self.model = model
            self.ctx = ctx

            DispatchQueue.main.async {
                self.isModelLoaded = true
                self.statusMessage = "Ready"
            }
        }
    }

    func generate(messages: [ChatMessage]) {
        guard isModelLoaded, !isGenerating else { return }

        shouldStop = false
        isGenerating = true
        currentResponse = ""

        let prompt = formatChatPrompt(messages: messages)

        logger.info("=== USER SENT MESSAGE ===")
        for msg in messages {
            logger.info("[\(msg.role)]: \(msg.content)")
        }
        logger.info("System prompt: \(self.systemPrompt.prefix(200))...")

        queue.async {
            guard let model = self.model, let ctx = self.ctx else {
                DispatchQueue.main.async { self.isGenerating = false }
                return
            }

            let vocab = llama_model_get_vocab(model)

            let maxTokens = prompt.utf8.count + 1
            var tokens = [llama_token](repeating: 0, count: maxTokens)
            let nTokens = Int(llama_tokenize(
                vocab, prompt, Int32(prompt.utf8.count),
                &tokens, Int32(maxTokens), true, true
            ))

            guard nTokens > 0 else {
                DispatchQueue.main.async {
                    self.currentResponse = "[Tokenization failed]"
                    self.isGenerating = false
                }
                return
            }

            let promptTokens = Array(tokens.prefix(nTokens))
            logger.info("Prompt tokenized: \(nTokens) tokens (context limit: 8192)")
            llama_memory_clear(llama_get_memory(ctx), true)

            var batch = llama_batch_init(8192, 0, 1)
            defer { llama_batch_free(batch) }

            batch.n_tokens = Int32(promptTokens.count)
            for i in 0..<promptTokens.count {
                batch.token[i] = promptTokens[i]
                batch.pos[i] = Int32(i)
                batch.n_seq_id[i] = 1
                if let seqIds = batch.seq_id, let seqId = seqIds[i] {
                    seqId[0] = 0
                }
                batch.logits[i] = (i == promptTokens.count - 1) ? 1 : 0
            }

            guard llama_decode(ctx, batch) == 0 else {
                DispatchQueue.main.async {
                    self.currentResponse = "[Prompt decode failed]"
                    self.isGenerating = false
                }
                return
            }

            var nCur = batch.n_tokens
            var responseBytes = Data()

            let maxGenTokens = min(max(8192 - nTokens, 256), 768)
            logger.info("Generation budget: \(maxGenTokens) tokens (capped at 768, thinking pre-filled)")
            var generatedCount = 0
            for _ in 0..<maxGenTokens {
                if self.shouldStop { break }

                guard let logits = llama_get_logits_ith(ctx, batch.n_tokens - 1) else { break }

                let vocabSize = Int(llama_vocab_n_tokens(vocab))
                var bestToken: llama_token = 0
                var bestLogit = logits[0]
                for j in 1..<vocabSize {
                    if logits[j] > bestLogit {
                        bestLogit = logits[j]
                        bestToken = llama_token(j)
                    }
                }

                generatedCount += 1
                if llama_vocab_is_eog(vocab, bestToken) {
                    logger.info("EOS reached after \(generatedCount) tokens")
                    break
                }

                var buf = [CChar](repeating: 0, count: 256)
                var len = llama_token_to_piece(vocab, bestToken, &buf, 256, 0, false)
                if len < 0 {
                    let needed = Int(-len)
                    buf = [CChar](repeating: 0, count: needed)
                    len = llama_token_to_piece(vocab, bestToken, &buf, Int32(needed), 0, false)
                }

                if len > 0 {
                    for k in 0..<Int(len) {
                        responseBytes.append(UInt8(bitPattern: buf[k]))
                    }

                    if let decoded = String(data: responseBytes, encoding: .utf8) {
                        let cleaned = self.cleanResponse(decoded)
                        let display = cleaned.isEmpty ? "Thinking..." : cleaned
                        DispatchQueue.main.async {
                            self.currentResponse = display
                        }
                    }
                }

                batch.n_tokens = 1
                batch.token[0] = bestToken
                batch.pos[0] = nCur
                batch.n_seq_id[0] = 1
                if let seqIds = batch.seq_id, let seqId = seqIds[0] {
                    seqId[0] = 0
                }
                batch.logits[0] = 1
                nCur += 1

                let decodeResult = llama_decode(ctx, batch)
                guard decodeResult == 0 else {
                    logger.error("Decode failed at token \(generatedCount), pos \(nCur), error: \(decodeResult)")
                    break
                }
            }

            logger.info("=== GENERATION COMPLETE ===")
            logger.info("Tokens generated: \(generatedCount) / \(maxGenTokens) max")
            let rawText = String(data: responseBytes, encoding: .utf8) ?? ""
            logger.info("Raw model output (\(rawText.count) chars): \(rawText.prefix(500))")
            let finalText = self.cleanResponse(rawText.isEmpty ? self.currentResponse : rawText)
            logger.info("Cleaned response (\(finalText.count) chars): \(finalText.prefix(500))")
            if finalText.isEmpty {
                logger.warning("Response is EMPTY after cleaning — model may have only produced <think> tags")
            }

            DispatchQueue.main.async {
                self.currentResponse = finalText
                self.isGenerating = false
            }
        }
    }

    func stopGeneration() {
        shouldStop = true
    }

    private func formatChatPrompt(messages: [ChatMessage]) -> String {
        var prompt = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n"
        for msg in messages {
            prompt += "<|im_start|>\(msg.role)\n\(msg.content)<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n<think>\n</think>\n"
        return prompt
    }

    private func cleanResponse(_ text: String) -> String {
        var result = text
        if let range = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.removeSubrange(range)
        }
        if let thinkStart = result.range(of: "<think>") {
            result.removeSubrange(thinkStart.lowerBound...)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        if let ctx { llama_free(ctx) }
        if let model { llama_model_free(model) }
    }
}
