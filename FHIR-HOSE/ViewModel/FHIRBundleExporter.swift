//
//  FHIRBundleExporter.swift
//  FHIR-HOSE
//

import Foundation

/// Assembles every record's FHIR JSON into a single FHIR R4 `collection` Bundle,
/// suitable for handing to downstream consumers that expect a Bundle envelope.
///
/// - Charmonizer-produced records contribute their `fhirData` (a Patient resource).
/// - HealthKit-sourced records contribute the base64-encoded JSON stored under
///   `healthKitData["fhirResource"]`. When that payload is itself a Bundle, its
///   entries are flattened into the output Bundle.
enum FHIRBundleExporter {

    static func makeCollectionBundle(from records: [HealthRecord]) -> [String: Any] {
        var entries: [[String: Any]] = []

        for record in records {
            if let resource = record.fhirData {
                appendResource(resource, to: &entries)
                continue
            }

            if let b64 = record.healthKitData?["fhirResource"] as? String,
               !b64.isEmpty,
               let raw = Data(base64Encoded: b64),
               let resource = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                appendResource(resource, to: &entries)
            }
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        let bundle: [String: Any] = [
            "resourceType": "Bundle",
            "type": "collection",
            "timestamp": iso.string(from: Date()),
            "entry": entries
        ]
        return bundle
    }

    static func makeCollectionBundleData(from records: [HealthRecord]) throws -> Data {
        let bundle = makeCollectionBundle(from: records)
        return try JSONSerialization.data(
            withJSONObject: bundle,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func appendResource(_ resource: [String: Any], to entries: inout [[String: Any]]) {
        if (resource["resourceType"] as? String) == "Bundle",
           let inner = resource["entry"] as? [[String: Any]] {
            for innerEntry in inner {
                if let innerResource = innerEntry["resource"] as? [String: Any] {
                    entries.append(["resource": innerResource])
                }
            }
            return
        }

        entries.append(["resource": resource])
    }
}
