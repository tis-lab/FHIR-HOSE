//
//  KTCMedicalVocabulary.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 3/31/26.
//

import Foundation

/// Medical terminology for VNRecognizeTextRequest.customWords.
/// Improves OCR accuracy on medical forms by telling Vision to look
/// specifically for these terms during its second-pass analysis.
enum KTCMedicalVocabulary {

    static let customWords: [String] = [
        // --- Common Drug Names (top prescribed) ---
        "acetaminophen", "amoxicillin", "atorvastatin", "lisinopril",
        "metformin", "amlodipine", "metoprolol", "omeprazole",
        "losartan", "gabapentin", "hydrochlorothiazide", "sertraline",
        "fluoxetine", "montelukast", "escitalopram", "bupropion",
        "pantoprazole", "rosuvastatin", "furosemide", "prednisone",
        "albuterol", "levothyroxine", "ibuprofen", "naproxen",
        "azithromycin", "ciprofloxacin", "cephalexin", "doxycycline",
        "tramadol", "cyclobenzaprine", "trazodone", "hydroxyzine",
        "duloxetine", "venlafaxine", "warfarin", "clopidogrel",
        "insulin", "glipizide", "sitagliptin", "empagliflozin",

        // --- Lab Test Names ---
        "hemoglobin", "hematocrit", "platelet", "leukocyte", "erythrocyte",
        "creatinine", "bilirubin", "albumin", "globulin", "triglycerides",
        "cholesterol", "glucose", "potassium", "sodium", "calcium",
        "magnesium", "phosphorus", "chloride", "bicarbonate",
        "troponin", "fibrinogen", "prothrombin", "hemoglobin A1c",
        "thyroid", "TSH", "thyroxine", "cortisol",
        "urinalysis", "hematuria", "proteinuria", "glycosuria",
        "lipid panel", "metabolic panel", "CBC", "BMP", "CMP",

        // --- Units & Measurements ---
        "mg/dL", "mEq/L", "mmol/L", "IU/mL", "ng/mL", "pg/mL",
        "mcg/dL", "mg/L", "g/dL", "U/L", "mL/min", "mm/hr",
        "mmHg", "bpm", "kg", "lbs", "cm", "ft", "in",
        "mcg", "mg", "mL", "cc",

        // --- Coding Systems ---
        "ICD-10", "CPT", "LOINC", "SNOMED", "SNOMED-CT",
        "NDC", "RxNorm", "HCPCS", "DRG", "NPI",
        "FHIR", "HL7", "CDA", "CCDA",

        // --- Clinical Terms ---
        "diagnosis", "prognosis", "etiology", "pathology",
        "comorbidity", "contraindication", "prophylaxis",
        "sublingual", "intramuscular", "intravenous", "subcutaneous",
        "bilateral", "unilateral", "proximal", "distal",
        "hypertension", "hypotension", "tachycardia", "bradycardia",
        "dyspnea", "edema", "cyanosis", "diaphoresis",
        "afebrile", "febrile", "normotensive",

        // --- Common Form Labels ---
        "DOB", "SSN", "MRN", "NPI", "DEA", "EIN",
        "guarantor", "subscriber", "copay", "co-pay", "coinsurance",
        "deductible", "formulary", "prior authorization",
        "PCP", "referring physician", "attending physician",
        "chief complaint", "reason for visit", "HPI",

        // --- Vital Signs ---
        "systolic", "diastolic", "pulse oximetry", "SpO2",
        "respiratory rate", "heart rate", "temperature",
        "blood pressure", "BMI", "body mass index",

        // --- Insurance / Admin ---
        "HIPAA", "PHI", "EOB", "PBM", "TPA",
        "preauthorization", "precertification", "adjudication",
        "policyholder", "beneficiary", "dependent",
    ]
}
