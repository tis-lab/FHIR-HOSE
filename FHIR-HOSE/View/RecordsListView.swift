//
//  RecordsListView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RecordsListView: View {
    @ObservedObject var recordStore: HealthRecordStore
    @State private var searchText = ""

    var body: some View {
        Group {
            if recordStore.isLoadingHealthKitData && recordStore.records.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Loading health records...")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if recordStore.isLoadingHealthKitData {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading additional health records...")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .padding(.vertical, 8)
                    }

                    ForEach(filteredRecords) { record in
                        NavigationLink(destination: RecordDetailView(record: record)) {
                            RecordRowView(record: record)
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .searchable(text: $searchText, prompt: "Search records...")
                .refreshable {
                    recordStore.loadHealthKitRecords()
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !recordStore.records.isEmpty {
                bottomActionBar
            }
        }
    }

    private var bottomActionBar: some View {
        shareControl
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var shareControl: some View {
        let exports = FHIRBundleExporter.makeExports(from: recordStore.records)

        if exports.count == 1 {
            // Single release: skip the menu — one tap goes straight to the share sheet.
            ShareLink(
                item: BundleFile(export: exports[0]),
                preview: SharePreview("\(exports[0].displayName) FHIR Bundle")
            ) {
                shareButtonLabel("Export Health Data")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        } else if exports.count > 1 {
            Menu {
                ForEach(exports, id: \.release) { export in
                    ShareLink(
                        item: BundleFile(export: export),
                        preview: SharePreview("\(export.displayName) FHIR Bundle")
                    ) {
                        Label(
                            "\(export.displayName) (\(export.entryCount) records)",
                            systemImage: "doc.text"
                        )
                    }
                }
                Divider()
                ShareLink(
                    item: BundlesZipFile(exports: exports),
                    preview: SharePreview("FHIR Bundles ZIP")
                ) {
                    Label("All as ZIP", systemImage: "doc.zipper")
                }
            } label: {
                shareButtonLabel("Export Health Data")
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func shareButtonLabel(_ title: String) -> some View {
        Label(title, systemImage: "square.and.arrow.up")
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
    }

    private var filteredRecords: [HealthRecord] {
        if searchText.isEmpty {
            return recordStore.records
        } else {
            return recordStore.records.filter { record in
                record.filename.localizedCaseInsensitiveContains(searchText) ||
                record.healthKitType?.localizedCaseInsensitiveContains(searchText) == true ||
                (record.healthKitData?["displayName"] as? String)?.localizedCaseInsensitiveContains(searchText) == true
            }
        }
    }
}

// MARK: - Transferable share items

/// A single FHIR Bundle file produced on-demand for `ShareLink`. The JSON is only
/// serialized and written to `tmp/` when the share sheet actually requests it.
private struct BundleFile: Transferable {
    let export: FHIRBundleExporter.Export

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let data = try file.export.data()
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fhir-bundle-\(file.export.release)-\(timestamp).json")
            try data.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

/// A zip of one-or-more FHIR Bundles, generated on-demand for `ShareLink`.
private struct BundlesZipFile: Transferable {
    let exports: [FHIRBundleExporter.Export]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { file in
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let entries: [ZipEncoder.File] = try file.exports.map { export in
                ZipEncoder.File(
                    name: "fhir-bundle-\(export.release)-\(timestamp).json",
                    data: try export.data()
                )
            }
            let archive = ZipEncoder.makeArchive(files: entries)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("fhir-bundles-\(timestamp).zip")
            try archive.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}
