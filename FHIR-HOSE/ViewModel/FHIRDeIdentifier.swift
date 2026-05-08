//
//  FHIRDeIdentifier.swift
//  FHIR-HOSE
//
//  Rule-based FHIR de-identification + optional Qwen-based de-ID (on-device).
//  Supports chunking: Bundles are de-identified per entry; oversized single resources use rule-based when Qwen would exceed token limits.
//

import Foundation
import os

/// Character/line/word counts (and optional token estimate) for size-based chunking decisions.
struct FHIRTextStats {
    var characters: Int
    var lines: Int
    var words: Int
    /// Rough token estimate (chars / 4) for context-window checks.
    var estimatedTokens: Int { max(1, characters / 4) }
}

private let deIDLogger = Logger(subsystem: "com.fhirhose", category: "FHIRDeIdentifier")

enum FHIRDeIdentifier {

    /// Above this character count we avoid sending a single resource to Qwen (use rule-based or per-entry for Bundles).
    private static let qwenMaxCharactersPerChunk = 12_000

    /// PHI-related keys to redact (values replaced with placeholder).
    /// Aligned with US Core Patient and common FHIR demographics: [US Core Patient](https://build.fhir.org/ig/HL7/US-Core/StructureDefinition-us-core-patient.html), [US Core IG](https://build.fhir.org/ig/HL7/US-Core/).
    private static let phiKeys: Set<String> = [
        "name", "birthDate", "identifier", "address", "telecom",
        "given", "family", "prefix", "suffix", "period",
        "line", "city", "state", "postalCode", "country", "district",
        "gender", "deceaseddatetime", "deceasedboolean", "photo", "contact", "communication",
        "maritalstatus", "language",
        "daterecorded", "recordeddate", "onsetdatetime", "performeddatetime", "occurrencedatetime"
    ]

    /// Keys that hold human-readable narrative we redact when at resource level (may contain PHI or location info).
    private static let narrativeKeys: Set<String> = ["div", "text", "notes"]

    /// FHIR keys whose value is a reference object (subject, patient, encounter, etc.) — redact "display" and "reference" inside them. Includes US Core Patient link.other, generalPractitioner, managingOrganization.
    private static let referenceKeys: Set<String> = [
        "subject", "patient", "performer", "actor", "author", "recorder", "source", "requester", "encounter",
        "asserter", "other", "generalpractitioner", "managingorganization"
    ]

    /// Extension URL substrings that indicate PHI (US Core race, ethnicity, tribal affiliation, sex; birthPlace). When present, redact value* and recurse into nested extension.
    private static let phiExtensionURLSubstrings: [String] = [
        "us-core-race", "us-core-ethnicity", "us-core-tribal-affiliation", "us-core-individual-sex",
        "birthplace", "birth-place"
    ]

    // MARK: - Size stats (for chunking)

    /// Returns character, line, and word counts for the given string (e.g. serialized JSON). Used to decide chunk boundaries and whether to use Qwen.
    static func textStats(for string: String) -> FHIRTextStats {
        let characters = string.count
        let lines = string.isEmpty ? 0 : string.components(separatedBy: .newlines).count
        let words = string.split(whereSeparator: { $0.isWhitespace }).count
        return FHIRTextStats(characters: characters, lines: lines, words: words)
    }

    /// Returns text stats for the FHIR payload (serialized to JSON). Use before de-ID to decide chunking.
    static func textStats(for fhir: [String: Any]) -> FHIRTextStats? {
        guard let data = jsonData(from: fhir), let str = String(data: data, encoding: .utf8) else { return nil }
        return textStats(for: str)
    }

    /// True if this FHIR dict is a Bundle with an `entry` array (chunk by entry).
    private static func isBundleWithEntries(_ fhir: [String: Any]) -> Bool {
        guard (fhir["resourceType"] as? String) == "Bundle" else { return false }
        guard let entries = fhir["entry"] as? [Any], !entries.isEmpty else { return false }
        return true
    }

    /// Prefix for de-identified resource and reference IDs so they remain usable for provenance/relationships but are not linkable to originals.
    private static let deIdIdPrefix = "de-id"

    /// Builds a mapping from original reference strings (e.g. "Patient/1") to de-identified references (e.g. "Patient/de-id-patient-1") by traversing the tree for resource ids and reference values. Same original ref always maps to the same new ref.
    private static func buildIdMapping(from value: Any) -> [String: String] {
        var refs = Set<String>()
        func collect(_ val: Any) {
            switch val {
            case let dict as [String: Any]:
                if let type = dict["resourceType"] as? String, let id = dict["id"] {
                    let idStr = String(describing: id)
                    if !idStr.isEmpty { refs.insert("\(type)/\(idStr)") }
                }
                for (k, v) in dict where referenceKeys.contains(k.lowercased()) {
                    if let ref = (v as? [String: Any])?["reference"] as? String, !ref.isEmpty {
                        refs.insert(ref)
                    }
                }
                if let fullUrl = dict["fullUrl"] as? String, fullUrl.contains("/"), !fullUrl.hasPrefix("urn:") {
                    refs.insert(fullUrl)
                }
                for (_, v) in dict { collect(v) }
            case let arr as [Any]: arr.forEach { collect($0) }
            default: break
            }
        }
        collect(value)
        var mapping: [String: String] = [:]
        for ref in refs {
            mapping[ref] = newReferenceFromReference(ref)
        }
        return mapping
    }

    /// Returns de-identified reference string: "Patient/1" → "Patient/de-id-patient-1"; full URLs like "http://example.org/Patient/1" → "http://example.org/Patient/de-id-patient-1". Preserves path after type/id for versioned refs.
    private static func newReferenceFromReference(_ ref: String) -> String {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return ref }
        let type: String
        let id: String
        let prefixCount: Int
        if ref.contains("://") {
            guard parts.count >= 2, !String(parts[parts.count - 2]).isEmpty, !String(parts[parts.count - 1]).isEmpty else { return ref }
            type = String(parts[parts.count - 2])
            id = String(parts[parts.count - 1])
            prefixCount = parts.count - 2
        } else {
            guard !String(parts[0]).isEmpty, !String(parts[1]).isEmpty else { return ref }
            type = String(parts[0])
            id = String(parts[1])
            prefixCount = 0
        }
        let newId = "\(deIdIdPrefix)-\(type.lowercased())-\(id)"
        if ref.contains("://"), prefixCount > 0 {
            let prefix = parts.prefix(prefixCount).map(String.init).joined(separator: "/")
            return prefix + "/" + type + "/" + newId
        }
        if parts.count > 2, prefixCount == 0 {
            return type + "/" + newId + "/" + parts.dropFirst(2).joined(separator: "/")
        }
        return type + "/" + newId
    }

    /// Returns only the new id part for a reference (e.g. "Patient/1" → "de-id-patient-1") for replacing resource.id.
    private static func newIdFromReference(_ ref: String) -> String {
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return ref }
        let type = String(parts[0])
        let id = String(parts[1])
        return "\(deIdIdPrefix)-\(type.lowercased())-\(id)"
    }

    /// Redacts common PHI in a FHIR-style dictionary. Returns a deep copy with PHI replaced.
    /// Resource and reference IDs are replaced with new stable IDs (e.g. Patient/1 → Patient/de-id-patient-1) so provenance and relationships are preserved. First collects PHI strings and builds ID mapping, then redacts structure and scrubs narrative.
    static func deidentify(_ fhir: [String: Any]) -> [String: Any] {
        var collected = Set<String>()
        collectPHIStrings(from: fhir, into: &collected)
        let idMapping = buildIdMapping(from: fhir)
        return redactValue(fhir, collectedPHI: collected, idMapping: idMapping) as? [String: Any] ?? [:]
    }

    /// Builds a new entry dict with `resource` replaced by the de-identified resource; preserves fullUrl, etc. Used by processBundleWithQwen.
    private static func entryWithReplacedResource(_ entry: [String: Any], resource deidentifiedResource: [String: Any]) -> [String: Any] {
        var out = entry
        out["resource"] = deidentifiedResource
        return out
    }

    private static let redactedPlaceholder = "[REDACTED]"

    /// Minimum length for a collected string to be used in narrative scrubbing (avoids replacing single chars).
    private static let minPHIStringLength = 2

    /// Collects all PHI string values from structured FHIR (names, addresses, dates, reference display/reference, etc.)
    /// so they can be found and replaced in narrative text (text, div, notes).
    private static func collectPHIStrings(from value: Any, into set: inout Set<String>) {
        func add(_ s: String?) {
            guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines),
                  s.count >= minPHIStringLength else { return }
            set.insert(s)
        }
        switch value {
        case let dict as [String: Any]:
            for (key, val) in dict {
                let keyLower = key.lowercased()
                if phiKeys.contains(keyLower) {
                    if let s = val as? String {
                        add(s)
                    } else if let arr = val as? [Any] {
                        for item in arr {
                            if let s = item as? String {
                                add(s)
                            } else if let obj = item as? [String: Any] {
                                if keyLower == "identifier" || keyLower == "telecom", let v = obj["value"] as? String {
                                    add(v)
                                }
                                collectPHIStrings(from: obj, into: &set)
                            } else {
                                collectPHIStrings(from: item, into: &set)
                            }
                        }
                    } else if let obj = val as? [String: Any] {
                        collectPHIStrings(from: obj, into: &set)
                    }
                } else if referenceKeys.contains(keyLower), let ref = val as? [String: Any] {
                    add(ref["display"] as? String)
                    add(ref["reference"] as? String)
                } else {
                    collectPHIStrings(from: val, into: &set)
                }
            }
        case let arr as [Any]:
            for item in arr { collectPHIStrings(from: item, into: &set) }
        default:
            break
        }
    }

    /// Replaces each occurrence of reference strings with de-identified refs (idMapping), then each PHI string with [REDACTED]. Longer strings first to avoid partial leaks.
    private static func redactNarrative(_ text: String, phiValues: Set<String>, idMapping: [String: String]? = nil) -> String {
        var result = text
        if let map = idMapping, !map.isEmpty {
            for (oldRef, newRef) in map.sorted(by: { $0.key.count > $1.key.count }) {
                result = result.replacingOccurrences(of: oldRef, with: newRef)
            }
        }
        guard !phiValues.isEmpty else { return result }
        for phi in phiValues.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: phi, with: redactedPlaceholder)
        }
        return result
    }

    private static func redactValue(_ value: Any, collectedPHI: Set<String>? = nil, idMapping: [String: String]? = nil) -> Any? {
        switch value {
        case let dict as [String: Any]:
            return redactDictionary(dict, collectedPHI: collectedPHI, idMapping: idMapping)
        case let arr as [Any]:
            return arr.compactMap { redactValue($0, collectedPHI: collectedPHI, idMapping: idMapping) }
        case is String, is Int, is Double, is Float, is Bool:
            return value
        default:
            return value
        }
    }

    private static func isPHIExtensionURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return phiExtensionURLSubstrings.contains { lower.contains($0) }
    }

    private static func redactDictionary(_ dict: [String: Any], collectedPHI: Set<String>? = nil, idMapping: [String: String]? = nil) -> [String: Any] {
        if let url = dict["url"] as? String, isPHIExtensionURL(url) {
            var out: [String: Any] = [:]
            for (key, val) in dict {
                let keyLower = key.lowercased()
                if keyLower == "url" {
                    out[key] = val
                } else if keyLower.hasPrefix("value") {
                    out[key] = redactedPlaceholder
                } else if let redacted = redactValue(val, collectedPHI: collectedPHI, idMapping: idMapping) {
                    out[key] = redacted
                } else {
                    out[key] = val
                }
            }
            return out
        }
        var out: [String: Any] = [:]
        for (key, val) in dict {
            let keyLower = key.lowercased()
            if keyLower == "id", dict["resourceType"] != nil, let type = dict["resourceType"] as? String, let idVal = dict["id"] {
                let idStr = String(describing: idVal)
                if !idStr.isEmpty {
                    out[key] = newIdFromReference("\(type)/\(idStr)")
                } else {
                    out[key] = val
                }
            } else if phiKeys.contains(keyLower) {
                if keyLower == "identifier" {
                    out[key] = [] as [[String: Any]]
                } else if keyLower == "name" || keyLower == "address" || keyLower == "telecom" {
                    out[key] = [[ "use": "anonymous", "text": redactedPlaceholder ]]
                } else if keyLower == "contact" || keyLower == "communication" || keyLower == "photo" {
                    out[key] = [] as [[String: Any]]
                } else {
                    out[key] = redactedPlaceholder
                }
            } else if narrativeKeys.contains(keyLower) {
                if let narrative = val as? String {
                    let phi = collectedPHI ?? []
                    let hasIdMapping = (idMapping?.isEmpty ?? true) == false
                    if !phi.isEmpty || hasIdMapping {
                        out[key] = redactNarrative(narrative, phiValues: phi, idMapping: idMapping)
                    } else if dict["resourceType"] != nil {
                        out[key] = redactedPlaceholder
                    } else {
                        out[key] = narrative
                    }
                } else if dict["resourceType"] != nil {
                    out[key] = redactedPlaceholder
                } else if let redacted = redactValue(val, collectedPHI: collectedPHI, idMapping: idMapping) {
                    out[key] = redacted
                } else {
                    out[key] = val
                }
            } else if referenceKeys.contains(keyLower), let refDict = val as? [String: Any] {
                out[key] = redactReferenceObject(refDict, idMapping: idMapping)
            } else if keyLower == "fullurl", let url = val as? String, let newUrl = idMapping?[url] {
                out[key] = newUrl
            } else {
                if let redacted = redactValue(val, collectedPHI: collectedPHI, idMapping: idMapping) {
                    out[key] = redacted
                } else {
                    out[key] = val
                }
            }
        }
        return out
    }

    /// Redacts display (→ [REDACTED]) and reference (→ de-identified ref) inside a FHIR reference object; preserves structure and provenance.
    private static func redactReferenceObject(_ dict: [String: Any], idMapping: [String: String]? = nil) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            let kLower = k.lowercased()
            if kLower == "display" {
                out[k] = redactedPlaceholder
            } else if kLower == "reference", let ref = v as? String, !ref.isEmpty {
                out[k] = idMapping?[ref] ?? newReferenceFromReference(ref)
            } else {
                if let redacted = redactValue(v, collectedPHI: nil, idMapping: idMapping) {
                    out[k] = redacted
                } else {
                    out[k] = v
                }
            }
        }
        return out
    }

    // MARK: - Qwen-based de-identification

    private static let deIDSystemPrompt = """
    You output JSON only. Rules: (1) Copy the input JSON exactly. (2) Keep every key at the same level—do not move resourceType, id, subject, patient, asserter, or anything inside another key. (3) Only replace these values with the string [REDACTED]: inside subject, patient, asserter, performer, encounter, author, other, generalPractitioner, managingOrganization replace "display" and "reference"; replace birthDate, dateRecorded, recordedDate, onsetDateTime, performedDateTime, gender, deceasedDateTime, deceasedBoolean; replace name, identifier, address, telecom, contact, communication, photo, maritalStatus; replace race/ethnicity/tribalAffiliation/sex extension values; replace address line, city, state, postalCode, country, district. (4) Do not add or remove top-level keys. Output the complete JSON. Example: "patient":{"display":"[REDACTED]","reference":"[REDACTED]"}.
    """

    /// Runs de-identification using Qwen. Completion receives (result, fallbackMessage): when fallbackMessage is non-nil, Qwen was not used or its output was rejected—UI should notify the user.
    static func deidentifyWithQwen(_ fhir: [String: Any], qwen: QwenInference, completion: @escaping ([String: Any], String?) -> Void) {
        if isBundleWithEntries(fhir) {
            processBundleWithQwen(fhir, qwen: qwen, completion: completion)
            return
        }
        guard let jsonData = jsonData(from: fhir),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            DispatchQueue.main.async { completion(deidentify(fhir), "Qwen was not used: could not serialize FHIR. Rule-based de-identification was used.") }
            return
        }
        let stats = textStats(for: jsonString)
        if stats.characters > qwenMaxCharactersPerChunk {
            deIDLogger.info("De-ID: oversized (\(stats.characters) chars), using rule-based")
            DispatchQueue.main.async { completion(deidentify(fhir), "Payload too large for Qwen. Rule-based de-identification was used.") }
            return
        }
        deIDLogger.info("De-ID: using Qwen (\(stats.characters) chars, ~\(stats.estimatedTokens) est tokens)")
        let systemPrompt = qwen.systemPrompt
        qwen.systemPrompt = deIDSystemPrompt
        let messages = [
            ChatMessage(role: "user", content: "Return the same JSON with only PHI replaced by [REDACTED]. Keep the exact structure—same top-level keys (resourceType, code, id, performedDateTime, status, subject). Do not nest them under code.\n\n\(jsonString)")
        ]
        qwen.generate(messages: messages) { fullResponse in
            qwen.systemPrompt = systemPrompt
            let parsed = parseJSONFromResponse(fullResponse)
            let valid = parsed.map { isValidDeidentifiedOutput(original: fhir, deidentified: $0) } ?? false
            if valid, let result = parsed {
                deIDLogger.info("De-ID: Qwen result accepted")
                completion(result, nil)
            } else {
                deIDLogger.info("De-ID: Qwen parse/validation failed, using rule-based")
                completion(deidentify(fhir), "Qwen's response was rejected (invalid, incomplete, or did not redact PHI). Rule-based de-identification was used instead.")
            }
        }
    }

    /// Processes a FHIR Bundle by de-identifying each entry's resource (Qwen if under size limit, else rule-based), then reassembles the Bundle and calls completion on the main queue. Uses bundle-wide PHI collection so narratives in any entry are scrubbed with PHI from the whole bundle.
    private static func processBundleWithQwen(_ fhir: [String: Any], qwen: QwenInference, completion: @escaping ([String: Any], String?) -> Void) {
        guard let entries = fhir["entry"] as? [[String: Any]] else {
            DispatchQueue.main.async { completion(deidentify(fhir), "Bundle has no entries. Rule-based de-identification was used.") }
            return
        }
        var bundleCollected = Set<String>()
        collectPHIStrings(from: fhir, into: &bundleCollected)
        let bundleIdMapping = buildIdMapping(from: fhir)
        var newEntries: [[String: Any]] = []
        var index = 0

        func ruleBasedResource(_ resource: [String: Any]) -> [String: Any] {
            (redactValue(resource, collectedPHI: bundleCollected, idMapping: bundleIdMapping) as? [String: Any]) ?? resource
        }

        func processNext() {
            if index >= entries.count {
                var out = fhir
                out["entry"] = newEntries
                DispatchQueue.main.async { completion(out, nil) }
                return
            }
            let entry = entries[index]
            let resource = entry["resource"] as? [String: Any]
            index += 1
            if resource == nil {
                newEntries.append(entry)
                processNext()
                return
            }
            guard let stats = FHIRDeIdentifier.textStats(for: resource!) else {
                deIDLogger.info("De-ID: Bundle entry stats unavailable, using rule-based")
                newEntries.append(entryWithReplacedResource(entry, resource: ruleBasedResource(resource!)))
                processNext()
                return
            }
            if stats.characters > qwenMaxCharactersPerChunk {
                deIDLogger.info("De-ID: Bundle entry oversized (\(stats.characters) chars), rule-based")
                newEntries.append(entryWithReplacedResource(entry, resource: ruleBasedResource(resource!)))
                processNext()
                return
            }
            deidentifyWithQwen(resource!, qwen: qwen) { result, _ in
                newEntries.append(entryWithReplacedResource(entry, resource: result))
                processNext()
            }
        }
        processNext()
    }

    private static func jsonData(from fhir: [String: Any]) -> Data? {
        let sanitized = makeJSONSerializableForQwen(fhir)
        return try? JSONSerialization.data(withJSONObject: sanitized, options: [.sortedKeys])
    }

    private static func makeJSONSerializableForQwen(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]:
            return Dictionary(uniqueKeysWithValues: d.map { ($0.key, makeJSONSerializableForQwen($0.value)) })
        case let a as [Any]:
            return a.map { makeJSONSerializableForQwen($0) }
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case is String, is Int, is Double, is Float, is Bool:
            return value
        default:
            return String(describing: value)
        }
    }

    /// Extracts a JSON object from model output (may be wrapped in ```json ... ```).
    private static func parseJSONFromResponse(_ response: String) -> [String: Any]? {
        var raw = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = raw.range(of: "```json"), let end = raw.range(of: "```", range: start.upperBound..<raw.endIndex) {
            raw = String(raw[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let start = raw.range(of: "```"), let end = raw.range(of: "```", range: start.upperBound..<raw.endIndex) {
            raw = String(raw[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    /// Reject Qwen output that mangled structure, is truncated, or did not actually redact PHI (e.g. returned a copy with references/dates unchanged).
    private static func isValidDeidentifiedOutput(original: [String: Any], deidentified: [String: Any]) -> Bool {
        guard let origResourceType = original["resourceType"] as? String else { return true }
        guard let outResourceType = deidentified["resourceType"] as? String, outResourceType == origResourceType else {
            return false
        }
        if deidentified.count == 1, deidentified["code"] != nil {
            return false
        }
        for refKey in ["subject", "patient", "asserter"] {
            if original[refKey] != nil && deidentified[refKey] == nil {
                return false
            }
            if let origRef = original[refKey] as? [String: Any], let outRef = deidentified[refKey] as? [String: Any] {
                let origDisplay = origRef["display"] as? String ?? ""
                let outDisplay = outRef["display"] as? String ?? ""
                let origRefVal = origRef["reference"] as? String ?? ""
                let outRefVal = outRef["reference"] as? String ?? ""
                if !origDisplay.isEmpty && outDisplay == origDisplay { return false }
                if !origRefVal.isEmpty && outRefVal == origRefVal { return false }
            }
        }
        if let origDate = original["dateRecorded"] as? String, let outDate = deidentified["dateRecorded"] as? String, origDate == outDate {
            return false
        }
        if let origOnset = original["onsetDateTime"] as? String, let outOnset = deidentified["onsetDateTime"] as? String, origOnset == outOnset {
            return false
        }
        return true
    }
}
