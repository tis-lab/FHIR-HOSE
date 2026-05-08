//
//  ClinicalTrialMatcher.swift
//  FHIR-HOSE
//
//  Created by Claude on 6/8/25.
//

import Foundation
import OSLog

class ClinicalTrialMatcher: ObservableObject {
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "ClinicalTrialMatcher")
    
    /// Convert health records to a consolidated medical record text
    func convertRecordsToMedicalText(_ records: [HealthRecord]) -> String {
        logger.info("Converting \(records.count) health records to medical text")
        
        var medicalText = "PATIENT MEDICAL RECORD\n"
        medicalText += "Generated: \(Date().formatted(date: .complete, time: .standard))\n"
        medicalText += String(repeating: "=", count: 50) + "\n\n"
        
        let processedRecords = records.filter { $0.processed }
        let unprocessedRecords = records.filter { !$0.processed }
        
        logger.info("Processed records: \(processedRecords.count), Unprocessed: \(unprocessedRecords.count)")
        
        // Add processed records with FHIR or HealthKit data
        if !processedRecords.isEmpty {
            medicalText += "PROCESSED HEALTH DATA:\n"
            medicalText += String(repeating: "-", count: 30) + "\n\n"
            
            for record in processedRecords {
                medicalText += "Record: \(record.filename)\n"
                medicalText += "Date: \(record.date.formatted(date: .abbreviated, time: .omitted))\n"
                medicalText += "Type: \(formatRecordType(record.type))\n"
                
                if let fhirData = record.fhirData {
                    medicalText += "FHIR Data:\n"
                    medicalText += formatDataAsText(fhirData, indent: "  ")
                } else if let healthKitData = record.healthKitData {
                    medicalText += "HealthKit Data (\(record.healthKitType ?? "Unknown")):\n"
                    medicalText += formatDataAsText(healthKitData, indent: "  ")
                }
                
                medicalText += "\n" + String(repeating: "-", count: 20) + "\n\n"
            }
        }
        
        // Add unprocessed records metadata
        if !unprocessedRecords.isEmpty {
            medicalText += "UNPROCESSED DOCUMENTS:\n"
            medicalText += String(repeating: "-", count: 30) + "\n"
            for record in unprocessedRecords {
                medicalText += "• \(record.filename) (\(formatRecordType(record.type))) - \(record.date.formatted(date: .abbreviated, time: .omitted))\n"
            }
            medicalText += "\nNote: These documents are available but have not been processed into structured data.\n\n"
        }
        
        logger.info("Generated medical text with \(medicalText.count) characters")
        return medicalText
    }
    
    /// Create a session with Charmonator for clinical trial matching
    func createClinicalTrialSession(medicalRecord: String, nctNumber: String? = nil) async throws -> ClinicalTrialSessionResponse {
        logger.info("Creating clinical trial session for NCT: \(nctNumber ?? "manual entry")")
        
        let config = ServerConfig.current()
        let baseURL = config.serverBase
        
        // Use the clinical trial matcher app's pre-populate endpoint
        guard let url = URL(string: "\(baseURL)/charm/apps/clinical-trial-matcher/pre-populate") else {
            throw ClinicalTrialError.invalidURL
        }
        
        var requestBody: [String: Any] = [
            "medicalRecord": medicalRecord
        ]
        
        if let nct = nctNumber {
            requestBody["nctNumber"] = nct
        }
        
        logger.info("Sending request to: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClinicalTrialError.invalidResponse
        }
        
        logger.info("Received response with status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            let sessionResponse = try JSONDecoder().decode(ClinicalTrialSessionResponse.self, from: data)
            logger.info("Successfully created session: \(sessionResponse.sessionId)")
            return sessionResponse
        } else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Failed to create session: \(errorMessage)")
            throw ClinicalTrialError.serverError(errorMessage)
        }
    }
    
    /// Generate the clinical trial matcher URL for localhost
    func generateClinicalTrialURL(sessionId: String) -> URL? {
        let config = ServerConfig.current()
        let baseURL = config.serverBase
        
        // Use the charm base URL with apps path
        let urlString = "\(baseURL)/charm/apps/clinical-trial-matcher/clinical-trial-matcher.html?session=\(sessionId)"
        
        logger.info("Generated clinical trial URL: \(urlString)")
        return URL(string: urlString)
    }
    
    /// Create a chat session with medical records for conversational AI
    func createChatSession(medicalRecord: String, chatContext: ChatContext? = nil) async throws -> ChatSessionResponse {
        logger.info("Creating chat session with medical records")
        
        let config = ServerConfig.current()
        let baseURL = config.serverBase
        
        // Use the chat-with-records app's pre-populate endpoint
        guard let url = URL(string: "\(baseURL)/charm/apps/chat-with-records/pre-populate") else {
            throw ClinicalTrialError.invalidURL
        }
        
        var requestBody: [String: Any] = [
            "medicalRecord": medicalRecord
        ]
        
        if let context = chatContext {
            var contextDict: [String: Any] = [:]
            if let patientName = context.patientName {
                contextDict["patientName"] = patientName
            }
            if let recordCount = context.recordCount {
                contextDict["recordCount"] = recordCount
            }
            if let lastUpdated = context.lastUpdated {
                contextDict["lastUpdated"] = lastUpdated
            }
            requestBody["chatContext"] = contextDict
        }
        
        logger.info("Sending chat session request to: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClinicalTrialError.invalidResponse
        }
        
        logger.info("Received chat session response with status: \(httpResponse.statusCode)")
        
        if httpResponse.statusCode == 200 {
            let sessionResponse = try JSONDecoder().decode(ChatSessionResponse.self, from: data)
            logger.info("Successfully created chat session: \(sessionResponse.sessionId)")
            return sessionResponse
        } else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            logger.error("Failed to create chat session: \(errorMessage)")
            throw ClinicalTrialError.serverError(errorMessage)
        }
    }
    
    /// Generate the chat with records URL for localhost
    func generateChatURL(sessionId: String) -> URL? {
        let config = ServerConfig.current()
        let baseURL = config.serverBase
        
        // Use the charm base URL with chat app path
        let urlString = "\(baseURL)/charm/apps/chat-with-records/chat-with-records.html?session=\(sessionId)"
        
        logger.info("Generated chat URL: \(urlString)")
        return URL(string: urlString)
    }
    
    // MARK: - Helper Functions
    
    private func formatRecordType(_ type: HealthRecord.RecordType) -> String {
        switch type {
        case .pdf: return "PDF Document"
        case .image: return "Image Document"
        case .healthKit: return "HealthKit Data"
        }
    }
    
    private func formatDataAsText(_ data: [String: Any], indent: String) -> String {
        var text = ""
        let sortedKeys = data.keys.sorted()
        
        for key in sortedKeys {
            let value = data[key]
            text += "\(indent)\(key.capitalized): "
            
            if let dict = value as? [String: Any] {
                text += "\n"
                text += formatDataAsText(dict, indent: indent + "  ")
            } else if let array = value as? [Any] {
                text += "[\(array.count) items]\n"
                for (index, item) in array.enumerated() {
                    text += "\(indent)  [\(index)] \(item)\n"
                }
            } else if key.lowercased() == "fhirresource", let fhirString = value as? String {
                // Decode base64 FHIR resource
                text += "\n"
                text += decodeFHIRResource(fhirString, indent: indent + "  ")
            } else {
                text += "\(value)\n"
            }
        }
        
        return text
    }
    
    /// Decode base64-encoded FHIR resource and format as readable text
    private func decodeFHIRResource(_ base64String: String, indent: String) -> String {
        guard let data = Data(base64Encoded: base64String),
              let jsonString = String(data: data, encoding: .utf8) else {
            return "\(indent)Unable to decode FHIR resource\n"
        }
        
        do {
            if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var fhirText = "\(indent)FHIR Resource (Decoded):\n"
                fhirText += formatFHIRData(jsonObject, indent: indent + "  ")
                return fhirText
            } else {
                return "\(indent)FHIR JSON: \(jsonString)\n"
            }
        } catch {
            return "\(indent)FHIR JSON (Raw): \(jsonString)\n"
        }
    }
    
    /// Format FHIR data with medical-friendly field names
    private func formatFHIRData(_ data: [String: Any], indent: String) -> String {
        var text = ""
        let sortedKeys = data.keys.sorted()
        
        for key in sortedKeys {
            let value = data[key]
            let displayName = getFHIRFieldDisplayName(key)
            text += "\(indent)\(displayName): "
            
            if let dict = value as? [String: Any] {
                text += "\n"
                text += formatFHIRData(dict, indent: indent + "  ")
            } else if let array = value as? [Any] {
                text += "\n"
                for (index, item) in array.enumerated() {
                    if let itemDict = item as? [String: Any] {
                        text += "\(indent)  [\(index + 1)]\n"
                        text += formatFHIRData(itemDict, indent: indent + "    ")
                    } else {
                        text += "\(indent)  [\(index + 1)] \(item)\n"
                    }
                }
            } else {
                text += "\(value)\n"
            }
        }
        
        return text
    }
    
    /// Convert FHIR field names to human-readable labels
    private func getFHIRFieldDisplayName(_ fieldName: String) -> String {
        switch fieldName.lowercased() {
        case "resourcetype": return "Resource Type"
        case "id": return "ID"
        case "status": return "Status"
        case "patient": return "Patient"
        case "recordeddate": return "Recorded Date"
        case "substance": return "Substance/Allergen"
        case "reaction": return "Reactions"
        case "onset": return "Onset Date"
        case "manifestation": return "Symptoms"
        case "severity": return "Severity"
        case "text": return "Description"
        case "display": return "Name"
        case "coding": return "Medical Codes"
        case "system": return "Code System"
        case "code": return "Code"
        case "reference": return "Reference"
        default: return fieldName.capitalized
        }
    }
}

// MARK: - Models

struct ChatContext {
    let patientName: String?
    let recordCount: Int?
    let lastUpdated: String?
}

struct ChatSessionResponse: Codable {
    let sessionId: String
    let chatUrl: String
    let prePopulatedData: ChatPrePopulatedData
    let metadata: SessionMetadata
}

struct ChatPrePopulatedData: Codable {
    let medicalRecord: String
    let systemPrompt: String
    let chatContext: [String: AnyCodable]
}

struct ClinicalTrialSessionResponse: Codable {
    let sessionId: String
    let interfaceUrl: String
    let deepLinkUrl: String?
    let trialInfo: TrialInfo?
    let prePopulatedData: PrePopulatedData
    let metadata: SessionMetadata
}

struct TrialInfo: Codable {
    let nctNumber: String
    let title: String?
    let condition: String?
    let phase: String?
    let status: String?
    let ageRange: String?
    let gender: String?
}

struct PrePopulatedData: Codable {
    let medicalRecord: String
    let trialCriteria: TrialCriteria?
    let mode: String
}

struct TrialCriteria: Codable {
    let inclusionCriteria: [String]?
    let exclusionCriteria: [String]?
}

struct SessionMetadata: Codable {
    let createdAt: String
    let expiresAt: String
    let sessionDuration: String
}

enum ClinicalTrialError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(String)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL for clinical trial matcher"
        case .invalidResponse:
            return "Invalid response from server"
        case .serverError(let message):
            return "Server error: \(message)"
        }
    }
}