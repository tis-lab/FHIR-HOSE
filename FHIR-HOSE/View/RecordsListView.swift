//
//  RecordsListView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RecordsListView: View {
    @ObservedObject var recordStore: HealthRecordStore
    @State private var searchText = ""

    @State private var exportURL: URL?
    @State private var exportErrorMessage: String?
    @State private var copyConfirmation: String?
    @State private var isExporting = false
    @State private var bannerDismissTask: Task<Void, Never>?

    private static let bannerVisibleDuration: Duration = .seconds(2.5)
    private static let bannerFadeDuration: Double = 0.35

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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(action: copyBundleToClipboard) {
                        Label("Copy FHIR Bundle to Clipboard", systemImage: "doc.on.doc")
                    }
                    Button(action: exportBundleToFile) {
                        Label("Save FHIR Bundle to File…", systemImage: "square.and.arrow.down")
                    }
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("Share \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        }
                    }
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(isExporting || recordStore.records.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 4) {
                if let copyConfirmation {
                    bannerText(copyConfirmation, color: .green)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if let exportErrorMessage {
                    bannerText(exportErrorMessage, color: .red)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if !recordStore.records.isEmpty {
                    recordCountView
                }
            }
            .animation(.easeOut(duration: Self.bannerFadeDuration), value: copyConfirmation)
            .animation(.easeOut(duration: Self.bannerFadeDuration), value: exportErrorMessage)
        }
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

    private var recordCountView: some View {
        Text("\(filteredRecords.count) records")
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(UIColor.systemBackground).opacity(0.8))
            .cornerRadius(8)
            .padding(.bottom, 8)
    }

    private func bannerText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color.opacity(0.9))
            .cornerRadius(8)
    }

    private func copyBundleToClipboard() {
        clearBanners()
        do {
            let data = try FHIRBundleExporter.makeCollectionBundleData(from: recordStore.records)
            guard let json = String(data: data, encoding: .utf8) else {
                showError("Could not encode bundle as UTF-8.")
                return
            }
            writeStringToClipboard(json)
            let kb = Double(data.count) / 1024.0
            showBanner(success: String(format: "Copied %.1f KB FHIR Bundle to clipboard.", kb))
        } catch {
            showError("Copy failed: \(error.localizedDescription)")
        }
    }

    private func exportBundleToFile() {
        isExporting = true
        clearBanners()
        let records = recordStore.records

        Task.detached(priority: .userInitiated) {
            do {
                let data = try FHIRBundleExporter.makeCollectionBundleData(from: records)
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("fhir-bundle-\(timestamp).json")
                try data.write(to: url, options: .atomic)

                await MainActor.run {
                    exportURL = url
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    isExporting = false
                    showError("Export failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func clearBanners() {
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        copyConfirmation = nil
        exportErrorMessage = nil
    }

    private func showBanner(success: String) {
        copyConfirmation = success
        exportErrorMessage = nil
        scheduleBannerDismiss()
    }

    private func showError(_ message: String) {
        exportErrorMessage = message
        copyConfirmation = nil
        scheduleBannerDismiss()
    }

    private func scheduleBannerDismiss() {
        bannerDismissTask?.cancel()
        bannerDismissTask = Task { @MainActor in
            try? await Task.sleep(for: Self.bannerVisibleDuration)
            guard !Task.isCancelled else { return }
            copyConfirmation = nil
            exportErrorMessage = nil
        }
    }

    private func writeStringToClipboard(_ string: String) {
        #if os(iOS) || os(visionOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}
