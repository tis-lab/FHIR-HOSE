//
//  LayoutLMv3Tokenizer.swift
//  FHIR-HOSE
//
//  Minimal tokenizer for LayoutLMv3: loads vocab from vocab.json (RoBERTa-style),
//  encodes word sequences to [CLS] + word tokens + [SEP] with bbox alignment.
//  For full BPE use the processor's tokenizer; this uses word-level lookup for on-device.
//

import Foundation

/// Word-level tokenizer for LayoutLMv3. Load vocab.json from the model bundle
/// (e.g. from HuggingFace nnul/layoutlmv3-finetuned-funsd or microsoft/layoutlmv3-base).
/// Encodes words to token IDs; subword tokens get the same bbox as the source word.
final class LayoutLMv3Tokenizer {
    private let vocab: [String: Int]
    private let clsId: Int32
    private let sepId: Int32
    private let padId: Int32
    private let unkId: Int32

    init(vocabURL: URL) throws {
        let data = try Data(contentsOf: vocabURL)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        guard let vocab = decoded else {
            throw NSError(domain: "LayoutLMv3", code: 1, userInfo: [NSLocalizedDescriptionKey: "vocab.json must be a JSON object mapping token strings to IDs"])
        }
        self.vocab = vocab
        // RoBERTa / LayoutLMv3 special tokens (typical keys)
        clsId = Int32(vocab["<s>"] ?? vocab["[CLS]"] ?? 0)
        sepId = Int32(vocab["</s>"] ?? vocab["[SEP]"] ?? 2)
        padId = Int32(vocab["<pad>"] ?? vocab["[PAD]"] ?? 1)
        unkId = Int32(vocab["<unk>"] ?? vocab["[UNK]"] ?? 3)
    }

    /// Encode a list of words (e.g. from OCR) to token IDs and per-token bboxes.
    /// Returns (inputIds, bboxes) both of length maxLength; bboxes are [x0,y0,x1,y1] in 0-1000.
    /// Word boxes should be in 0-1000, top-left origin.
    func encode(
        words: [String],
        boxes: [[Int32]],
        maxLength: Int
    ) -> (inputIds: [Int32], bboxes: [[Int32]]) {
        var inputIds: [Int32] = [clsId]
        var bboxes: [[Int32]] = [[0, 0, 0, 0]]

        for (word, box) in zip(words, boxes) {
            let tid = tokenId(for: word)
            inputIds.append(tid)
            bboxes.append(box)
            if inputIds.count >= maxLength - 1 { break }
        }
        inputIds.append(sepId)
        bboxes.append([0, 0, 0, 0])

        while inputIds.count < maxLength {
            inputIds.append(padId)
            bboxes.append([0, 0, 0, 0])
        }
        return (inputIds, bboxes)
    }

    private func tokenId(for word: String) -> Int32 {
        let w = word.trimmingCharacters(in: .whitespaces)
        if let id = vocab[w] { return Int32(id) }
        if let id = vocab[" " + w] { return Int32(id) }
        return unkId
    }

    var padTokenId: Int32 { padId }
}
