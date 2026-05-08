//
//  SentencePieceTokenizer.swift
//  FHIR-HOSE
//

import Foundation
import OSLog

/// Minimal SentencePiece unigram tokenizer that reads a `.model` protobuf
/// and performs Viterbi-optimal encoding / concatenation-based decoding.
final class SentencePieceTokenizer {

    // MARK: - Internal types

    private struct Piece {
        let text: String
        let score: Float
        let type: Int // 1=NORMAL 2=UNKNOWN 3=CONTROL 4=USER_DEFINED 5=UNUSED 6=BYTE
    }

    private final class TrieNode {
        var children: [Character: TrieNode] = [:]
        var pieceId: Int?
        var score: Float?
    }

    // MARK: - Properties

    private let pieces: [Piece]
    private let root: TrieNode
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "SentencePiece")

    let vocabSize: Int
    let padId: Int32 = 0
    let eosId: Int32 = 1
    let unkId: Int32 = 2

    // MARK: - Init

    init(modelURL: URL) throws {
        let data = try Data(contentsOf: modelURL)
        let parsed = try Self.parseProto(data)
        self.pieces = parsed
        self.vocabSize = parsed.count

        let trie = TrieNode()
        for (i, p) in parsed.enumerated() {
            guard p.type == 1 || p.type == 4 || p.type == 6 else { continue }
            var node = trie
            for ch in p.text {
                if node.children[ch] == nil {
                    node.children[ch] = TrieNode()
                }
                node = node.children[ch]!
            }
            node.pieceId = i
            node.score = p.score
        }
        self.root = trie
        logger.info("SentencePiece loaded: \(parsed.count) pieces")
    }

    // MARK: - Encode (Viterbi)

    /// Tokenize `text` into an array of token IDs using Viterbi-optimal segmentation.
    func encode(_ text: String) -> [Int32] {
        guard !text.isEmpty else { return [] }
        let normalized = "\u{2581}" + text.replacingOccurrences(of: " ", with: "\u{2581}")
        let chars = Array(normalized)
        let n = chars.count

        var best = [Float](repeating: -.infinity, count: n + 1)
        var prev = [Int](repeating: -1, count: n + 1)
        var pieceAt = [Int](repeating: Int(unkId), count: n + 1)
        best[0] = 0

        for i in 0..<n {
            guard best[i] > -.infinity else { continue }
            var node = root
            for j in i..<n {
                guard let next = node.children[chars[j]] else { break }
                node = next
                if let id = node.pieceId, let sc = node.score {
                    let candidate = best[i] + sc
                    if candidate > best[j + 1] {
                        best[j + 1] = candidate
                        prev[j + 1] = i
                        pieceAt[j + 1] = id
                    }
                }
            }
            if best[i + 1] <= -.infinity {
                best[i + 1] = best[i] - 100
                prev[i + 1] = i
                pieceAt[i + 1] = Int(unkId)
            }
        }

        var ids: [Int32] = []
        var pos = n
        while pos > 0 {
            ids.append(Int32(pieceAt[pos]))
            pos = prev[pos]
        }
        ids.reverse()
        return ids
    }

    // MARK: - Decode

    /// Convert a sequence of token IDs back to a string.
    func decode(_ ids: [Int32]) -> String {
        var text = ""
        for id in ids {
            let idx = Int(id)
            if idx == Int(eosId) { break }
            if idx == Int(padId) { continue }
            guard idx >= 0 && idx < pieces.count else { continue }
            text += pieces[idx].text
        }
        return text
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Human-readable piece text for a given token ID (for debug logging).
    func pieceName(for id: Int32) -> String {
        let idx = Int(id)
        guard idx >= 0 && idx < pieces.count else { return "<\(id)?>" }
        return pieces[idx].text
    }

    // MARK: - Protobuf Parser

    /// Parse a SentencePiece ModelProto binary into an ordered list of pieces.
    /// Only extracts field 1 (repeated SentencePiece) with sub-fields
    /// piece(1/string), score(2/float), type(3/varint).
    private static func parseProto(_ data: Data) throws -> [Piece] {
        let bytes = [UInt8](data)
        var pieces: [Piece] = []
        var off = 0

        while off < bytes.count {
            let (tag, o1) = varint(bytes, off); off = o1
            let field = tag >> 3
            let wire = tag & 7

            if field == 1 && wire == 2 {
                let (len, o2) = varint(bytes, off); off = o2
                let end = off + Int(len)

                var text = ""
                var score: Float = 0
                var type = 1
                var s = off

                while s < end {
                    let (st, so) = varint(bytes, s); s = so
                    let sf = st >> 3
                    let sw = st & 7

                    if sf == 1 && sw == 2 {
                        let (sl, slo) = varint(bytes, s); s = slo
                        let upper = min(s + Int(sl), bytes.count)
                        text = String(bytes: Array(bytes[s..<upper]), encoding: .utf8) ?? ""
                        s = upper
                    } else if sf == 2 && sw == 5 {
                        guard s + 4 <= bytes.count else { s = end; continue }
                        score = Array(bytes[s..<s + 4]).withUnsafeBufferPointer {
                            $0.baseAddress!.withMemoryRebound(to: Float.self, capacity: 1) { $0.pointee }
                        }
                        s += 4
                    } else if sf == 3 && sw == 0 {
                        let (tv, to) = varint(bytes, s)
                        type = Int(tv)
                        s = to
                    } else {
                        s = skip(bytes, s, Int(sw))
                    }
                }
                pieces.append(Piece(text: text, score: score, type: type))
                off = end
            } else {
                off = skip(bytes, off, Int(wire))
            }
        }
        return pieces
    }

    private static func varint(_ b: [UInt8], _ o: Int) -> (UInt64, Int) {
        var r: UInt64 = 0
        var sh: UInt64 = 0
        var p = o
        repeat {
            guard p < b.count else { break }
            let byte = UInt64(b[p])
            r |= (byte & 0x7F) << sh
            p += 1
            if byte & 0x80 == 0 { break }
            sh += 7
        } while true
        return (r, p)
    }

    private static func skip(_ b: [UInt8], _ o: Int, _ w: Int) -> Int {
        switch w {
        case 0: return varint(b, o).1
        case 1: return o + 8
        case 2: let (l, o2) = varint(b, o); return o2 + Int(l)
        case 5: return o + 4
        default: return o + 1
        }
    }
}
