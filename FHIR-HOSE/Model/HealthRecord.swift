//
//  HealthRecord.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation
import HealthKit

struct HealthRecord: Identifiable, Hashable, Equatable {
    let id = UUID()
    let filename: String
    let type: RecordType
    var processed: Bool = false
    var date: Date = Date()

    /// NEW: We store the final FHIR data (if any) in a dictionary after processing.
    var fhirData: [String: Any]? = nil
    
    /// For HealthKit records, store the original data
    var healthKitData: [String: Any]? = nil
    var healthKitType: String? = nil

    enum RecordType {
        case pdf
        case image
        case healthKit
    }
    
    /// Convenience initializer for HealthKit records
    init(healthKitType: String, data: [String: Any], date: Date = Date()) {
        self.filename = "\(healthKitType)_\(date.timeIntervalSince1970)"
        self.type = .healthKit
        self.date = date
        self.healthKitData = data
        self.healthKitType = healthKitType
        self.processed = true // HealthKit data is already structured
    }
    
    /// Original initializer for document records
    init(filename: String, type: RecordType) {
        self.filename = filename
        self.type = type
    }

    static func == (lhs: HealthRecord, rhs: HealthRecord) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
