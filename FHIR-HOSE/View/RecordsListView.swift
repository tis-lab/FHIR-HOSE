//
//  RecordsListView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

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
        .overlay(alignment: .bottom) {
            if !recordStore.records.isEmpty {
                recordCountView
            }
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
}
