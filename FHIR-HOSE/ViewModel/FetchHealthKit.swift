//
//  FetchHealthKit.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import HealthKit
import Foundation

private let fileLogger = FileLogger.shared

/// Maps an `HKFHIRVersion` to a release code used for bucketing exports.
///
/// FHIR release lineage: DSTU1 (0.x), DSTU2 (1.0.x), STU3 (3.0.x), R4 (4.0.x),
/// R4B (4.3.x), R5 (5.0.x). R4 and R4B share major version 4 and are distinguished
/// by minor version. Versions not on this lineage fall through to `"unknown"`.
private func fhirReleaseCode(for version: HKFHIRVersion?) -> String {
    guard let v = version else { return "unknown" }
    switch (v.majorVersion, v.minorVersion) {
    case (0, _): return "dstu1"
    case (1, _): return "dstu2"
    case (3, _): return "stu3"
    case (4, 0): return "r4"
    case (4, 3): return "r4b"
    case (5, _): return "r5"
    default: return "unknown"
    }
}

extension HKBloodType {
    var displayString: String {
        switch self {
        case .notSet:    return "Not Set"
        case .aPositive: return "A+"
        case .aNegative: return "A-"
        case .bPositive: return "B+"
        case .bNegative: return "B-"
        case .abPositive: return "AB+"
        case .abNegative: return "AB-"
        case .oPositive:  return "O+"
        case .oNegative:  return "O-"
        @unknown default: return "Unknown"
        }
    }
}

extension HKBiologicalSex {
    var displayString: String {
        switch self {
        case .notSet:  return "Not Set"
        case .female:  return "Female"
        case .male:    return "Male"
        case .other:   return "Other"
        @unknown default: return "Unknown"
        }
    }
}

class HealthKitManager: ObservableObject {
    let healthStore = HKHealthStore()
    
    private let quantityTypes: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .bloodPressureSystolic,
        .bloodPressureDiastolic,
        .bodyTemperature,
        .height,
        .bodyMass,
        .bodyMassIndex,
        .stepCount,
        .distanceWalkingRunning,
        .activeEnergyBurned,
        .bloodGlucose,
        .oxygenSaturation
    ]
    
    private let categoryTypes: [HKCategoryTypeIdentifier] = [
        .sleepAnalysis,
        .mindfulSession,
        .menstrualFlow
    ]
    
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        var typesToRead = Set<HKObjectType>()
        var typesToWrite = Set<HKSampleType>()
        
        // Add characteristic types (read-only)
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .biologicalSex)!)
        typesToRead.insert(HKObjectType.characteristicType(forIdentifier: .bloodType)!)
        
        print("🔐 Requesting HealthKit authorization...")
        print("📊 Requesting \(quantityTypes.count) quantity types including BMI")
        
        // Add quantity types for reading
        for identifier in quantityTypes {
            if let type = HKObjectType.quantityType(forIdentifier: identifier) {
                typesToRead.insert(type)
                print("   ✅ Added quantity type: \(identifier.rawValue)")
            } else {
                print("   ❌ Failed to create quantity type: \(identifier.rawValue)")
            }
        }
        
        // Add write permissions for BMI, height, and weight
        if let bmiType = HKObjectType.quantityType(forIdentifier: .bodyMassIndex) {
            typesToWrite.insert(bmiType)
            print("   ✅ Added write permission for BMI")
        }
        if let heightType = HKObjectType.quantityType(forIdentifier: .height) {
            typesToWrite.insert(heightType)
            print("   ✅ Added write permission for height")
        }
        if let weightType = HKObjectType.quantityType(forIdentifier: .bodyMass) {
            typesToWrite.insert(weightType)
            print("   ✅ Added write permission for weight")
        }
        
        // Add category types
        for identifier in categoryTypes {
            if let type = HKObjectType.categoryType(forIdentifier: identifier) {
                typesToRead.insert(type)
            }
        }
        
        // Add clinical record types
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .allergyRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .conditionRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .medicationRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .procedureRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .immunizationRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .labResultRecord) {
            typesToRead.insert(clinicalRecordType)
        }
        if let clinicalRecordType = HKObjectType.clinicalType(forIdentifier: .vitalSignRecord) {
            typesToRead.insert(clinicalRecordType)
            print("   ✅ Added vital sign records (contains BMI)")
        }
        
        print("📋 Total types to request: \(typesToRead.count) read, \(typesToWrite.count) write")
        print("🔍 Types include: \(typesToRead.map { $0.identifier }.sorted())")
        
        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, error in
            completion(success, error)
        }
    }
    
    func fetchAllHealthRecords(completion: @escaping ([HealthRecord]) -> Void) {
        var allRecords: [HealthRecord] = []
        let group = DispatchGroup()
        
        // Fetch characteristics
        group.enter()
        fetchCharacteristics { records in
            allRecords.append(contentsOf: records)
            group.leave()
        }
        
        // Fetch quantity samples
        for identifier in quantityTypes {
            group.enter()
            fetchQuantityData(for: identifier) { records in
                allRecords.append(contentsOf: records)
                group.leave()
            }
        }
        
        // Fetch category samples
        for identifier in categoryTypes {
            group.enter()
            fetchCategoryData(for: identifier) { records in
                allRecords.append(contentsOf: records)
                group.leave()
            }
        }
        
        // Fetch clinical records
        group.enter()
        fetchClinicalRecords { records in
            allRecords.append(contentsOf: records)
            group.leave()
        }
        
        group.notify(queue: .main) {
            completion(allRecords)
        }
    }
    
    private func fetchCharacteristics(completion: @escaping ([HealthRecord]) -> Void) {
        var records: [HealthRecord] = []
        
        do {
            // Date of birth
            if let birthday = try? healthStore.dateOfBirth() {
                let data: [String: Any] = [
                    "type": "dateOfBirth",
                    "value": birthday,
                    "displayName": "Date of Birth"
                ]
                records.append(HealthRecord(healthKitType: "DateOfBirth", data: data, date: birthday))
            }
            
            // Biological sex
            let biologicalSex = try healthStore.biologicalSex()
            let sexData: [String: Any] = [
                "type": "biologicalSex",
                "value": biologicalSex.biologicalSex.displayString,
                "displayName": "Biological Sex"
            ]
            records.append(HealthRecord(healthKitType: "BiologicalSex", data: sexData))
            
            // Blood type
            let bloodType = try healthStore.bloodType()
            let bloodData: [String: Any] = [
                "type": "bloodType",
                "value": bloodType.bloodType.displayString,
                "displayName": "Blood Type"
            ]
            records.append(HealthRecord(healthKitType: "BloodType", data: bloodData))
            
        } catch {
            fileLogger.error("Error fetching characteristics: \(error)", category: "HealthKit")
        }
        
        completion(records)
    }
    
    private func fetchQuantityData(for identifier: HKQuantityTypeIdentifier, completion: @escaping ([HealthRecord]) -> Void) {
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            completion([])
            return
        }
        
        let query = HKSampleQuery(
            sampleType: quantityType,
            predicate: nil,
            limit: 100,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { _, samples, error in
            
            guard let samples = samples as? [HKQuantitySample], error == nil else {
                completion([])
                return
            }
            
            let records = samples.map { sample in
                // Use a common unit for the quantity type
                let unit: HKUnit
                switch identifier {
                case .heartRate:
                    unit = HKUnit.count().unitDivided(by: .minute())
                case .bloodPressureSystolic, .bloodPressureDiastolic:
                    unit = HKUnit.millimeterOfMercury()
                case .bodyTemperature:
                    unit = HKUnit.degreeCelsius()
                case .height:
                    unit = HKUnit.meter()
                case .bodyMass:
                    unit = HKUnit.gramUnit(with: .kilo)
                case .bodyMassIndex:
                    unit = HKUnit.count()
                case .stepCount:
                    unit = HKUnit.count()
                case .distanceWalkingRunning:
                    unit = HKUnit.meter()
                case .activeEnergyBurned:
                    unit = HKUnit.kilocalorie()
                case .bloodGlucose:
                    unit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
                case .oxygenSaturation:
                    unit = HKUnit.percent()
                default:
                    unit = HKUnit.count()
                }
                
                let data: [String: Any] = [
                    "type": identifier.rawValue,
                    "value": sample.quantity.doubleValue(for: unit),
                    "unit": unit.unitString,
                    "startDate": sample.startDate,
                    "endDate": sample.endDate,
                    "displayName": sample.quantityType.identifier
                ]
                return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
            }
            
            completion(records)
        }
        
        healthStore.execute(query)
    }
    
    private func fetchCategoryData(for identifier: HKCategoryTypeIdentifier, completion: @escaping ([HealthRecord]) -> Void) {
        guard let categoryType = HKObjectType.categoryType(forIdentifier: identifier) else {
            completion([])
            return
        }
        
        let query = HKSampleQuery(
            sampleType: categoryType,
            predicate: nil,
            limit: 100,
            sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        ) { _, samples, error in
            
            guard let samples = samples as? [HKCategorySample], error == nil else {
                completion([])
                return
            }
            
            let records = samples.map { sample in
                let data: [String: Any] = [
                    "type": identifier.rawValue,
                    "value": sample.value,
                    "startDate": sample.startDate,
                    "endDate": sample.endDate,
                    "displayName": sample.categoryType.identifier
                ]
                return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
            }
            
            completion(records)
        }
        
        healthStore.execute(query)
    }
    
    private func fetchClinicalRecords(completion: @escaping ([HealthRecord]) -> Void) {
        var allClinicalRecords: [HealthRecord] = []
        let clinicalTypes: [HKClinicalTypeIdentifier] = [
            .allergyRecord, .conditionRecord, .medicationRecord,
            .procedureRecord, .immunizationRecord, .labResultRecord, .vitalSignRecord
        ]
        
        let group = DispatchGroup()
        
        for identifier in clinicalTypes {
            guard let clinicalType = HKObjectType.clinicalType(forIdentifier: identifier) else { continue }
            
            group.enter()
            let query = HKSampleQuery(
                sampleType: clinicalType,
                predicate: nil,
                limit: 100,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                
                defer { group.leave() }
                
                guard let samples = samples as? [HKClinicalRecord], error == nil else {
                    return
                }
                
                let records = samples.map { sample in
                    let data: [String: Any] = [
                        "type": identifier.rawValue,
                        "displayName": sample.clinicalType.identifier,
                        "startDate": sample.startDate,
                        "endDate": sample.endDate,
                        "fhirResource": sample.fhirResource?.data.base64EncodedString() ?? "",
                        "fhirVersion": sample.fhirResource?.fhirVersion.stringRepresentation ?? "unknown",
                        "fhirRelease": fhirReleaseCode(for: sample.fhirResource?.fhirVersion)
                    ]
                    
                    // Debug: Check if this clinical record contains Patient data
                    if let fhirResource = sample.fhirResource {
                        if let fhirData = try? JSONSerialization.jsonObject(with: fhirResource.data) as? [String: Any] {
                            if let resourceType = fhirData["resourceType"] as? String {
                                fileLogger.info("Clinical record \(identifier.rawValue) contains FHIR resource type: \(resourceType)", category: "HealthKit")
                                
                                // Check if this is a Patient resource
                                if resourceType == "Patient" {
                                    fileLogger.info("🎯 FOUND PATIENT RESOURCE in \(identifier.rawValue)!", category: "HealthKit")
                                    if let gender = fhirData["gender"] as? String {
                                        fileLogger.info("   Patient gender: \(gender)", category: "HealthKit")
                                    }
                                    if let birthDate = fhirData["birthDate"] as? String {
                                        fileLogger.info("   Patient birthDate: \(birthDate)", category: "HealthKit")
                                    }
                                }
                                
                                // Check if this is a Bundle with Patient resources
                                if resourceType == "Bundle",
                                   let entries = fhirData["entry"] as? [[String: Any]] {
                                    fileLogger.info("   Bundle contains \(entries.count) entries", category: "HealthKit")
                                    for (index, entry) in entries.enumerated() {
                                        if let resource = entry["resource"] as? [String: Any],
                                           let entryResourceType = resource["resourceType"] as? String {
                                            fileLogger.info("     Entry \(index): \(entryResourceType)", category: "HealthKit")
                                            if entryResourceType == "Patient" {
                                                fileLogger.info("🎯 FOUND PATIENT RESOURCE in Bundle entry \(index)!", category: "HealthKit")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    return HealthRecord(healthKitType: identifier.rawValue, data: data, date: sample.startDate)
                }
                
                allClinicalRecords.append(contentsOf: records)
            }
            
            healthStore.execute(query)
        }
        
        group.notify(queue: .main) {
            completion(allClinicalRecords)
        }
    }
    
    private func fetchFHIRResources(completion: @escaping ([HealthRecord]) -> Void) {
        var allFHIRResources: [HealthRecord] = []
        
        // Patient FHIR data is embedded within clinical records, not a separate queryable type
        // We'll extract Patient resources from the FHIR data in existing clinical records
        let clinicalTypes: [HKClinicalTypeIdentifier] = [
            .allergyRecord, .conditionRecord, .medicationRecord,
            .procedureRecord, .immunizationRecord, .labResultRecord
        ]
        
        let group = DispatchGroup()
        
        // Query each clinical type and extract any Patient FHIR resources from the bundles
        for identifier in clinicalTypes {
            guard let clinicalType = HKObjectType.clinicalType(forIdentifier: identifier) else { continue }
            
            group.enter()
            
            let query = HKSampleQuery(
                sampleType: clinicalType,
                predicate: nil,
                limit: 100,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
            ) { _, samples, error in
                
                defer { group.leave() }
                
                guard let samples = samples as? [HKClinicalRecord], error == nil else {
                    if let error = error {
                        fileLogger.error("Error fetching clinical records for Patient extraction from \(identifier.rawValue): \(error)", category: "HealthKit")
                    }
                    return
                }
                
                // Extract Patient resources from FHIR bundles
                for sample in samples {
                    guard let fhirResource = sample.fhirResource else { continue }
                    
                    // Decode the FHIR resource to look for Patient data
                    guard let fhirData = try? JSONSerialization.jsonObject(with: fhirResource.data) as? [String: Any] else { continue }
                    
                    // Check if this is a Bundle containing Patient resources
                    if let resourceType = fhirData["resourceType"] as? String,
                       resourceType == "Bundle",
                       let entries = fhirData["entry"] as? [[String: Any]] {
                        
                        for entry in entries {
                            if let resource = entry["resource"] as? [String: Any],
                               let entryResourceType = resource["resourceType"] as? String,
                               entryResourceType == "Patient" {
                                
                                // Found a Patient resource! Create a record for it
                                guard let encodedResource = try? JSONSerialization.data(withJSONObject: resource).base64EncodedString() else {
                                    fileLogger.error("Skipping Patient resource in \(identifier.rawValue) bundle: not JSON-serializable", category: "HealthKit")
                                    continue
                                }

                                let patientData: [String: Any] = [
                                    "type": "PatientFHIRResource",
                                    "displayName": "FHIR Patient Data",
                                    "startDate": sample.startDate,
                                    "endDate": sample.endDate,
                                    "sourceType": identifier.rawValue,
                                    "fhirResource": encodedResource,
                                    "fhirVersion": fhirResource.fhirVersion.stringRepresentation,
                                    "fhirRelease": fhirReleaseCode(for: fhirResource.fhirVersion)
                                ]
                                
                                let patientRecord = HealthRecord(healthKitType: "PatientFHIRResource", data: patientData, date: sample.startDate)
                                allFHIRResources.append(patientRecord)
                                
                                fileLogger.info("Found Patient FHIR resource in \(identifier.rawValue) bundle", category: "HealthKit")
                            }
                        }
                    }
                    // Check if this is a direct Patient resource (less common but possible)
                    else if let resourceType = fhirData["resourceType"] as? String,
                            resourceType == "Patient" {
                        
                        let patientData: [String: Any] = [
                            "type": "PatientFHIRResource",
                            "displayName": "FHIR Patient Data",
                            "startDate": sample.startDate,
                            "endDate": sample.endDate,
                            "sourceType": identifier.rawValue,
                            "fhirResource": fhirResource.data.base64EncodedString(),
                            "fhirVersion": fhirResource.fhirVersion.stringRepresentation,
                            "fhirRelease": fhirReleaseCode(for: fhirResource.fhirVersion)
                        ]
                        
                        let patientRecord = HealthRecord(healthKitType: "PatientFHIRResource", data: patientData, date: sample.startDate)
                        allFHIRResources.append(patientRecord)
                        
                        fileLogger.info("Found direct Patient FHIR resource in \(identifier.rawValue)", category: "HealthKit")
                    }
                }
            }
            
            healthStore.execute(query)
        }
        
        group.notify(queue: .main) {
            fileLogger.info("Completed FHIR Patient resource extraction: \(allFHIRResources.count) Patient resources found", category: "HealthKit")
            completion(allFHIRResources)
        }
    }
    
    func fetchNameAndBirthday() -> (name: String?, birthday: Date?)? {
        do {
            // Get birthday
            let birthday = try healthStore.dateOfBirth()
            let name = "HealthKit User" // Placeholder - Healthkit does not natively provide method for fetching user name
            return (name: name, birthday: birthday)
        } catch {
            fileLogger.error("Error retrieving name or birthday: \(error.localizedDescription)", category: "HealthKit")
            return nil
        }
    }
    
    /// Fetch BMI from HealthKit, or calculate and save it if missing
    /// - Parameter completion: Returns the BMI value or nil if unable to determine
    func fetchOrCalculateBMI(completion: @escaping (Double?) -> Void) {
        print("🔍 fetchOrCalculateBMI() called")
        guard let bmiType = HKObjectType.quantityType(forIdentifier: .bodyMassIndex) else {
            print("❌ Unable to create BMI quantity type")
            fileLogger.error("Unable to create BMI quantity type", category: "HealthKit")
            DispatchQueue.main.async {
                completion(nil)
            }
            return
        }
        
        print("📊 Step 1: Querying HealthKit for existing BMI...")
        // First, try to fetch existing BMI from HealthKit
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: bmiType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { [weak self] _, samples, error in
            print("📥 BMI query completed")
            
            if let error = error {
                print("❌ Error fetching BMI: \(error.localizedDescription)")
                fileLogger.error("Error fetching BMI: \(error.localizedDescription)", category: "HealthKit")
                DispatchQueue.main.async {
                    completion(nil)
                }
                return
            }
            
            // If we have a recent BMI value, use it
            if let bmiSample = samples?.first as? HKQuantitySample {
                let bmiValue = bmiSample.quantity.doubleValue(for: HKUnit.count())
                print("✅ Found existing BMI in HealthKit: \(bmiValue)")
                fileLogger.info("✅ Found existing BMI in HealthKit: \(bmiValue)", category: "HealthKit")
                DispatchQueue.main.async {
                    completion(bmiValue)
                }
                return
            }
            
            // No BMI found, check if we have height and weight first
            print("⚠️ No BMI found in HealthKit")
            print("📊 Step 2: Checking for height and weight...")
            self?.checkHeightAndWeightThenCalculate(completion: completion)
        }
        
        print("🚀 Executing BMI query...")
        healthStore.execute(query)
    }
    
    /// Check if height and weight exist, then calculate BMI or return nil
    private func checkHeightAndWeightThenCalculate(completion: @escaping (Double?) -> Void) {
        print("📏 Checking for height...")
        print("⚖️ Checking for weight...")
        
        let dispatchGroup = DispatchGroup()
        var hasHeight = false
        var hasWeight = false
        var heightCheckCompleted = false
        var weightCheckCompleted = false
        
        // Check for height with timeout
        dispatchGroup.enter()
        fetchMostRecentQuantity(for: .height) { height in
            guard !heightCheckCompleted else { return }
            heightCheckCompleted = true
            hasHeight = (height != nil)
            print("📏 Height check: \(hasHeight ? "EXISTS ✅" : "MISSING ❌")")
            dispatchGroup.leave()
        }
        
        // Timeout for height check (2 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !heightCheckCompleted else { return }
            heightCheckCompleted = true
            print("⏱️ Height check timed out - assuming missing")
            dispatchGroup.leave()
        }
        
        // Check for weight with timeout
        dispatchGroup.enter()
        fetchMostRecentQuantity(for: .bodyMass) { weight in
            guard !weightCheckCompleted else { return }
            weightCheckCompleted = true
            hasWeight = (weight != nil)
            print("⚖️ Weight check: \(hasWeight ? "EXISTS ✅" : "MISSING ❌")")
            dispatchGroup.leave()
        }
        
        // Timeout for weight check (2 seconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            guard !weightCheckCompleted else { return }
            weightCheckCompleted = true
            print("⏱️ Weight check timed out - assuming missing")
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) { [weak self] in
            print("📊 Height and weight check complete:")
            print("   Height: \(hasHeight ? "✅ Available" : "❌ Missing")")
            print("   Weight: \(hasWeight ? "✅ Available" : "❌ Missing")")
            
            if hasHeight && hasWeight {
                print("✅ Both height and weight exist - proceeding to calculate BMI")
                self?.calculateAndSaveBMI(completion: completion)
            } else {
                print("❌ Missing height or weight - cannot calculate BMI")
                print("📝 User needs to provide missing data")
                DispatchQueue.main.async {
                    completion(nil)
                }
            }
        }
    }
    
    /// Calculate BMI from height and weight, then save to HealthKit
    private func calculateAndSaveBMI(completion: @escaping (Double?) -> Void) {
        print("🔍 calculateAndSaveBMI() called")
        let dispatchGroup = DispatchGroup()
        var heightInMeters: Double?
        var weightInKg: Double?
        
        // Fetch height
        print("📏 Fetching height from HealthKit...")
        dispatchGroup.enter()
        fetchMostRecentQuantity(for: .height) { height in
            print("📏 Height fetch completed: \(height?.description ?? "nil")")
            heightInMeters = height
            dispatchGroup.leave()
        }
        
        // Fetch weight
        print("⚖️ Fetching weight from HealthKit...")
        dispatchGroup.enter()
        fetchMostRecentQuantity(for: .bodyMass) { weight in
            print("⚖️ Weight fetch completed: \(weight?.description ?? "nil")")
            weightInKg = weight
            dispatchGroup.leave()
        }
        
        print("⏳ Waiting for height and weight queries to complete...")
        
        dispatchGroup.notify(queue: .main) { [weak self] in
            print("📊 Height fetch result: \(heightInMeters?.description ?? "nil")")
            print("📊 Weight fetch result: \(weightInKg?.description ?? "nil")")
            
            guard let height = heightInMeters, let weight = weightInKg else {
                print("❌ Cannot calculate BMI - missing data")
                fileLogger.error("Unable to calculate BMI: missing height (\(heightInMeters?.description ?? "nil")) or weight (\(weightInKg?.description ?? "nil"))", category: "HealthKit")
                print("🔙 Calling completion with nil to trigger input sheet")
                completion(nil)
                return
            }
            
            // Calculate BMI: weight (kg) / height² (m²)
            let bmi = weight / (height * height)
            fileLogger.info("📊 Calculated BMI: \(bmi) from height: \(height)m, weight: \(weight)kg", category: "HealthKit")
            
            // Save BMI to HealthKit
            self?.saveBMIToHealthKit(bmi: bmi) { success in
                if success {
                    fileLogger.info("✅ Successfully saved BMI to HealthKit: \(bmi)", category: "HealthKit")
                    completion(bmi)
                } else {
                    fileLogger.error("❌ Failed to save BMI to HealthKit, but returning calculated value: \(bmi)", category: "HealthKit")
                    // Still return the calculated value even if save failed
                    completion(bmi)
                }
            }
        }
    }
    
    /// Fetch the most recent quantity sample for a given type
    private func fetchMostRecentQuantity(for identifier: HKQuantityTypeIdentifier, completion: @escaping (Double?) -> Void) {
        print("🔍 fetchMostRecentQuantity for \(identifier.rawValue)")
        guard let quantityType = HKObjectType.quantityType(forIdentifier: identifier) else {
            print("❌ Could not create quantity type for \(identifier.rawValue)")
            completion(nil)
            return
        }
        
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: quantityType,
            predicate: nil,
            limit: 1,
            sortDescriptors: [sortDescriptor]
        ) { _, samples, error in
            print("📥 Query completed for \(identifier.rawValue)")
            
            if let error = error {
                print("❌ Error fetching \(identifier.rawValue): \(error.localizedDescription)")
                fileLogger.error("Error fetching \(identifier.rawValue): \(error.localizedDescription)", category: "HealthKit")
                completion(nil)
                return
            }
            
            guard let sample = samples?.first as? HKQuantitySample else {
                print("⚠️ No samples found for \(identifier.rawValue)")
                completion(nil)
                return
            }
            
            let unit: HKUnit
            switch identifier {
            case .height:
                unit = HKUnit.meter()
            case .bodyMass:
                unit = HKUnit.gramUnit(with: .kilo)
            default:
                unit = HKUnit.count()
            }
            
            let value = sample.quantity.doubleValue(for: unit)
            print("✅ Found \(identifier.rawValue): \(value)")
            completion(value)
        }
        
        print("🚀 Executing query for \(identifier.rawValue)")
        healthStore.execute(query)
    }
    
    /// Save BMI value to HealthKit
    private func saveBMIToHealthKit(bmi: Double, completion: @escaping (Bool) -> Void) {
        guard let bmiType = HKObjectType.quantityType(forIdentifier: .bodyMassIndex) else {
            completion(false)
            return
        }
        
        let bmiQuantity = HKQuantity(unit: HKUnit.count(), doubleValue: bmi)
        let bmiSample = HKQuantitySample(
            type: bmiType,
            quantity: bmiQuantity,
            start: Date(),
            end: Date()
        )
        
        healthStore.save(bmiSample) { success, error in
            if let error = error {
                fileLogger.error("Error saving BMI to HealthKit: \(error.localizedDescription)", category: "HealthKit")
                completion(false)
            } else {
                completion(success)
            }
        }
    }
    
    /// Save height to HealthKit
    func saveHeight(heightInMeters: Double, completion: @escaping (Bool) -> Void) {
        guard let heightType = HKObjectType.quantityType(forIdentifier: .height) else {
            fileLogger.error("Unable to create height quantity type", category: "HealthKit")
            completion(false)
            return
        }
        
        let heightQuantity = HKQuantity(unit: HKUnit.meter(), doubleValue: heightInMeters)
        let heightSample = HKQuantitySample(
            type: heightType,
            quantity: heightQuantity,
            start: Date(),
            end: Date()
        )
        
        healthStore.save(heightSample) { success, error in
            if let error = error {
                fileLogger.error("Error saving height to HealthKit: \(error.localizedDescription)", category: "HealthKit")
                completion(false)
            } else {
                fileLogger.info("✅ Successfully saved height to HealthKit: \(heightInMeters)m", category: "HealthKit")
                completion(success)
            }
        }
    }
    
    /// Save weight to HealthKit
    func saveWeight(weightInKg: Double, completion: @escaping (Bool) -> Void) {
        guard let weightType = HKObjectType.quantityType(forIdentifier: .bodyMass) else {
            fileLogger.error("Unable to create weight quantity type", category: "HealthKit")
            completion(false)
            return
        }
        
        let weightQuantity = HKQuantity(unit: HKUnit.gramUnit(with: .kilo), doubleValue: weightInKg)
        let weightSample = HKQuantitySample(
            type: weightType,
            quantity: weightQuantity,
            start: Date(),
            end: Date()
        )
        
        healthStore.save(weightSample) { success, error in
            if let error = error {
                fileLogger.error("Error saving weight to HealthKit: \(error.localizedDescription)", category: "HealthKit")
                completion(false)
            } else {
                fileLogger.info("✅ Successfully saved weight to HealthKit: \(weightInKg)kg", category: "HealthKit")
                completion(success)
            }
        }
    }
    
    /// Save height and weight, then calculate and save BMI
    func saveHeightWeightAndCalculateBMI(heightInMeters: Double, weightInKg: Double, completion: @escaping (Double?) -> Void) {
        let dispatchGroup = DispatchGroup()
        var heightSaved = false
        var weightSaved = false
        
        // Save height
        dispatchGroup.enter()
        saveHeight(heightInMeters: heightInMeters) { success in
            heightSaved = success
            dispatchGroup.leave()
        }
        
        // Save weight
        dispatchGroup.enter()
        saveWeight(weightInKg: weightInKg) { success in
            weightSaved = success
            dispatchGroup.leave()
        }
        
        dispatchGroup.notify(queue: .main) { [weak self] in
            guard heightSaved && weightSaved else {
                fileLogger.error("Failed to save height or weight to HealthKit", category: "HealthKit")
                completion(nil)
                return
            }
            
            // Calculate BMI
            let bmi = weightInKg / (heightInMeters * heightInMeters)
            fileLogger.info("📊 Calculated BMI from user input: \(bmi)", category: "HealthKit")
            
            // Save BMI to HealthKit
            self?.saveBMIToHealthKit(bmi: bmi) { success in
                if success {
                    fileLogger.info("✅ Successfully saved calculated BMI to HealthKit: \(bmi)", category: "HealthKit")
                    completion(bmi)
                } else {
                    fileLogger.error("❌ Failed to save BMI to HealthKit, but returning calculated value: \(bmi)", category: "HealthKit")
                    completion(bmi)
                }
            }
        }
    }
}
