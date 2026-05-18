//
//  FHIRBundleExporter.swift
//  FHIR-HOSE
//

import Foundation

/// Assembles records' FHIR JSON into one or more FHIR `collection` Bundles,
/// bucketed by FHIR release so each output Bundle contains only one spec version.
///
/// - HealthKit-sourced records contribute the base64-encoded JSON stored under
///   `healthKitData["fhirResource"]`; release comes from `healthKitData["fhirRelease"]`
///   and the precise version string from `healthKitData["fhirVersion"]`.
/// - When a HealthKit payload is itself a Bundle, its entries are flattened into the
///   bucket for the wrapper's release.
/// - Charmonizer-produced records (`fhirData`) carry no version metadata and land in
///   the `"unknown"` bucket.
enum FHIRBundleExporter {

    /// A single per-release output ready to copy or write to disk.
    struct Export {
        /// `"dstu1"`, `"dstu2"`, `"stu3"`, `"r4"`, `"r4b"`, `"r5"`, or `"unknown"`.
        let release: String
        /// The assembled Bundle dictionary, with `meta.tag` entries for each precise
        /// FHIR version observed in the source records.
        let bundle: [String: Any]
        /// Convenience count of entries in this bundle.
        let entryCount: Int

        /// Short FHIR release name shown in UI (e.g. `"R4"`, `"R4B"`, `"DSTU2"`).
        var displayName: String {
            switch release {
            case "dstu1": return "DSTU1"
            case "dstu2": return "DSTU2"
            case "stu3":  return "STU3"
            case "r4":    return "R4"
            case "r4b":   return "R4B"
            case "r5":    return "R5"
            default:      return "Unknown"
            }
        }

        func data(prettyPrinted: Bool = true) throws -> Data {
            let options: JSONSerialization.WritingOptions = prettyPrinted
                ? [.prettyPrinted, .sortedKeys]
                : []
            return try JSONSerialization.data(withJSONObject: bundle, options: options)
        }
    }

    /// Per-release accumulator: the entries plus every distinct precise version
    /// string observed (e.g. `"4.0.1"`, `"4.0.2"` within an R4 bucket).
    private struct Bucket {
        var entries: [[String: Any]] = []
        var versions: Set<String> = []
    }

    /// Returns one `Export` per FHIR release present in `records`, ordered newest-first.
    /// Releases with zero entries are omitted.
    static func makeExports(from records: [HealthRecord]) -> [Export] {
        var buckets: [String: Bucket] = [:]

        for record in records {
            if let resource = record.fhirData {
                appendResource(resource, release: "unknown", version: nil, to: &buckets)
                continue
            }

            if let b64 = record.healthKitData?["fhirResource"] as? String,
               !b64.isEmpty,
               let raw = Data(base64Encoded: b64),
               let resource = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
                let release = (record.healthKitData?["fhirRelease"] as? String) ?? "unknown"
                let version = record.healthKitData?["fhirVersion"] as? String
                appendResource(resource, release: release, version: version, to: &buckets)
            }
        }

        let order = ["r5", "r4b", "r4", "stu3", "dstu2", "dstu1", "unknown"]
        return order.compactMap { release in
            guard let bucket = buckets[release], !bucket.entries.isEmpty else { return nil }
            return Export(
                release: release,
                bundle: makeBundle(release: release, bucket: bucket),
                entryCount: bucket.entries.count
            )
        }
    }

    private static func appendResource(
        _ resource: [String: Any],
        release: String,
        version: String?,
        to buckets: inout [String: Bucket]
    ) {
        var bucket = buckets[release] ?? Bucket()
        if let version, !version.isEmpty, version != "unknown" {
            bucket.versions.insert(version)
        }

        if (resource["resourceType"] as? String) == "Bundle",
           let inner = resource["entry"] as? [[String: Any]] {
            for innerEntry in inner {
                if let innerResource = innerEntry["resource"] as? [String: Any] {
                    bucket.entries.append(["resource": innerResource])
                }
            }
        } else {
            bucket.entries.append(["resource": resource])
        }

        buckets[release] = bucket
    }

    private static func makeBundle(release: String, bucket: Bucket) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var bundle: [String: Any] = [
            "resourceType": "Bundle",
            "type": "collection",
            "timestamp": iso.string(from: Date()),
            "entry": bucket.entries
        ]

        // Emit one meta.tag per distinct precise version observed in the source records.
        // Spec-correct, machine-readable, and survives mixed patch versions within a release.
        if !bucket.versions.isEmpty {
            let tags: [[String: String]] = bucket.versions.sorted().map { version in
                [
                    "system": "http://hl7.org/fhir/FHIR-version",
                    "code": version
                ]
            }
            bundle["meta"] = ["tag": tags]
        }
        return bundle
    }
}
