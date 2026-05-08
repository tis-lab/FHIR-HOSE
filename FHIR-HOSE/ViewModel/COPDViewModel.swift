import Foundation
import SwiftUI

@MainActor
class COPDViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var hasGeneratedData = false
    @Published var generatedJSON = ""
    @Published var errorMessage: String?
    
    /// Generate COPD prediction data from health records
    func generateCOPDData(from records: [HealthRecord]) {
        isProcessing = true
        errorMessage = nil
        
        Task {
            do {
                let copdData = await extractCOPDData(from: records)
                let jsonString = formatAsJSON(copdData)
                
                await MainActor.run {
                    self.generatedJSON = jsonString
                    self.hasGeneratedData = true
                    self.isProcessing = false
                }
                
                print("✅ COPD JSON Generated:")
                print(jsonString)
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to generate COPD data: \(error.localizedDescription)"
                    self.isProcessing = false
                }
            }
        }
    }
    
    /// Extract COPD-relevant data from health records
    private func extractCOPDData(from healthRecords: [HealthRecord]) async -> [String: Any] {
        var data: [String: Any] = [
            "ethnicity": "Unknown",
            "sex_at_birth": "Unknown",
            "obesity": 0.0,
            "diabetes": 0.0,
            "cardiovascular_disease": 0.0,
            "smoking_status": 0.0,
            "alcohol_use": 0.0,
            "bmi": NSNull(), // No default - must be provided by user or HealthKit
            "age_at_time_0": NSNull() // No default - must be provided by user or HealthKit
        ]
        
        print("🔍 COPD Data Extraction Starting...")
        print("📊 Total HealthKit records to process: \(healthRecords.count)")
        
        // Group records by type for debugging
        let recordsByType = Dictionary(grouping: healthRecords) { record in
            return record.healthKitType ?? "Unknown"
        }
        print("📋 Record types found:")
        for (type, records) in recordsByType {
            print("   \(type): \(records.count) records")
        }
        
        for (index, record) in healthRecords.enumerated() {
            print("\n🔍 Processing record \(index + 1)/\(healthRecords.count)")
            print("📊 HealthKit data: \(record.healthKitType ?? "Unknown")")
            print("📅 Date: \(record.date)")
            print("🔑 Data keys: \(record.healthKitData?.keys.map(Array.init) ?? [])")
            
            if let healthKitData = record.healthKitData, let type = record.healthKitType {
                processHealthKitData(data: &data, type: type, healthKitData: healthKitData)
                print("❌ No HealthKit data available for this record")
            }
        }
        
        print("🎯 Final extracted data:")
        for (key, value) in data.sorted(by: { $0.key < $1.key }) {
            print("   \(key): \(value)")
        }
        
        // Explicitly log BMI value
        if let bmiValue = data["bmi"] as? Double {
            print("🏋️‍♂️ EXPLICIT BMI CHECK: BMI = \(bmiValue)")
        } else if let bmiValue = data["bmi"] as? NSNumber {
            print("🏋️‍♂️ EXPLICIT BMI CHECK: BMI = \(bmiValue.doubleValue)")
        } else {
            print("❌ EXPLICIT BMI CHECK: NO BMI FOUND IN FINAL DATA")
        }
        
        return data
    }
    
    /// Process HealthKit data
    private func processHealthKitData(data: inout [String: Any], type: String, healthKitData: [String: Any]) {

        print("🔍 Processing HealthKit type: '\(type)'")
        print("📊 HealthKit data: \(healthKitData)")
        
        // Handle different possible type identifier formats
        let normalizedType = type.lowercased()
        print("🔄 Normalized type: '\(normalizedType)'")
        
        switch normalizedType {
        // Biological Sex - HKCharacteristicTypeIdentifierBiologicalSex
        case "hkcharacteristictypeidentifierbiologicalsex", "biologicalsex", "biological sex":
            if let sexValue = healthKitData["value"] as? Int {
                print("✅ Biological sex raw value found: \(sexValue)")
                // Apple HealthKit HKBiologicalSex enum:
                // HKBiologicalSex.notSet = 0
                // HKBiologicalSex.female = 1
                // HKBiologicalSex.male = 2
                // HKBiologicalSex.other = 3
                switch sexValue {
                case 1:
                    data["sex_at_birth"] = "Female"
                    print("✅ Set sex_at_birth to Female")
                case 2:
                    data["sex_at_birth"] = "Male"
                    print("✅ Set sex_at_birth to Male")
                case 3:
                    data["sex_at_birth"] = "Other"
                    print("✅ Set sex_at_birth to Other")
                case 0:
                    data["sex_at_birth"] = "Unknown"
                    print("⚠️ Biological sex not set")
                default:
                    data["sex_at_birth"] = "Unknown"
                    print("⚠️ Unknown biological sex value: \(sexValue)")
                }
            } else {
                print("❌ Could not extract biological sex value from: \(healthKitData)")
            }
            
        // Date of Birth - HKCharacteristicTypeIdentifierDateOfBirth
        case "hkcharacteristictypeidentifierdateofbirth", "dateofbirth", "date of birth":
            if let birthDate = healthKitData["value"] as? Date {
                let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
                data["age_at_time_0"] = Double(age)
                print("✅ Age calculated: \(age) years (from birth date: \(birthDate))")
            } else if let birthDateString = healthKitData["value"] as? String {
                // Try to parse string date
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let birthDate = formatter.date(from: birthDateString) {
                    let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
                    data["age_at_time_0"] = Double(age)
                    print("✅ Age calculated from string: \(age) years")
                } else {
                    print("❌ Could not parse birth date string: \(birthDateString)")
                }
            } else {
                print("❌ Could not extract birth date from: \(healthKitData)")
            }
            
        // Body Mass Index - HKQuantityTypeIdentifier.bodyMassIndex
        case "hkquantitytypeidentifierbodymassindex", "bodymassindex", "body mass index", "bmi", "hkquantitytypeidentifier.bodymassindex":
            print("🔍 Found BMI record! Processing...")
            print("📊 BMI HealthKit data: \(healthKitData)")
            if let bmiValue = healthKitData["value"] as? Double {
                data["bmi"] = bmiValue
                print("✅ BMI found: \(bmiValue)")
                print("🏋️‍♂️ EXPLICIT BMI SET FROM HEALTHKIT: \(bmiValue)")
            } else if let bmiValue = healthKitData["value"] as? NSNumber {
                data["bmi"] = bmiValue.doubleValue
                print("✅ BMI found (NSNumber): \(bmiValue.doubleValue)")
                print("🏋️‍♂️ EXPLICIT BMI SET FROM HEALTHKIT (NSNumber): \(bmiValue.doubleValue)")
            } else {
                print("❌ Could not extract BMI value from: \(healthKitData)")
                print("❌ Available keys in BMI data: \(Array(healthKitData.keys))")
            }
            
        // Clinical Records - HKClinicalTypeIdentifierConditionRecord
        case "hkclinicaltypeidentifierconditionrecord", "conditionrecord", "clinical condition":
            print("🏥 Processing Clinical Condition Record")
            if let fhirResourceString = healthKitData["fhirResource"] as? String {
                print("📋 Found FHIR resource data, attempting to decode...")
                if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                    print("✅ Successfully decoded FHIR resource")
                    // Process the decoded FHIR data
                    updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                } else {
                    print("❌ Failed to decode FHIR resource")
                }
            } else {
                print("❌ No fhirResource found in clinical record")
            }
            
        // Other Clinical Records
        case "hkclinicaltypeidentifierallergyrecord", "allergyrecord":
            print("🤧 Processing Clinical Allergy Record")
            if let fhirResourceString = healthKitData["fhirResource"] as? String {
                if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                    updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                }
            }
            
        case "hkclinicaltypeidentifiermedicationrecord", "medicationrecord":
            print("💊 Processing Clinical Medication Record")
            if let fhirResourceString = healthKitData["fhirResource"] as? String {
                if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                    updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                }
            }
            
        case "hkclinicaltypeidentifiervitalrecord", "vitalrecord", "hkclinicaltypeidentifiervitalsignrecord", "vitalsignrecord":
            print("📊 Processing Clinical Vital Sign Record")
            if let fhirResourceString = healthKitData["fhirResource"] as? String {
                print("🔍 Found FHIR resource in vital sign record, checking for BMI...")
                if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                    print("✅ Successfully decoded FHIR vital sign record")
                    // Check specifically for BMI in this vital record
                    if let observation = decodedFHIR as? [String: Any],
                       let resourceType = observation["resourceType"] as? String,
                       resourceType == "Observation" {
                        print("🔍 Found Observation in vital sign record, checking for BMI...")
                        extractBMIFromObservation(observation: observation, data: &data)
                    }
                    updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                }
            }
            
        case "patientfhirresource":
            print("👤 Processing Patient FHIR Resource")
            if let fhirResourceString = healthKitData["fhirResource"] as? String {
                print("🔍 Found Patient FHIR resource data")
                if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                    print("✅ Successfully decoded Patient FHIR resource")
                    updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                } else {
                    print("❌ Failed to decode Patient FHIR resource")
                }
            } else {
                print("❌ No FHIR resource string found in Patient FHIR Resource")
            }
            
        default:
            print("⚠️ Unhandled HealthKit type: '\(type)' (normalized: '\(normalizedType)')")
            print("📋 Available data keys: \(Array(healthKitData.keys))")
            
            // Check if this is a clinical record we haven't handled yet
            if normalizedType.contains("clinical") && healthKitData["fhirResource"] != nil {
                print("🏥 Detected unhandled clinical record type, attempting to decode FHIR...")
                if let fhirResourceString = healthKitData["fhirResource"] as? String {
                    if let decodedFHIR = decodeFHIRResource(fhirResourceString) {
                        print("✅ Successfully decoded unknown clinical record")
                        updateDataFromFHIR(data: &data, fhirData: decodedFHIR)
                    }
                }
            }
            
            // Log the type for debugging - this helps us identify new types to handle
            if !normalizedType.isEmpty {
                print("🔍 Consider adding support for: \(type)")
            }
            break
        }
    }
    
    /// Decode base64-encoded FHIR resource to actual JSON object
    private func decodeFHIRResource(_ base64String: String) -> [String: Any]? {
        guard let data = Data(base64Encoded: base64String) else {
            // If it's not base64, try to parse as direct JSON string
            guard let jsonData = base64String.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        }
        
        // Try to parse the decoded data as JSON
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            // If JSON parsing fails, try treating the decoded data as a JSON string
            if let jsonString = String(data: data, encoding: .utf8),
               let jsonData = jsonString.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
            }
            return nil
        }
    }
    
    /// Update data from FHIR records
    private func updateDataFromFHIR(data: inout [String: Any], fhirData: [String: Any]) {
        print("🩺 Processing FHIR data...")
        print("📊 FHIR top-level keys: \(Array(fhirData.keys))")
        
        // Extract from Patient resource
        if let patient = fhirData["Patient"] as? [String: Any] {
            print("👤 Found Patient resource with keys: \(Array(patient.keys))")
            
            // Ethnicity from extensions (US Core R4 format)
            if let extensions = patient["extension"] as? [[String: Any]] {
                print("🔍 Found \(extensions.count) extensions in Patient")
                for (index, ext) in extensions.enumerated() {
                    print("   Extension \(index): \(Array(ext.keys))")
                    if let url = ext["url"] as? String {
                        print("   Extension URL: \(url)")
                        
                        // US Core ethnicity extension
                        if url.contains("us-core-ethnicity") || url.contains("ethnicity") {
                            print("   ✅ Found US Core ethnicity extension!")
                            
                            // Look for nested extensions with ombCategory
                            if let nestedExtensions = ext["extension"] as? [[String: Any]] {
                                print("   🔍 Found \(nestedExtensions.count) nested extensions")
                                for (nestedIndex, nestedExt) in nestedExtensions.enumerated() {
                                    print("      Nested Extension \(nestedIndex): \(Array(nestedExt.keys))")
                                    if let nestedUrl = nestedExt["url"] as? String {
                                        print("      Nested URL: \(nestedUrl)")
                                        
                                        // OMB Category (main ethnicity classification)
                                        if nestedUrl == "ombCategory" {
                                            print("      🎯 Found ombCategory!")
                                            if let valueCoding = nestedExt["valueCoding"] as? [String: Any] {
                                                print("         valueCoding: \(valueCoding)")
                                                if let display = valueCoding["display"] as? String {
                                                    data["ethnicity"] = display
                                                    print("      ✅ Set ethnicity from ombCategory display: \(display)")
                                                } else if let code = valueCoding["code"] as? String {
                                                    // Map common OMB codes to readable names
                                                    let ethnicityName = mapOMBEthnicityCode(code)
                                                    data["ethnicity"] = ethnicityName
                                                    print("      ✅ Set ethnicity from ombCategory code: \(code) -> \(ethnicityName)")
                                                }
                                            }
                                        }
                                        // Text field (human readable)
                                        else if nestedUrl == "text" {
                                            print("      📝 Found text field!")
                                            if let valueString = nestedExt["valueString"] as? String {
                                                // Only use text if we don't already have ethnicity from ombCategory
                                                if data["ethnicity"] as? String == "Unknown" {
                                                    data["ethnicity"] = valueString
                                                    print("      ✅ Set ethnicity from text: \(valueString)")
                                                }
                                            }
                                        }
                                        // Detailed ethnicity (more specific)
                                        else if nestedUrl == "detailed" {
                                            print("      📋 Found detailed ethnicity")
                                            if let valueCoding = nestedExt["valueCoding"] as? [String: Any],
                                               let display = valueCoding["display"] as? String {
                                                print("         Detailed ethnicity: \(display)")
                                                // Could store this for more granular data if needed
                                            }
                                        }
                                    }
                                }
                            }
                            // Fallback: direct value in extension (non-standard but possible)
                            else if let valueCoding = ext["valueCoding"] as? [String: Any],
                                     let display = valueCoding["display"] as? String {
                                data["ethnicity"] = display
                                print("   ✅ Set ethnicity from direct valueCoding: \(display)")
                            } else if let valueString = ext["valueString"] as? String {
                                data["ethnicity"] = valueString
                                print("   ✅ Set ethnicity from direct valueString: \(valueString)")
                            }
                        }
                        // US Core race extension (similar structure)
                        else if url.contains("us-core-race") || url.contains("race") {
                            print("   🔍 Found US Core race extension")
                            // Similar processing for race if needed
                        }
                    }
                }
            } else {
                print("❌ No extensions found in Patient resource")
            }
            
            // Also check direct fields in Patient resource
            if let ethnicity = patient["ethnicity"] as? String {
                data["ethnicity"] = ethnicity
                print("✅ Set ethnicity from direct field: \(ethnicity)")
            } else if let race = patient["race"] as? String {
                data["ethnicity"] = race
                print("✅ Set ethnicity from race field: \(race)")
            }
            
            // Gender (Administrative Gender)
            if let gender = patient["gender"] as? String {
                data["sex_at_birth"] = gender.capitalized
                print("✅ Set sex_at_birth from FHIR gender: \(gender.capitalized)")
            }
            
            // Look for Sex Assigned At Birth in extensions (more specific than administrative gender)
            if let extensions = patient["extension"] as? [[String: Any]] {
                for ext in extensions {
                    if let url = ext["url"] as? String,
                       url.contains("recordedSexOrGender") {
                        print("🔍 Found recordedSexOrGender extension")
                        if let nestedExtensions = ext["extension"] as? [[String: Any]] {
                            for nestedExt in nestedExtensions {
                                if let nestedUrl = nestedExt["url"] as? String {
                                    // Look for type field to identify "Sex Assigned At Birth"
                                    if nestedUrl == "type" {
                                        if let typeValue = nestedExt["valueCodeableConcept"] as? [String: Any],
                                           let coding = typeValue["coding"] as? [[String: Any]] {
                                            for code in coding {
                                                if let display = code["display"] as? String,
                                                   display.lowercased().contains("sex assigned at birth") {
                                                    print("   🎯 Found 'Sex Assigned At Birth' type")
                                                    // Now look for the value in the same extension
                                                    for valueExt in nestedExtensions {
                                                        if let valueUrl = valueExt["url"] as? String,
                                                           valueUrl == "value" {
                                                            if let valueCodeable = valueExt["valueCodeableConcept"] as? [String: Any],
                                                               let valueCoding = valueCodeable["coding"] as? [[String: Any]],
                                                               let firstCode = valueCoding.first,
                                                               let display = firstCode["display"] as? String {
                                                                data["sex_at_birth"] = display
                                                                print("   ✅ Set sex_at_birth from Sex Assigned At Birth: \(display)")
                                                                break
                                                            }
                                                        }
                                                    }
                                                    break
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Birth date for age calculation
            if let birthDate = patient["birthDate"] as? String {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                if let date = formatter.date(from: birthDate) {
                    let age = Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
                    data["age_at_time_0"] = Double(age)
                    print("✅ Set age from FHIR birthDate: \(age)")
                }
            }
        } else {
            print("❌ No Patient resource found in FHIR data")
        }
        
        // Extract BMI from Observation resources
        if let observation = fhirData["Observation"] as? [String: Any] {
            extractBMIFromObservation(observation: observation, data: &data)
        } else if let observations = fhirData["entry"] as? [[String: Any]] {
            // Handle Bundle format with multiple entries
            for entry in observations {
                if let resource = entry["resource"] as? [String: Any],
                   let resourceType = resource["resourceType"] as? String,
                   resourceType == "Observation" {
                    extractBMIFromObservation(observation: resource, data: &data)
                }
            }
        }
    }
    
    /// Extract BMI from FHIR Observation resource
    private func extractBMIFromObservation(observation: [String: Any], data: inout [String: Any]) {
        print("🔍 Processing Observation for BMI...")
        print("📊 Observation keys: \(Array(observation.keys))")
        
        // Check if this is a BMI observation
        if let code = observation["code"] as? [String: Any] {
            print("🔍 Found code section: \(code)")
            
            // Check for text field first (simpler)
            if let text = code["text"] as? String {
                print("📝 Code text: '\(text)'")
                if text.lowercased().contains("bmi") || text.lowercased().contains("body mass index") {
                    print("✅ Found BMI by text field!")
                    if let valueQuantity = observation["valueQuantity"] as? [String: Any],
                       let value = valueQuantity["value"] as? Double {
                        data["bmi"] = value
                        print("✅ Set BMI from FHIR text match: \(value)")
                        print("🏋️‍♂️ EXPLICIT BMI SET FROM FHIR TEXT: \(value)")
                        return
                    }
                }
            }
            
            // Check coding array
            if let coding = code["coding"] as? [[String: Any]] {
                print("🔍 Found \(coding.count) coding entries")
                
                for (index, codeEntry) in coding.enumerated() {
                    print("   Coding \(index): \(codeEntry)")
                    
                    if let loincCode = codeEntry["code"] as? String,
                       let system = codeEntry["system"] as? String {
                        print("   System: \(system), Code: \(loincCode)")
                        
                        // BMI LOINC code: 39156-5 "Body mass index (BMI) [Ratio]"
                        if system.contains("loinc.org") && loincCode == "39156-5" {
                            print("✅ Found BMI Observation (LOINC: 39156-5)")
                            
                            // Extract the value
                            if let valueQuantity = observation["valueQuantity"] as? [String: Any] {
                                print("📊 ValueQuantity: \(valueQuantity)")
                                if let value = valueQuantity["value"] as? Double {
                                    data["bmi"] = value
                                    print("✅ Set BMI from FHIR Observation: \(value)")
                                    return
                                } else if let value = valueQuantity["value"] as? NSNumber {
                                    data["bmi"] = value.doubleValue
                                    print("✅ Set BMI from FHIR Observation (NSNumber): \(value.doubleValue)")
                                    return
                                }
                            }
                        }
                    }
                    
                    // Also check for display text that might indicate BMI
                    if let display = codeEntry["display"] as? String {
                        print("   Display: '\(display)'")
                        if display.lowercased().contains("body mass index") || display.lowercased().contains("bmi") {
                            print("✅ Found BMI Observation by display text: \(display)")
                            
                            if let valueQuantity = observation["valueQuantity"] as? [String: Any],
                               let value = valueQuantity["value"] as? Double {
                                data["bmi"] = value
                                print("✅ Set BMI from FHIR Observation: \(value)")
                                return
                            }
                        }
                    }
                }
            }
        } else {
            print("❌ No code section found in observation")
        }
    }
    
    /// Format the extracted data as JSON string with consistent ordering
    private func formatAsJSON(_ data: [String: Any]) -> String {
        // Define the exact order we want
        let fieldOrder = [
            "ethnicity",
            "sex_at_birth", 
            "obesity",
            "diabetes",
            "cardiovascular_disease",
            "smoking_status",
            "alcohol_use",
            "bmi",
            "age_at_time_0"
        ]
        
        // Build JSON manually to guarantee field order
        var jsonLines: [String] = []
        jsonLines.append("[")
        jsonLines.append("  {")
        
        for (index, field) in fieldOrder.enumerated() {
            let value = data[field] ?? getDefaultValue(for: field)
            let jsonValue = formatValueForJSON(value)
            let comma = index < fieldOrder.count - 1 ? "," : ""
            jsonLines.append("    \"\(field)\" : \(jsonValue)\(comma)")
        }
        
        jsonLines.append("  }")
        jsonLines.append("]")
        
        return jsonLines.joined(separator: "\n")
    }
    
    /// Get default value for a field
    private func getDefaultValue(for field: String) -> Any {
        switch field {
        case "ethnicity", "sex_at_birth":
            return "Unknown"
        case "bmi", "age_at_time_0":
            return NSNull() // No defaults for these critical fields
        default:
            return 0.0
        }
    }
    
    /// Format a value for JSON output
    private func formatValueForJSON(_ value: Any) -> String {
        if value is NSNull {
            return "null"
        } else if let string = value as? String {
            return "\"\(string)\""
        } else if let number = value as? Double {
            // Format as integer if it's a whole number, otherwise as decimal
            if number == floor(number) {
                return String(Int(number))
            } else {
                return String(number)
            }
        } else if let number = value as? Int {
            return String(number)
        } else if let bool = value as? Bool {
            return bool ? "1" : "0"
        } else {
            return "\"\(value)\""
        }
    }
    
    /// Map OMB ethnicity codes to readable names
    private func mapOMBEthnicityCode(_ code: String) -> String {
        // Add mappings here as needed
        switch code {
        case "1002-5":
            return "Hispanic or Latino"
        case "2028-9":
            return "Not Hispanic or Latino"
        default:
            return "Unknown"
        }
    }
}
