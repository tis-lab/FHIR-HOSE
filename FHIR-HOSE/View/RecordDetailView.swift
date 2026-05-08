//
//  RecordDetailView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordDetailView: View {
    let record: HealthRecord

    var body: some View {
        VStack {
            // Show either processed or unprocessed UI
            if record.processed {
                ProcessedRecordView(record: record)
            } else {
                UnprocessedRecordView()
            }
        }
        .navigationTitle(record.filename)
    }
}
