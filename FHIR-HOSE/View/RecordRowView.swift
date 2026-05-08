//
//  RecordRowView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI

struct RecordRowView: View {
    let record: HealthRecord
    
    var body: some View {
        HStack {
            Image(systemName: iconForRecordType(record.type))
                .foregroundColor(colorForRecordType(record.type))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(2)
                
                HStack {
                    Text(record.date, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if record.type == .healthKit, let healthKitType = record.healthKitType {
                        Text("• \(healthKitType)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            if record.processed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }
    
    private var displayName: String {
        switch record.type {
        case .pdf, .image:
            return record.filename
        case .healthKit:
            if let data = record.healthKitData,
               let displayName = data["displayName"] as? String {
                return displayName.replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
                    .replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
                    .replacingOccurrences(of: "HKClinicalTypeIdentifier", with: "")
                    .capitalized
            }
            return record.healthKitType?.capitalized ?? "HealthKit Record"
        }
    }
    
    private func iconForRecordType(_ type: HealthRecord.RecordType) -> String {
        switch type {
        case .pdf:
            return "doc.fill"
        case .image:
            return "photo.fill"
        case .healthKit:
            return "heart.fill"
        }
    }
    
    private func colorForRecordType(_ type: HealthRecord.RecordType) -> Color {
        switch type {
        case .pdf:
            return .blue
        case .image:
            return .green
        case .healthKit:
            return .red
        }
    }
}
