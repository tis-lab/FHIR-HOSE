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
    /// Returns (inputIds, bboxes, tokenToWordIndex). inputIds and bboxes have length maxLength.
    /// tokenToWordIndex[contentTokenIndex] = word index (0..<words.count) for that token; length = number of content tokens (between CLS and SEP).
    /// Word boxes should be in 0-1000, top-left origin.
    /// Unknown words are split into characters (RoBERTa vocab has many single-char entries) so the model gets a better signal than all UNK.
    func encode(
        words: [String],
        boxes: [[Int32]],
        maxLength: Int
    ) -> (inputIds: [Int32], bboxes: [[Int32]], tokenToWordIndex: [Int]) {
        var inputIds: [Int32] = [clsId]
        var bboxes: [[Int32]] = [[0, 0, 0, 0]]
        var tokenToWordIndex: [Int] = []

        for (wordIndex, (word, box)) in zip(words, boxes).enumerated() {
            let tids = tokenIds(for: word)
            for tid in tids {
                inputIds.append(tid)
                bboxes.append(box)
                tokenToWordIndex.append(wordIndex)
                if inputIds.count >= maxLength - 1 { break }
            }
            if inputIds.count >= maxLength - 1 { break }
        }
        inputIds.append(sepId)
        bboxes.append([0, 0, 0, 0])

        while inputIds.count < maxLength {
            inputIds.append(padId)
            bboxes.append([0, 0, 0, 0])
        }
        return (inputIds, bboxes, tokenToWordIndex)
    }

    /// One or more token IDs for a word: whole-word lookup, then space-prefixed, then Ġ-prefixed, then character-level fallback.
    private func tokenIds(for word: String) -> [Int32] {
        let w = word.trimmingCharacters(in: .whitespaces)
        if w.isEmpty { return [padId] }
        if let id = vocab[w] { return [Int32(id)] }
        if let id = vocab[" " + w] { return [Int32(id)] }
        if let id = vocab["\u{0120}" + w] { return [Int32(id)] }
        // Character-level fallback: RoBERTa vocab has many single-char entries; avoids feeding all UNK
        var ids: [Int32] = []
        for char in w {
            let s = String(char)
            if let id = vocab[s] { ids.append(Int32(id)) }
            else if let id = vocab["\u{0120}" + s] { ids.append(Int32(id)) }
            else { ids.append(unkId) }
        }
        return ids.isEmpty ? [unkId] : ids
    }

    var padTokenId: Int32 { padId }
}
