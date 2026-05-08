//
//  UndiagnosedDiseases.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 6/9/25.
//

import Foundation
import OSLog

class UndiagnosedDiseases: ObservableObject {
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "UndiagnosedDiseases")
    
    struct UDNSession {
        let sessionId: String
        let applicationUrl: String
        let createdAt: String
        let expiresAt: String
    }
    
    func createUDNSession(from records: [HealthRecord]) async throws -> UDNSession {
        logger.info("🧬 Creating UDN application session with \(records.count) records")
        
        // Convert records to medical text format
        let medicalText = convertRecordsToMedicalText(records)
        
        guard !medicalText.isEmpty else {
            throw NSError(domain: "UndiagnosedDiseases", code: 1001, userInfo: [
                NSLocalizedDescriptionKey: "No medical data available for UDN application"
            ])
        }
        
        // Get server configuration
        let serverConfig = ServerConfig.current()
        
        // Create request body
        let requestBody: [String: Any] = [
            "medicalRecord": medicalText,
            "patientContext": [
                "recordCount": records.count,
                "lastUpdated": ISO8601DateFormatter().string(from: Date()),
                "diagnosticJourney": "Comprehensive medical records for UDN application assessment"
            ]
        ]
        
        // Create URL for pre-populate endpoint
        let urlString = "\(serverConfig.serverBase)/charm/apps/undiagnosed-diseases/pre-populate"
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "UndiagnosedDiseases", code: 1003, userInfo: [
                NSLocalizedDescriptionKey: "Invalid server URL: \(urlString)"
            ])
        }
        
        logger.info("📡 Making request to: \(urlString)")
        
        // Create request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw NSError(domain: "UndiagnosedDiseases", code: 1004, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode request: \(error.localizedDescription)"
            ])
        }
        
        // Make request
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "UndiagnosedDiseases", code: 1005, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response type"
            ])
        }
        
        logger.info("📊 Received response with status: \(httpResponse.statusCode)")
        
        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "UndiagnosedDiseases", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Server error (\(httpResponse.statusCode)): \(errorMessage)"
            ])
        }
        
        // Parse response
        guard let responseJson = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = responseJson["sessionId"] as? String,
              let applicationUrl = responseJson["applicationUrl"] as? String,
              let metadata = responseJson["metadata"] as? [String: Any],
              let createdAt = metadata["createdAt"] as? String,
              let expiresAt = metadata["expiresAt"] as? String else {
            throw NSError(domain: "UndiagnosedDiseases", code: 1006, userInfo: [
                NSLocalizedDescriptionKey: "Invalid response format"
            ])
        }
        
        logger.info("✅ Successfully created UDN session: \(sessionId)")
        
        return UDNSession(
            sessionId: sessionId,
            applicationUrl: applicationUrl,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }
    
    private func convertRecordsToMedicalText(_ records: [HealthRecord]) -> String {
        var medicalText = "PATIENT MEDICAL RECORDS FOR UDN APPLICATION:\n\n"
        
        for (index, record) in records.enumerated() {
            medicalText += "=== RECORD \(index + 1): \(record.filename) ===\n"
            medicalText += "Type: \(getRecordTypeString(record.type))\n"
            medicalText += "Processed: \(record.processed ? "Yes" : "No")\n"
            medicalText += "Date Added: \(ISO8601DateFormatter().string(from: record.date))\n"
            
            if let healthKitType = record.healthKitType {
                medicalText += "HealthKit Type: \(healthKitType)\n"
            }
            
            // Add FHIR data if available
            if let fhirData = record.fhirData {
                medicalText += "\nFHIR DATA:\n"
                medicalText += formatDataForMedicalText(fhirData)
            }
            
            // Add HealthKit data if available
            if let healthKitData = record.healthKitData {
                medicalText += "\nHEALTHKIT DATA:\n"
                medicalText += formatDataForMedicalText(healthKitData)
            }
            
            medicalText += "\n" + String(repeating: "-", count: 50) + "\n\n"
        }
        
        return medicalText
    }
    
    private func formatDataForMedicalText(_ data: [String: Any]) -> String {
        var text = ""
        
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            text += "\(key): "
            
            if let dict = value as? [String: Any] {
                text += "\n"
                for (subKey, subValue) in dict.sorted(by: { $0.key < $1.key }) {
                    text += "  \(subKey): \(formatValue(subValue))\n"
                }
            } else if let array = value as? [Any] {
                text += "[\(array.count) items]\n"
                for (index, item) in array.enumerated() {
                    text += "  [\(index)]: \(formatValue(item))\n"
                }
            } else {
                text += "\(formatValue(value))\n"
            }
        }
        
        return text
    }
    
    private func getRecordTypeString(_ type: HealthRecord.RecordType) -> String {
        switch type {
        case .pdf:
            return "PDF"
        case .image:
            return "Image"
        case .healthKit:
            return "HealthKit"
        }
    }
    
    private func formatValue(_ value: Any) -> String {
        if let string = value as? String {
            // Decode base64 FHIR resources
            if string.count > 100 && Data(base64Encoded: string) != nil {
                if let data = Data(base64Encoded: string),
                   let decoded = String(data: data, encoding: .utf8) {
                    return "[FHIR Resource]: \(decoded.prefix(200))..."
                }
            }
            return string
        } else if let number = value as? NSNumber {
            return number.stringValue
        } else if let dict = value as? [String: Any] {
            return "[Dictionary with \(dict.count) keys]"
        } else if let array = value as? [Any] {
            return "[Array with \(array.count) items]"
        } else {
            return String(describing: value)
        }
    }
}