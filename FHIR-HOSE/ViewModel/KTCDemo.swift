//
//  KTCDemo.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import CoreML
import Foundation
import FoundationModels
import NaturalLanguage
import OSLog
import UIKit
import Vision

// MARK: - Form Autofill Backend Selection

enum FormAutofillBackend: String, CaseIterable, Identifiable {
    case visionOCR = "visionOCR"
    case layoutlmv3 = "layoutlmv3"
    case udop = "udop"
    case visionOCRv2 = "visionOCRv2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visionOCR: return "Vision OCR"
        case .layoutlmv3: return "LayoutLMv3"
        case .udop: return "UDOP"
        case .visionOCRv2: return "Vision OCR v2"
        }
    }

    private static let userDefaultsKey = "formAutofillBackend"

    static var persisted: FormAutofillBackend {
        get {
            guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
                  let value = FormAutofillBackend(rawValue: raw) else {
                return .visionOCR
            }
            return value
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}

// MARK: - Data Structures

struct KTCRecognizedLine: Identifiable {
    let id = UUID()
    let text: String
    let boundingBox: CGRect   // Vision normalized coords (origin bottom-left)
    let confidence: Float
    let pageIndex: Int
}

enum KTCFieldType: String {
    case text = "text"
    case checkbox = "checkbox"
    case signature = "signature"
    case date = "date"
}

struct KTCField: Identifiable {
    let id = UUID()
    var label: String
    var labelBoundingBox: CGRect
    var fieldType: KTCFieldType = .text
    var mappedKeypath: String?
    var value: String = ""
    var matchConfidence: Double = 0  // 0-1 confidence score for the match
    var matchMethod: String?  // How the match was made (synonym, embedding, token)
    var detectedValue: String?  // Value found on the form via spatial analysis
    var valueBoundingBox: CGRect?  // Where the value was found
    var isChecked: Bool?  // For checkbox fields
    var adjustedValueBox: CGRect?  // User-adjusted position for the value (normalized Vision coords)
    var isSkipped: Bool = false  // User marked as N/A / not applicable
    var skippedValue: String?  // Stashed value before N/A, so Undo can restore it
}

/// Represents a detected checkbox on the form.
struct KTCCheckbox {
    let boundingBox: CGRect
    var isChecked: Bool
    var associatedText: String?  // Text near the checkbox (e.g., "Male", "Female")
    var groupId: UUID?  // If part of a checkbox group
}

/// Represents a group of mutually exclusive checkboxes (e.g., Male/Female, Yes/No).
struct KTCCheckboxGroup: Identifiable {
    let id = UUID()
    let boundingBox: CGRect  // Combined bounding box of the group
    var options: [KTCCheckbox]  // The checkboxes in this group
    var groupLabel: String?  // e.g., "Sex", "Gender" - the label for the whole group
    var mappedKeypath: String?  // Patient data keypath this group maps to
    var selectedIndex: Int?  // Which option is selected (auto-filled)
}

// MARK: - ViewModel

@MainActor
final class KTCDemo: ObservableObject {
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC")

    enum Phase {
        case landing
        case scanning
        case analyzing
        case editing
        case error(String)
    }

    @Published var phase: Phase = .landing
    @Published var backend: FormAutofillBackend = FormAutofillBackend.persisted {
        didSet {
            FormAutofillBackend.persisted = self.backend
            self.logger.info("Form autofill backend changed to: \(self.backend.displayName)")
        }
    }
    @Published var pages: [UIImage] = []
    @Published var recognizedLines: [KTCRecognizedLine] = []
    @Published var fields: [KTCField] = []
    @Published var checkboxGroups: [KTCCheckboxGroup] = []  // Detected checkbox groups
    @Published var patientData: [String: String] = [:]  // flattened keypath → value
    @Published var signatureImage: UIImage? = nil  // User's signature as UIImage
    @Published var hasSignature: Bool = false  // Whether user has signed
    @Published var signatureFieldId: UUID? = nil  // Which field to place signature at (if any)
    @Published var signatureSize: CGSize = CGSize(width: 60, height: 24)  // Adjustable signature display size (at 400x600 reference scale)
    @Published var signatureNormalizedPosition: CGPoint? = nil  // Manual position in normalized coords (0-1)

    /// Sorted keypath list for Picker UI.
    var sortedKeypaths: [String] {
        patientData.keys.sorted()
    }

    /// Human-readable display name for a keypath, e.g. "patient.address.city" → "Address > City".
    func displayName(for keypath: String) -> String {
        // Special display names for computed fields
        switch keypath {
        case "_computed.todayDate": return "Today's Date"
        case "_computed.patientAge": return "Patient Age"
        case "_computed.dobFormatted": return "DOB (Formatted)"
        case "patient.fullName": return "Full Name"
        case "patient.fullAddress": return "Full Address"
        default: break
        }
        let parts = keypath.components(separatedBy: ".")
        // Drop known prefixes
        let meaningful: [String]
        if parts.first == "patient" || parts.first == "_computed" {
            meaningful = Array(parts.dropFirst())
        } else {
            meaningful = parts
        }
        return meaningful.map { Self.camelCaseToTitleCase($0) }.joined(separator: " > ")
    }

    /// Convert camelCase to Title Case words, also splitting before digits.
    /// "postalCode" → "Postal Code", "line1" → "Line 1", "memberId" → "Member ID"
    private static func camelCaseToTitleCase(_ text: String) -> String {
        var words: [String] = []
        var current = ""
        var prevWasDigit = false
        for char in text {
            let isDigit = char.isNumber
            if (char.isUppercase || (isDigit && !prevWasDigit)) && !current.isEmpty {
                words.append(current)
                current = String(char).lowercased()
            } else {
                current += String(char)
            }
            prevWasDigit = isDigit
        }
        if !current.isEmpty { words.append(current) }
        // Title-case each word, with special handling for "id" → "ID"
        return words.map { word in
            let lower = word.lowercased()
            if lower == "id" { return "ID" }
            if lower == "dob" { return "DOB" }
            if lower == "ssn" { return "SSN" }
            if lower == "mrn" { return "MRN" }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: - Field editing

    func updateFieldKeypath(id: UUID, newKeypath: String?) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        fields[idx].mappedKeypath = newKeypath
        if let kp = newKeypath, let val = patientData[kp] {
            fields[idx].value = val
        } else {
            fields[idx].value = ""
        }
    }

    func resetField(id: UUID) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        if let kp = fields[idx].mappedKeypath, let val = patientData[kp] {
            fields[idx].value = val
        }
    }

    /// Update the value position for a field (used when user drags the badge).
    /// Position is stored in normalized Vision coordinates (0-1).
    func updateFieldValueBox(id: UUID, normalizedBox: CGRect) {
        guard let idx = fields.firstIndex(where: { $0.id == id }) else { return }
        // Validate and clamp the normalized box to [0, 1] range
        let clampedBox = CGRect(
            x: max(0, min(1, normalizedBox.origin.x)),
            y: max(0, min(1, normalizedBox.origin.y)),
            width: max(0.01, min(1, normalizedBox.width)),
            height: max(0.01, min(1, normalizedBox.height))
        )
        fields[idx].adjustedValueBox = clampedBox
        let fieldLabel = fields[idx].label
        logger.info("Updated value box for field '\(fieldLabel)'")
    }

    /// Set which field should receive the signature.
    func setSignatureField(id: UUID?) {
        signatureFieldId = id
        if let id = id, let field = fields.first(where: { $0.id == id }) {
            logger.info("Signature will be placed at field: '\(field.label)'")
        } else {
            logger.info("Signature field cleared")
        }
    }

    /// Get the field designated for signature placement.
    var signatureField: KTCField? {
        if let id = signatureFieldId {
            return fields.first { $0.id == id }
        }
        // Fall back to auto-detected signature field
        return fields.first { $0.fieldType == .signature }
    }

    /// Update signature position (for manual dragging).
    /// Position should be in normalized coordinates (0-1).
    func updateSignatureNormalizedPosition(_ normalizedPos: CGPoint) {
        // Validate and clamp to [0, 1] range
        let clampedPos = CGPoint(
            x: max(0, min(1, normalizedPos.x)),
            y: max(0, min(1, normalizedPos.y))
        )
        signatureNormalizedPosition = clampedPos
        logger.info("Signature position updated to normalized (\(clampedPos.x), \(clampedPos.y))")
    }

    // MARK: - Checkbox Group Editing

    /// Toggle a checkbox within a group. For multi-option groups, only one can be selected.
    func toggleCheckbox(groupIndex: Int, optionIndex: Int) {
        guard groupIndex < checkboxGroups.count,
              optionIndex < checkboxGroups[groupIndex].options.count else { return }

        let isMultiOption = checkboxGroups[groupIndex].options.count > 1

        if isMultiOption {
            // Mutually exclusive: uncheck all others, check this one
            for i in checkboxGroups[groupIndex].options.indices {
                checkboxGroups[groupIndex].options[i].isChecked = (i == optionIndex)
            }
            checkboxGroups[groupIndex].selectedIndex = optionIndex
        } else {
            // Single checkbox: just toggle it
            checkboxGroups[groupIndex].options[optionIndex].isChecked.toggle()
            checkboxGroups[groupIndex].selectedIndex = checkboxGroups[groupIndex].options[optionIndex].isChecked ? 0 : nil
        }

        logger.info("Toggled checkbox group \(groupIndex) option \(optionIndex)")
    }

    // MARK: - Signature Handling

    /// Update the signature image.
    func updateSignature(_ image: UIImage?) {
        signatureImage = image
        hasSignature = image != nil
        let hasSig = hasSignature
        logger.info("Signature updated: hasSignature=\(hasSig)")
    }

    /// Clear the signature.
    func clearSignature() {
        signatureImage = nil
        hasSignature = false
        logger.info("Signature cleared")
    }

    // MARK: - Export

    /// Build a readable text summary of all filled fields.
    func filledDataText() -> String {
        var lines: [String] = []
        lines.append("Kill-The-Clipboard — Filled Form Data")
        lines.append(String(repeating: "=", count: 38))
        lines.append("")

        // Checkbox groups
        let filledGroups = checkboxGroups.filter { $0.selectedIndex != nil && $0.options.count > 1 }
        if !filledGroups.isEmpty {
            lines.append("Checkbox Selections:")
            for group in filledGroups {
                let label = group.groupLabel ?? "Choice"
                if let idx = group.selectedIndex, idx < group.options.count {
                    let selected = group.options[idx].associatedText ?? "Option \(idx + 1)"
                    lines.append("  \(label): \(selected)")
                }
            }
            lines.append("")
        }

        // Text fields
        let matched = fields.filter { $0.mappedKeypath != nil && !$0.value.isEmpty }
        let unmatched = fields.filter { $0.mappedKeypath == nil }

        if matched.isEmpty && filledGroups.isEmpty {
            lines.append("No fields were matched to patient data.")
        } else if !matched.isEmpty {
            lines.append("Text Fields:")
            for field in matched {
                lines.append("  \(field.label): \(field.value)")
            }
        }

        if !unmatched.isEmpty {
            lines.append("")
            lines.append("Unmatched Fields:")
            for field in unmatched {
                let val = field.value.isEmpty ? "(empty)" : field.value
                lines.append("  - \(field.label): \(val)")
            }
        }

        // Signature status
        if hasSignature {
            lines.append("")
            lines.append("Signature: ✓ Signed")
        }

        lines.append("")
        lines.append("Generated by FHIR-HOSE KTC Demo")
        return lines.joined(separator: "\n")
    }

    /// Copy the filled-data summary to the system clipboard.
    func copyToClipboard() {
        let text = filledDataText()
        UIPasteboard.general.string = text
        logger.info("Copied filled data to clipboard (\(text.count) chars)")
    }

    /// Generate a PDF with the scanned image as background and filled values drawn on.
    /// Returns a temporary file URL for sharing, or nil on failure.
    func generateFilledPDF() -> URL? {
        guard let image = pages.first else { return nil }

        let pageSize = CGSize(width: image.size.width, height: image.size.height)
        let pdfData = NSMutableData()

        UIGraphicsBeginPDFContextToData(pdfData, CGRect(origin: .zero, size: pageSize), [
            kCGPDFContextTitle as String: "Filled Form" as NSString
        ])
        UIGraphicsBeginPDFPage()

        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndPDFContext()
            return nil
        }

        // Draw the scanned image as background
        image.draw(in: CGRect(origin: .zero, size: pageSize))

        // Draw checkmarks for selected checkboxes
        for group in checkboxGroups {
            guard let selectedIdx = group.selectedIndex, selectedIdx < group.options.count else { continue }
            let option = group.options[selectedIdx]
            let box = option.boundingBox

            // Convert Vision coords to PDF coords
            let x = box.origin.x * pageSize.width
            let y = (1.0 - box.origin.y - box.height) * pageSize.height
            let h = box.height * pageSize.height

            // Draw an X mark inside the checkbox (more visible than ✓)
            let checkSize = max(10, min(18, h * 0.7))
            let checkFont = UIFont.systemFont(ofSize: checkSize, weight: .bold)
            let checkAttrs: [NSAttributedString.Key: Any] = [
                .font: checkFont,
                .foregroundColor: UIColor.black
            ]
            let checkStr = "X" as NSString
            checkStr.draw(at: CGPoint(x: x + 2, y: y), withAttributes: checkAttrs)
        }

        // Build set of keypaths that are handled by checkbox groups (don't draw as text)
        let checkboxKeypaths = Set(checkboxGroups.compactMap { $0.mappedKeypath })

        // Draw filled values - detect if input area is below or to the right
        let filledFields = fields.filter { !$0.value.isEmpty }
        for field in filledFields {
            // Skip fields that are handled by checkbox groups
            if let keypath = field.mappedKeypath, checkboxKeypaths.contains(keypath) {
                continue
            }

            // Skip checkbox-type fields (they're handled separately)
            if field.fieldType == .checkbox {
                continue
            }

            // Skip signature fields (handled separately)
            if field.fieldType == .signature {
                continue
            }

            // Skip single-letter values that are likely checkbox indicators (M, F, Y, N)
            let trimmedValue = field.value.trimmingCharacters(in: .whitespaces)
            if trimmedValue.count == 1 && "MFYNmfyn".contains(trimmedValue) {
                continue
            }

            // Compute font/text size first (needed for vertical centering)
            let labelBox = field.labelBoundingBox
            let labelH = labelBox.height * pageSize.height
            let fontSize = max(10, min(18, labelH * 0.8))
            let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]
            let valueStr = field.value as NSString
            let textSize = valueStr.size(withAttributes: attributes)

            // Calculate position — mirrors overlay's calculateDefaultValueRect logic
            let valueX: CGFloat
            let valueY: CGFloat

            if let adjustedBox = field.adjustedValueBox {
                // The overlay positions the badge using .position(x: rect.midX, y: rect.midY).
                // The badge has .padding(.horizontal, 6) so the text left edge is at
                // badgeOriginX + 6pt in screen coords. We approximate this padding offset
                // in normalized coords using the ratio: 6 / estimatedBadgeScreenWidth.
                let charCount = CGFloat(field.value.count)
                let estBadgeWidth = max(30.0, charCount * 6.0 + 16.0)
                let padFraction = 10.0 / estBadgeWidth
                valueX = (adjustedBox.origin.x + padFraction * adjustedBox.width) * pageSize.width

                // Vertically center at the badge's center point
                let centerPdfY = (1.0 - adjustedBox.origin.y - adjustedBox.height / 2) * pageSize.height
                valueY = centerPdfY - textSize.height / 2
            } else {
                let box = field.labelBoundingBox
                let x = box.origin.x * pageSize.width
                let y = (1.0 - box.origin.y - box.height) * pageSize.height
                let w = box.width * pageSize.width
                let h = box.height * pageSize.height

                // Same heuristic as overlay: short labels without ":" → below, else → right
                let isShortLabel = field.label.count < 20 && !field.label.contains(":")
                if isShortLabel {
                    valueX = x
                    valueY = y + h + 2  // just below label (matches overlay's +2 offset)
                } else {
                    valueX = x + w + 4  // right of label (matches overlay's +4 offset)
                    valueY = y + (h - textSize.height) / 2  // vertically centered with label
                }
            }

            // Draw white background rect for legibility
            let textRect = CGRect(x: valueX - 2, y: valueY - 1, width: textSize.width + 4, height: textSize.height + 2)
            context.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
            context.fill(textRect)

            // Draw the text
            valueStr.draw(at: CGPoint(x: valueX, y: valueY), withAttributes: attributes)
        }

        // Draw signature if present
        if self.hasSignature, let sigImage = self.signatureImage {
            let sigWidth = self.signatureSize.width * (pageSize.width / 400)  // Scale to page
            let sigHeight = self.signatureSize.height * (pageSize.height / 600)
            let sigRect: CGRect

            if let normalizedPos = self.signatureNormalizedPosition {
                // User manually positioned the signature
                let x = normalizedPos.x * pageSize.width - sigWidth / 2
                let y = (1.0 - normalizedPos.y) * pageSize.height - sigHeight / 2
                sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
            } else if let field = self.signatureField {
                // Place to the right of the label (like text values)
                let box = field.labelBoundingBox
                let x = (box.origin.x + box.width) * pageSize.width + 6
                let y = (1.0 - box.origin.y - box.height) * pageSize.height
                sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
            } else {
                // Default: bottom right area
                sigRect = CGRect(
                    x: pageSize.width - sigWidth - 40,
                    y: pageSize.height - sigHeight - 60,
                    width: sigWidth,
                    height: sigHeight
                )
            }

            sigImage.draw(in: sigRect)
        }

        UIGraphicsEndPDFContext()

        // Save to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KTC-FilledForm.pdf")
        do {
            try pdfData.write(to: tempURL, options: .atomic)
            logger.info("Generated filled PDF at \(tempURL.path) (\(pdfData.length) bytes, \(filledFields.count) values)")
            return tempURL
        } catch {
            logger.error("Failed to write PDF: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Scan / Pick handlers

    func handleScannedPages(_ images: [UIImage]) {
        guard !images.isEmpty else {
            logger.warning("Scanner returned zero pages")
            phase = .landing
            return
        }
        logger.info("Received \(images.count) scanned page(s)")
        pages = images
        phase = .analyzing
        runOCR()
    }

    func handlePickedPhoto(_ image: UIImage) {
        logger.info("Received picked photo")
        pages = [image]
        phase = .analyzing
        runOCR()
    }

    func cancelScan() {
        logger.info("Scan/pick cancelled")
        phase = .landing
    }

    // MARK: - OCR + Mapping Pipeline

    private func runOCR() {
        guard let image = pages.first, let cgImage = image.cgImage else {
            phase = .error("Could not read the scanned image.")
            return
        }

        logger.info("Pipeline starting — backend: \(self.backend.displayName), image: \(cgImage.width)x\(cgImage.height)")

        switch backend {
        case .visionOCR:
            runVisionOCRPipeline(cgImage: cgImage)
        case .layoutlmv3:
            runLayoutLMv3Pipeline(cgImage: cgImage)
        case .udop:
            runUDOPPipeline(cgImage: cgImage)
        case .visionOCRv2:
            runVisionOCRv2Pipeline(cgImage: cgImage)
        }
    }

    // MARK: - Vision OCR Pipeline (old way)

    private func runVisionOCRPipeline(cgImage: CGImage) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let lines = try await Self.performOCR(on: cgImage, pageIndex: 0)
                var detectedFields = Self.extractLabelCandidates(from: lines)
                let checkboxes = Self.detectCheckboxes(from: lines)
                var checkboxGroups = Self.groupCheckboxes(checkboxes, allLines: lines)
                Self.classifyFieldTypes(&detectedFields, checkboxes: checkboxes, allLines: lines)
                Self.associateValuesWithLabels(&detectedFields, allLines: lines)
                let data = KTCPatientDataLoader.loadAndFlatten()
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)
                Self.autoCheckCheckboxGroups(&checkboxGroups, using: data)

                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.checkboxGroups = checkboxGroups
                    self.patientData = data
                    let withValues = detectedFields.filter { $0.detectedValue != nil }.count
                    let checkboxFields = detectedFields.filter { $0.fieldType == .checkbox }.count
                    let groupCount = checkboxGroups.count
                    let autoChecked = checkboxGroups.filter { $0.selectedIndex != nil }.count
                    self.logger.info("[VisionOCR] Complete: \(lines.count) lines, \(detectedFields.count) fields (\(withValues) detected, \(checkboxFields) checkboxes, \(groupCount) groups, \(autoChecked) auto-checked), \(data.count) keypaths")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.phase = .editing
                }
            } catch {
                await MainActor.run {
                    self.logger.error("[VisionOCR] Failed: \(error.localizedDescription)")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.phase = .error("OCR failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Vision OCR v2 Pipeline (enhanced preprocessing + tuned OCR)

    private func runVisionOCRv2Pipeline(cgImage: CGImage) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                // 1 — Preprocess: CIDocumentEnhancer -> grayscale -> sharpen
                let enhanced = KTCImagePreprocessor.enhance(cgImage)

                // 2 — Tuned OCR with medical vocabulary
                let lines = try await Self.performOCRv2(on: enhanced, pageIndex: 0)

                // 3 — Same heuristic pipeline as v1
                var detectedFields = Self.extractLabelCandidates(from: lines)
                let checkboxes = Self.detectCheckboxes(from: lines)
                var checkboxGroups = Self.groupCheckboxes(checkboxes, allLines: lines)
                Self.classifyFieldTypes(&detectedFields, checkboxes: checkboxes, allLines: lines)
                Self.associateValuesWithLabels(&detectedFields, allLines: lines)

                // 4 — Visual checkbox detection on the enhanced image
                let visualCheckboxes = try Self.detectCheckboxShapes(
                    in: enhanced, ocrLines: lines,
                    logger: Logger(subsystem: "com.fhirhose.app", category: "KTC.v2")
                )
                // Merge visual checkboxes that don't overlap with text-detected ones
                let existingBoxes = checkboxes.map(\.boundingBox)
                for vBox in visualCheckboxes {
                    let overlaps = existingBoxes.contains { existing in
                        existing.intersects(vBox)
                    }
                    if !overlaps {
                        let checkbox = KTCCheckbox(
                            boundingBox: vBox,
                            isChecked: false,
                            associatedText: nil
                        )
                        // Find nearest text to associate
                        var nearest: (text: String, dist: CGFloat) = ("", .greatestFiniteMagnitude)
                        for line in lines {
                            let dx = line.boundingBox.midX - vBox.midX
                            let dy = line.boundingBox.midY - vBox.midY
                            let dist = sqrt(dx * dx + dy * dy)
                            if dist < nearest.dist && dist < 0.1 {
                                nearest = (line.text, dist)
                            }
                        }
                        var cb = checkbox
                        if !nearest.text.isEmpty {
                            cb.associatedText = nearest.text
                        }
                        // Add to a single-checkbox group
                        let group = KTCCheckboxGroup(
                            boundingBox: vBox,
                            options: [cb]
                        )
                        checkboxGroups.append(group)
                    }
                }

                // 5 — Apple Intelligence for field values + checkbox groups (iOS 26+)
                if #available(iOS 26, *) {
                    let fullOCRText = lines.map(\.text).joined(separator: "\n")

                    let fieldsToQuery = detectedFields.enumerated().filter { (_, field) in
                        field.fieldType != .checkbox && field.fieldType != .signature && field.detectedValue == nil
                    }
                    if !fieldsToQuery.isEmpty {
                        let log = Logger(subsystem: "com.fhirhose.app", category: "KTC.v2")
                        log.info("[v2] \(fieldsToQuery.count) fields without values — querying AI")
                        let fieldLabels = fieldsToQuery.map { "\($0.offset): \($0.element.label)" }.joined(separator: "\n")
                        let extracted = try await Self.extractFieldsWithAppleIntelligence(
                            ocrText: fullOCRText, fieldLabels: fieldLabels, logger: log
                        )
                        for (idx, value) in extracted {
                            if idx < detectedFields.count {
                                detectedFields[idx].detectedValue = value
                                detectedFields[idx].value = value
                            }
                        }
                    }

                    let aiCheckboxGroups = try await Self.detectCheckboxGroupsWithAI(
                        ocrText: lines.map(\.text).joined(separator: "\n"),
                        logger: Logger(subsystem: "com.fhirhose.app", category: "KTC.v2")
                    )
                    if !aiCheckboxGroups.isEmpty {
                        checkboxGroups.append(contentsOf: aiCheckboxGroups)
                    }
                }

                // 6 — Patient data mapping
                let data = KTCPatientDataLoader.loadAndFlatten()
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)
                Self.autoCheckCheckboxGroups(&checkboxGroups, using: data)

                let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0)
                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.checkboxGroups = checkboxGroups
                    self.patientData = data
                    let withValues = detectedFields.filter { $0.detectedValue != nil }.count
                    let checkboxCount = checkboxGroups.count
                    let autoChecked = checkboxGroups.filter { $0.selectedIndex != nil }.count
                    self.logger.info("[VisionOCR-v2] Complete in \(elapsed)s: \(lines.count) lines, \(detectedFields.count) fields (\(withValues) with values), \(checkboxCount) groups (\(autoChecked) auto-checked)")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.phase = .editing
                }
            } catch {
                await MainActor.run {
                    self.logger.error("[VisionOCR-v2] Failed: \(error.localizedDescription)")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.phase = .error("Vision OCR v2 failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Tuned OCR for Vision OCR v2 — medical vocabulary, lower text height threshold.
    private nonisolated static func performOCRv2(on cgImage: CGImage, pageIndex: Int) async throws -> [KTCRecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines: [KTCRecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return KTCRecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence,
                        pageIndex: pageIndex
                    )
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.automaticallyDetectsLanguage = false
            request.minimumTextHeight = 0.008
            request.customWords = KTCMedicalVocabulary.customWords
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - LayoutLMv3 Pipeline (token classification for form understanding)

    private struct LayoutLMv3WordBox {
        let word: String
        let boundingBox: CGRect
    }

    private func runLayoutLMv3Pipeline(cgImage: CGImage) {
        let log = Logger(subsystem: "com.fhirhose.app", category: "KTC.LayoutLMv3")
        log.info("[LayoutLMv3] Starting pipeline for image \(cgImage.width)x\(cgImage.height)")
        print("[LayoutLMv3] Starting pipeline for image \(cgImage.width)x\(cgImage.height)")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                // 1 — Tokenizer (vocab.json from bundle, e.g. from HuggingFace model)
                guard let vocabURL = Bundle.main.url(forResource: "vocab", withExtension: "json", subdirectory: "LayoutLMv3")
                    ?? Bundle.main.url(forResource: "vocab", withExtension: "json") else {
                    throw NSError(domain: "LayoutLMv3", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "vocab.json not found. Add LayoutLMv3 vocab to bundle (e.g. from HuggingFace nnul/layoutlmv3-finetuned-funsd)."])
                }
                let tokenizer = try LayoutLMv3Tokenizer(vocabURL: vocabURL)
                log.info("[LayoutLMv3] Tokenizer loaded")
                print("[LayoutLMv3] Tokenizer loaded")

                // 2 — Core ML model (Xcode compiles .mlpackage → .mlmodelc at build time)
                guard let modelURL = Bundle.main.url(forResource: "LayoutLMv3", withExtension: "mlmodelc", subdirectory: nil)
                    ?? Bundle.main.url(forResource: "LayoutLMv3", withExtension: "mlpackage", subdirectory: nil) else {
                    throw NSError(domain: "LayoutLMv3", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "LayoutLMv3.mlpackage not found. Export LayoutLMv3ForTokenClassification (FUNSD) to Core ML and add to app bundle."])
                }
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let model = try MLModel(contentsOf: modelURL, configuration: config)
                let loadTime = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0)
                log.info("[LayoutLMv3] Model loaded in \(loadTime)s")
                print("[LayoutLMv3] Model loaded in \(loadTime)s")

                // 3 — Word-level OCR (same as UDOP path)
                let wordBoxes = try await Self.layoutlmv3WordOCR(cgImage)
                let words = wordBoxes.map(\.word)
                let boxes1000 = wordBoxes.map { wb in
                    let b = wb.boundingBox
                    return [
                        Int32(max(0, min(1000, Int(b.minX * 1000)))),
                        Int32(max(0, min(1000, Int((1 - b.maxY) * 1000)))),
                        Int32(max(0, min(1000, Int(b.maxX * 1000)))),
                        Int32(max(0, min(1000, Int((1 - b.minY) * 1000)))),
                    ]
                }
                log.info("[LayoutLMv3] OCR found \(words.count) words")
                print("[LayoutLMv3] OCR found \(words.count) words")

                let maxLen = 512
                let (inputIds, bboxes, tokenToWordIndex) = tokenizer.encode(words: words, boxes: boxes1000, maxLength: maxLen)
                let realCount = inputIds.firstIndex(of: tokenizer.padTokenId) ?? inputIds.count
                let attentionMask = (0..<maxLen).map { i in Int32(i < realCount ? 1 : 0) }

                // 4 — Image 224×224 (LayoutLMv3 base)
                let pixelValues = try Self.layoutlmv3PreprocessImage(cgImage)
                log.info("[LayoutLMv3] Image preprocessed 224×224")
                print("[LayoutLMv3] Image preprocessed 224×224")

                // 5 — Run model
                let (fieldsFromModel, linesFromModel) = try Self.layoutlmv3RunAndDecode(
                    model: model,
                    inputIds: inputIds,
                    bboxes: bboxes,
                    attentionMask: attentionMask,
                    pixelValues: pixelValues,
                    wordBoxes: wordBoxes,
                    tokenToWordIndex: tokenToWordIndex,
                    numLabels: 7
                )
                log.info("[LayoutLMv3] Decoded \(fieldsFromModel.count) fields, \(linesFromModel.count) lines")
                print("[LayoutLMv3] Decoded \(fieldsFromModel.count) fields, \(linesFromModel.count) lines")

                // Also run line-level OCR for heuristic field detection as fallback
                let ocrLines = try await Self.performOCR(on: cgImage, pageIndex: 0)
                let heuristicFields = Self.extractLabelCandidates(from: ocrLines)
                let checkboxes = Self.detectCheckboxes(from: ocrLines)
                var checkboxGroups = Self.groupCheckboxes(checkboxes, allLines: ocrLines)
                log.info("[LayoutLMv3] Heuristic fallback: \(heuristicFields.count) fields, \(checkboxGroups.count) checkbox groups")
                print("[LayoutLMv3] Heuristic fallback: \(heuristicFields.count) fields, \(checkboxGroups.count) checkbox groups")

                // Merge: use model fields if any, otherwise fall back to heuristic
                var detectedFields = fieldsFromModel.isEmpty ? heuristicFields : fieldsFromModel
                if !fieldsFromModel.isEmpty {
                    // Supplement model fields with heuristic fields it may have missed
                    Self.classifyFieldTypes(&detectedFields, checkboxes: checkboxes, allLines: ocrLines)
                    Self.associateValuesWithLabels(&detectedFields, allLines: ocrLines)
                }

                // Use display lines from OCR (more complete than word-level model lines)
                let displayLines = ocrLines
                let fullOCRText = ocrLines.map(\.text).joined(separator: "\n")

                // Apple Intelligence: field values + checkbox groups
                if #available(iOS 26, *) {
                    let fieldsToQuery = detectedFields.enumerated().filter { (_, field) in
                        field.fieldType != .checkbox && field.fieldType != .signature && field.detectedValue == nil
                    }
                    if !fieldsToQuery.isEmpty {
                        log.info("[LayoutLMv3] \(fieldsToQuery.count) fields without values — querying AI")
                        print("[LayoutLMv3] \(fieldsToQuery.count) fields without values — querying AI")
                        let fieldLabels = fieldsToQuery.map { "\($0.offset): \($0.element.label)" }.joined(separator: "\n")
                        let extracted = try await Self.extractFieldsWithAppleIntelligence(
                            ocrText: fullOCRText, fieldLabels: fieldLabels, logger: log
                        )
                        for (idx, value) in extracted {
                            if idx < detectedFields.count {
                                detectedFields[idx].detectedValue = value
                                detectedFields[idx].value = value
                                print("[LayoutLMv3] AI filled [\(idx)] \(detectedFields[idx].label) = \"\(value)\"")
                            }
                        }
                    }

                    let aiCheckboxGroups = try await Self.detectCheckboxGroupsWithAI(
                        ocrText: fullOCRText, logger: log
                    )
                    if !aiCheckboxGroups.isEmpty {
                        checkboxGroups.append(contentsOf: aiCheckboxGroups)
                        print("[LayoutLMv3] AI detected \(aiCheckboxGroups.count) checkbox groups, total: \(checkboxGroups.count)")
                    }
                }

                let data = KTCPatientDataLoader.loadAndFlatten()
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)
                Self.autoCheckCheckboxGroups(&checkboxGroups, using: data)

                await MainActor.run {
                    self.recognizedLines = displayLines
                    self.fields = detectedFields
                    self.checkboxGroups = checkboxGroups
                    self.patientData = data
                    let total = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - t0)
                    let withValues = detectedFields.filter { $0.detectedValue != nil }.count
                    self.logger.info("[LayoutLMv3] Complete in \(total)s: \(detectedFields.count) fields (\(withValues) with values), \(checkboxGroups.count) checkbox groups")
                    print("[LayoutLMv3] Complete in \(total)s: \(detectedFields.count) fields (\(withValues) with values), \(checkboxGroups.count) checkbox groups")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.phase = .editing
                }
            } catch {
                await MainActor.run {
                    self.logger.error("[LayoutLMv3] Failed: \(error.localizedDescription)")
                    print("[LayoutLMv3] Failed: \(error.localizedDescription)")
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.phase = .error("LayoutLMv3 failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func layoutlmv3WordOCR(_ cgImage: CGImage) async throws -> [LayoutLMv3WordBox] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let obs = request.results else { return [] }
        var boxes: [LayoutLMv3WordBox] = []
        for obs in obs {
            let topCands = obs.topCandidates(1)
            guard let line = topCands.first?.string else { continue }
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
                .map(String.init)
            if words.isEmpty {
                boxes.append(LayoutLMv3WordBox(word: line, boundingBox: obs.boundingBox))
            } else {
                for w in words where !w.isEmpty {
                    boxes.append(LayoutLMv3WordBox(word: w, boundingBox: obs.boundingBox))
                }
            }
        }
        return boxes
    }

    private nonisolated static func layoutlmv3PreprocessImage(_ cgImage: CGImage) throws -> MLMultiArray {
        let w = 224
        let h = 224
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "LayoutLMv3", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot create CGContext"])
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else {
            throw NSError(domain: "LayoutLMv3", code: 4, userInfo: [NSLocalizedDescriptionKey: "No pixel data"])
        }
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let arr = try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(arr.dataPointer))
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std: [Float] = [0.229, 0.224, 0.225]
        let chStride = h * w
        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let r = Float(px[i]) / 255.0
                let g = Float(px[i + 1]) / 255.0
                let b = Float(px[i + 2]) / 255.0
                ptr[0 * chStride + row * w + col] = (r - mean[0]) / std[0]
                ptr[1 * chStride + row * w + col] = (g - mean[1]) / std[1]
                ptr[2 * chStride + row * w + col] = (b - mean[2]) / std[2]
            }
        }
        return arr
    }

    /// FUNSD-style labels: O, B-QUESTION, I-QUESTION, B-ANSWER, I-ANSWER, B-HEADER, I-HEADER
    // Standard FUNSD order (HuggingFace: O, B-HEADER, I-HEADER, B-QUESTION, I-QUESTION, B-ANSWER, I-ANSWER). If your model uses a different id2label, reorder this array.
    private static let layoutlmv3LabelNames = ["O", "B-HEADER", "I-HEADER", "B-QUESTION", "I-QUESTION", "B-ANSWER", "I-ANSWER"]

    private nonisolated static func layoutlmv3RunAndDecode(
        model: MLModel,
        inputIds: [Int32],
        bboxes: [[Int32]],
        attentionMask: [Int32],
        pixelValues: MLMultiArray,
        wordBoxes: [LayoutLMv3WordBox],
        tokenToWordIndex: [Int],
        numLabels: Int
    ) throws -> (fields: [KTCField], lines: [KTCRecognizedLine]) {
        let seqLen = inputIds.count
        let idsArr = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let maskArr = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let bboxArr = try MLMultiArray(shape: [1, NSNumber(value: seqLen), 4], dataType: .int32)
        let idsPtr = UnsafeMutablePointer<Int32>(OpaquePointer(idsArr.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(maskArr.dataPointer))
        let bboxPtr = UnsafeMutablePointer<Int32>(OpaquePointer(bboxArr.dataPointer))
        for i in 0..<seqLen {
            idsPtr[i] = inputIds[i]
            maskPtr[i] = attentionMask[i]
            for j in 0..<4 { bboxPtr[i * 4 + j] = bboxes[i][j] }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: idsArr),
            "attention_mask": MLFeatureValue(multiArray: maskArr),
            "bbox": MLFeatureValue(multiArray: bboxArr),
            "pixel_values": MLFeatureValue(multiArray: pixelValues),
        ])
        let result = try model.prediction(from: provider)
        guard let logits = result.featureValue(for: "logits")?.multiArrayValue else {
            throw NSError(domain: "LayoutLMv3", code: 5, userInfo: [NSLocalizedDescriptionKey: "Model did not return logits"])
        }
        let strides = logits.strides.map { $0.intValue }
        let seqStride = strides.count > 2 ? strides[1] : numLabels
        let labelStride = strides.count > 2 ? strides[2] : 1
        var predictions: [Int] = []
        for pos in 0..<seqLen {
            var best: Float = -.infinity
            var bestLabel = 0
            if logits.dataType == .float16 {
                let basePtr = UnsafePointer<Float16>(OpaquePointer(logits.dataPointer))
                for l in 0..<numLabels {
                    let val = Float(basePtr[pos * seqStride + l * labelStride])
                    if val > best { best = val; bestLabel = l }
                }
            } else {
                let basePtr = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
                for l in 0..<numLabels {
                    let val = basePtr[pos * seqStride + l * labelStride]
                    if val > best { best = val; bestLabel = l }
                }
            }
            predictions.append(bestLabel)
        }
        // Diagnostic: what did the model predict? (so we can see if it's all O or wrong label order)
        var hist: [Int: Int] = [:]
        for id in predictions { hist[id, default: 0] += 1 }
        let histStr = (0..<numLabels).map { "\(layoutlmv3LabelNames[$0]):\(hist[$0] ?? 0)" }.joined(separator: " ")
        print("[LayoutLMv3] Label histogram: \(histStr)")
        let preview = (1..<min(31, predictions.count)).map { i in
            let id = predictions[i]
            let name = id < layoutlmv3LabelNames.count ? layoutlmv3LabelNames[id] : "O"
            return "\(i):\(name)"
        }.joined(separator: " ")
        print("[LayoutLMv3] First 30 token predictions: \(preview)")
        // BIO decode: token position i (1-based) maps to word via tokenToWordIndex[i-1] (one word can produce multiple tokens).
        var fields: [KTCField] = []
        var i = 1
        let numContentTokens = tokenToWordIndex.count
        while i < seqLen && i - 1 < numContentTokens {
            let labelId = predictions[i]
            let name = labelId < layoutlmv3LabelNames.count ? layoutlmv3LabelNames[labelId] : "O"
            if name.hasPrefix("B-") {
                var spanWordIndices: [Int] = [tokenToWordIndex[i - 1]]
                i += 1
                while i < seqLen && i - 1 < numContentTokens && predictions[i] == labelId + 1 {
                    let wi = tokenToWordIndex[i - 1]
                    if spanWordIndices.last != wi { spanWordIndices.append(wi) }
                    i += 1
                }
                let text = spanWordIndices.map { wordBoxes[$0].word }.joined(separator: " ")
                let spanBoxes = spanWordIndices.map { wordBoxes[$0].boundingBox }
                let box = spanBoxes.reduce(spanBoxes[0]) { r, b in
                    CGRect(x: min(r.minX, b.minX), y: min(r.minY, b.minY),
                           width: max(r.maxX, b.maxX) - min(r.minX, b.minX),
                           height: max(r.maxY, b.maxY) - min(r.minY, b.minY))
                }
                if name == "B-QUESTION" {
                    fields.append(KTCField(label: text, labelBoundingBox: box))
                } else if name == "B-ANSWER" {
                    if !fields.isEmpty && fields[fields.count - 1].detectedValue == nil {
                        fields[fields.count - 1].detectedValue = text
                        fields[fields.count - 1].valueBoundingBox = box
                    } else {
                        var orphan = KTCField(label: "", labelBoundingBox: .zero)
                        orphan.detectedValue = text
                        orphan.valueBoundingBox = box
                        fields.append(orphan)
                    }
                }
            } else {
                i += 1
            }
        }
        let lines = wordBoxes.map { wb in
            KTCRecognizedLine(text: wb.word, boundingBox: wb.boundingBox, confidence: 1, pageIndex: 0)
        }
        return (fields, lines)
    }

    // MARK: - UDOP Pipeline (new way)

    private struct UDOPWordBox {
        let word: String
        let boundingBox: CGRect
    }

    private func runUDOPPipeline(cgImage: CGImage) {
        let udopLogger = Logger(subsystem: "com.fhirhose.app", category: "KTC.UDOP")
        udopLogger.info("[UDOP] Starting pipeline for image \(cgImage.width)x\(cgImage.height)")
        print("[UDOP] Starting pipeline for image \(cgImage.width)x\(cgImage.height)")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let t0 = CFAbsoluteTimeGetCurrent()

            do {
                // 1 — Line-level OCR for field detection
                let lines = try await Self.performOCR(on: cgImage, pageIndex: 0)
                udopLogger.info("[UDOP] Line OCR found \(lines.count) lines")
                print("[UDOP] Line OCR found \(lines.count) lines")

                // 2 — Standard field detection pipeline
                var detectedFields = Self.extractLabelCandidates(from: lines)
                let checkboxes = Self.detectCheckboxes(from: lines)
                udopLogger.info("[UDOP] Text-based checkboxes: \(checkboxes.count)")
                print("[UDOP] Text-based checkboxes: \(checkboxes.count)")

                var checkboxGroups = Self.groupCheckboxes(checkboxes, allLines: lines)
                Self.classifyFieldTypes(&detectedFields, checkboxes: checkboxes, allLines: lines)
                Self.associateValuesWithLabels(&detectedFields, allLines: lines)
                udopLogger.info("[UDOP] Heuristic detection: \(detectedFields.count) fields, \(checkboxGroups.count) checkbox groups")
                print("[UDOP] Heuristic detection: \(detectedFields.count) fields, \(checkboxGroups.count) checkbox groups")

                // 3 — Build full OCR text for Apple Intelligence
                let fullOCRText = lines.map(\.text).joined(separator: "\n")

                // 4 — Apple Intelligence: extract field values AND checkbox groups
                if #available(iOS 26, *) {
                    // 4a — Extract values for text fields missing them
                    let fieldsToQuery = detectedFields.enumerated().filter { (_, field) in
                        field.fieldType != .checkbox && field.fieldType != .signature && field.detectedValue == nil
                    }
                    if !fieldsToQuery.isEmpty {
                        udopLogger.info("[UDOP] \(fieldsToQuery.count) fields without values — querying AI")
                        print("[UDOP] \(fieldsToQuery.count) fields without values — querying AI")

                        let fieldLabels = fieldsToQuery.map { "\($0.offset): \($0.element.label)" }.joined(separator: "\n")
                        let extracted = try await Self.extractFieldsWithAppleIntelligence(
                            ocrText: fullOCRText,
                            fieldLabels: fieldLabels,
                            logger: udopLogger
                        )
                        for (idx, value) in extracted {
                            if idx < detectedFields.count {
                                detectedFields[idx].detectedValue = value
                                detectedFields[idx].value = value
                                udopLogger.info("[UDOP] AI filled [\(idx)] \(detectedFields[idx].label) = \"\(value)\"")
                                print("[UDOP] AI filled [\(idx)] \(detectedFields[idx].label) = \"\(value)\"")
                            }
                        }
                    }

                    // 4b — Detect checkbox groups from OCR text structure
                    let aiCheckboxGroups = try await Self.detectCheckboxGroupsWithAI(
                        ocrText: fullOCRText,
                        logger: udopLogger
                    )
                    if !aiCheckboxGroups.isEmpty {
                        checkboxGroups.append(contentsOf: aiCheckboxGroups)
                        udopLogger.info("[UDOP] AI detected \(aiCheckboxGroups.count) checkbox groups, total: \(checkboxGroups.count)")
                        print("[UDOP] AI detected \(aiCheckboxGroups.count) checkbox groups, total: \(checkboxGroups.count)")
                    }
                } else {
                    udopLogger.warning("[UDOP] Apple Intelligence requires iOS 26+, skipping AI extraction")
                    print("[UDOP] Apple Intelligence requires iOS 26+, skipping AI extraction")
                }

                // 6 — Apply patient data mappings and auto-check checkboxes
                let data = KTCPatientDataLoader.loadAndFlatten()
                KTCPatientDataLoader.applyMappings(to: &detectedFields, using: data)
                Self.autoCheckCheckboxGroups(&checkboxGroups, using: data)

                let total = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)
                udopLogger.info("[UDOP] Full pipeline completed in \(total)s")
                print("[UDOP] Full pipeline completed in \(total)s")

                // 7 — Transition to editing with populated data
                await MainActor.run {
                    self.recognizedLines = lines
                    self.fields = detectedFields
                    self.checkboxGroups = checkboxGroups
                    self.patientData = data
                    let withValues = detectedFields.filter { $0.detectedValue != nil }.count
                    let checkboxFieldCount = detectedFields.filter { $0.fieldType == .checkbox }.count
                    let autoChecked = checkboxGroups.filter { $0.selectedIndex != nil }.count
                    udopLogger.info("[UDOP] → editing phase: \(lines.count) lines, \(detectedFields.count) fields (\(withValues) with values, \(checkboxFieldCount) checkboxes, \(checkboxGroups.count) groups, \(autoChecked) auto-checked), \(data.count) keypaths")
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self.phase = .editing
                }
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - t0
                let errTime = String(format: "%.2f", elapsed)
                udopLogger.error("[UDOP] Failed after \(errTime)s: \(error.localizedDescription)")
                print("[UDOP] FAILED after \(errTime)s: \(error.localizedDescription)")

                await MainActor.run {
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    self.phase = .error("UDOP failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Apple Intelligence Field Extraction

    /// Ask Apple Intelligence to extract field values from OCR text.
    /// Returns array of (fieldIndex, extractedValue) pairs.
    @available(iOS 26, macOS 26, visionOS 26, *)
    private nonisolated static func extractFieldsWithAppleIntelligence(
        ocrText: String,
        fieldLabels: String,
        logger: Logger
    ) async throws -> [(Int, String)] {
        let session = LanguageModelSession(instructions: """
            You are a form field extractor. Given OCR text from a scanned form and a list of field labels, \
            extract the value for each field from the text. If a field's value is not present or the field \
            is blank on the form, skip it. Respond ONLY with lines in the format: INDEX|VALUE
            Do not include any other text, explanations, or empty lines.
            """)

        let prompt = """
            OCR TEXT:
            \(ocrText)

            FIELDS TO EXTRACT (index: label):
            \(fieldLabels)

            Extract the value for each field. Respond with INDEX|VALUE lines only:
            """

        logger.info("[UDOP] Apple Intelligence prompt length: \(prompt.count) chars")
        print("[UDOP] Apple Intelligence prompt length: \(prompt.count) chars")

        let t0 = CFAbsoluteTimeGetCurrent()
        let response = try await session.respond(to: prompt)
        let responseText = response.content
        let elapsed = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)
        logger.info("[UDOP] Apple Intelligence responded in \(elapsed)s: \(responseText)")
        print("[UDOP] Apple Intelligence responded in \(elapsed)s:\n\(responseText)")

        // Parse INDEX|VALUE lines
        var results: [(Int, String)] = []
        for line in responseText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "|", maxSplits: 1)
            guard parts.count == 2,
                  let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty {
                results.append((idx, value))
            }
        }
        return results
    }

    // MARK: - Apple Intelligence Checkbox Group Detection

    /// Ask Apple Intelligence to identify checkbox/radio groups from OCR text.
    /// Returns KTCCheckboxGroup objects with options parsed from the AI response.
    @available(iOS 26, macOS 26, visionOS 26, *)
    private nonisolated static func detectCheckboxGroupsWithAI(
        ocrText: String,
        logger: Logger
    ) async throws -> [KTCCheckboxGroup] {
        let session = LanguageModelSession(instructions: """
            You are a form structure analyzer. Given OCR text from a scanned form, identify all \
            checkbox or radio-button groups that ACTUALLY APPEAR in the text. These are places where \
            a user must select one or more options from a list. They often look like: \
            "Label: □ Option1 □ Option2 □ Option3" or "Label: Option1 Option2 Option3" \
            (the □ symbols may be missing or read as 'o' or 'D').

            IMPORTANT: Only report groups whose label AND options are explicitly present in the OCR text. \
            Do NOT invent or guess groups that are not in the text. If the text does not mention \
            "Marital Status" anywhere, do not include a Marital Status group.

            Respond ONLY with lines in this format, one per group:
            GROUP_LABEL|OPTION1,OPTION2,OPTION3

            Do not include any other text or explanations.
            """)

        let prompt = """
            Identify all checkbox/radio groups in this form text. Only include groups \
            whose labels and options actually appear in the text below:

            \(ocrText)
            """

        logger.info("[Checkbox-AI] Prompt length: \(prompt.count) chars")
        print("[Checkbox-AI] Prompt length: \(prompt.count) chars")

        let t0 = CFAbsoluteTimeGetCurrent()
        let response = try await session.respond(to: prompt)
        let responseText = response.content
        let elapsed = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0)
        logger.info("[Checkbox-AI] Responded in \(elapsed)s:\n\(responseText)")
        print("[Checkbox-AI] Responded in \(elapsed)s:\n\(responseText)")

        let ocrLower = ocrText.lowercased()

        // Parse GROUP_LABEL|OPTION1,OPTION2,OPTION3 lines
        var groups: [KTCCheckboxGroup] = []
        for line in responseText.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let groupLabel = parts[0].trimmingCharacters(in: .whitespaces)
            let optionStrings = parts[1].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            guard !optionStrings.isEmpty else { continue }

            // Validate: at least 2 options must actually appear in the OCR text
            let matchingOptions = optionStrings.filter { ocrLower.contains($0.lowercased()) }
            if matchingOptions.count < 2 {
                logger.info("[Checkbox-AI] Skipped hallucinated group: \(groupLabel) (only \(matchingOptions.count) options found in text)")
                print("[Checkbox-AI] Skipped hallucinated group: \(groupLabel) (only \(matchingOptions.count)/\(optionStrings.count) options in text)")
                continue
            }

            // Only use the options that actually appear in the OCR text
            let validOptions = optionStrings.filter { ocrLower.contains($0.lowercased()) }

            let options = validOptions.map { optText in
                KTCCheckbox(
                    boundingBox: .zero,
                    isChecked: false,
                    associatedText: optText
                )
            }

            var group = KTCCheckboxGroup(
                boundingBox: .zero,
                options: options,
                groupLabel: groupLabel
            )

            // Try to match to known patient data keypaths
            let labelLower = groupLabel.lowercased()
            if labelLower.contains("gender") || labelLower.contains("sex") {
                group.mappedKeypath = "patient.sex"
            } else if labelLower.contains("marital") {
                group.mappedKeypath = "patient.maritalStatus"
            } else if labelLower.contains("race") || labelLower.contains("ethnicity") {
                group.mappedKeypath = "patient.race"
            }

            groups.append(group)
            logger.info("[Checkbox-AI] Group: \(groupLabel) → \(validOptions.joined(separator: ", ")) (\(validOptions.count)/\(optionStrings.count) validated)")
            print("[Checkbox-AI] Group: \(groupLabel) → \(validOptions.joined(separator: ", ")) (\(validOptions.count)/\(optionStrings.count) validated)")
        }

        return groups
    }

    // MARK: - Visual Checkbox Detection

    /// Detect unfilled checkbox squares and circles in a scanned form image
    /// using Vision contour detection. Returns bounding boxes in Vision
    /// normalized coordinates (0-1, bottom-left origin).
    private nonisolated static func detectCheckboxShapes(
        in cgImage: CGImage,
        ocrLines: [KTCRecognizedLine] = [],
        logger: Logger
    ) throws -> [CGRect] {
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 1024

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first else {
            logger.info("[Checkbox] No contours found")
            return []
        }

        logger.info("[Checkbox] Total contours detected: \(observation.contourCount)")
        print("[Checkbox] Total contours detected: \(observation.contourCount)")

        // Checkbox size range in normalized coords.
        // Real checkboxes on a letter-size form are ~12-30px, which at ~1700px wide
        // is 0.007–0.018. Bump minimum up to avoid letter components.
        let minDim: CGFloat = 0.008
        let maxDim: CGFloat = 0.035

        var candidates: [CGRect] = []

        func evaluateContour(_ contour: VNContour) {
            let bounds = contour.normalizedPath.boundingBox
            let w = bounds.width
            let h = bounds.height

            guard w > minDim, w < maxDim, h > minDim, h < maxDim else { return }

            // Tight aspect ratio — checkboxes are very square
            let aspect = w / h
            guard aspect > 0.75, aspect < 1.35 else { return }

            guard contour.pointCount >= 4 else { return }

            candidates.append(bounds)
        }

        // Walk the contour tree
        for topIdx in 0..<observation.topLevelContourCount {
            guard let top = try? observation.contour(at: topIdx) else { continue }
            evaluateContour(top)
            for childIdx in 0..<top.childContourCount {
                guard let child = try? top.childContour(at: childIdx) else { continue }
                evaluateContour(child)
                for grandIdx in 0..<child.childContourCount {
                    guard let grand = try? child.childContour(at: grandIdx) else { continue }
                    evaluateContour(grand)
                }
            }
        }

        logger.info("[Checkbox] Shape candidates after size/aspect filter: \(candidates.count)")
        print("[Checkbox] Shape candidates after size/aspect filter: \(candidates.count)")

        // --- Key filter: remove candidates embedded WITHIN OCR text lines ---
        // Real checkboxes sit at the left edge of (or just before) their text label.
        // Letter components (o, e, a, d loops) are surrounded by other text on both sides.
        // Check: if a candidate's bounding box is fully inside an OCR line box and
        // there is text on BOTH its left AND right sides within that line, it's a letter.
        let textFiltered: [CGRect]
        if !ocrLines.isEmpty {
            textFiltered = candidates.filter { cb in
                for line in ocrLines {
                    let lb = line.boundingBox
                    // Is the candidate inside this OCR line vertically?
                    let vertInside = cb.midY > lb.minY - lb.height * 0.3 &&
                                     cb.midY < lb.maxY + lb.height * 0.3
                    guard vertInside else { continue }

                    // How much of the line is to the LEFT vs RIGHT of the candidate?
                    let spaceLeft = cb.minX - lb.minX
                    let spaceRight = lb.maxX - cb.maxX

                    // If there's significant text on BOTH sides, it's embedded in text
                    // (a checkbox would be at the start of the text, so very little to the left)
                    let lineWidth = lb.width
                    guard lineWidth > 0 else { continue }
                    let leftFraction = spaceLeft / lineWidth
                    let rightFraction = spaceRight / lineWidth

                    // If >10% of line on left AND >10% on right → likely a letter component
                    if leftFraction > 0.10 && rightFraction > 0.10 {
                        return false // reject — it's inside text
                    }
                }
                return true // keep — not embedded in text
            }
            logger.info("[Checkbox] After text-embedding filter: \(textFiltered.count) (removed \(candidates.count - textFiltered.count) embedded in text)")
            print("[Checkbox] After text-embedding filter: \(textFiltered.count)")
        } else {
            textFiltered = candidates
        }

        // --- Hollowness check: real checkboxes have a light interior ---
        let hollowFiltered = textFiltered.filter { rect in
            !isCheckboxFilled(cgImage: cgImage, normalizedRect: rect)
        }
        logger.info("[Checkbox] After hollowness filter (unfilled only): \(hollowFiltered.count)")
        print("[Checkbox] After hollowness filter: \(hollowFiltered.count)")

        // Deduplicate overlapping detections
        var deduped: [CGRect] = []
        var used = [Bool](repeating: false, count: hollowFiltered.count)
        for i in 0..<hollowFiltered.count {
            guard !used[i] else { continue }
            var best = hollowFiltered[i]
            for j in (i + 1)..<hollowFiltered.count {
                guard !used[j] else { continue }
                if overlaps(best, hollowFiltered[j], threshold: 0.5) {
                    used[j] = true
                    let aI = best.width / best.height
                    let aJ = hollowFiltered[j].width / hollowFiltered[j].height
                    if abs(aJ - 1.0) < abs(aI - 1.0) { best = hollowFiltered[j] }
                }
            }
            deduped.append(best)
        }

        logger.info("[Checkbox] Final checkbox candidates: \(deduped.count)")
        print("[Checkbox] Final checkbox candidates: \(deduped.count)")
        for (i, r) in deduped.prefix(30).enumerated() {
            print("[Checkbox]   [\(i)] x=\(String(format: "%.3f", r.minX)) y=\(String(format: "%.3f", r.minY)) w=\(String(format: "%.3f", r.width)) h=\(String(format: "%.3f", r.height))")
        }

        return deduped
    }

    /// Check if two rects overlap by more than `threshold` fraction of the smaller rect's area.
    private nonisolated static func overlaps(_ a: CGRect, _ b: CGRect, threshold: CGFloat) -> Bool {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return false }
        let interArea = intersection.width * intersection.height
        let smallerArea = min(a.width * a.height, b.width * b.height)
        return smallerArea > 0 && interArea / smallerArea > threshold
    }

    /// Check if a detected checkbox region is filled (checked) by examining pixel intensity.
    /// Returns true if the interior is mostly dark (filled/checked).
    private nonisolated static func isCheckboxFilled(
        cgImage: CGImage,
        normalizedRect: CGRect
    ) -> Bool {
        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        // Convert Vision coords (bottom-left) to pixel coords (top-left)
        let pixelX = Int(normalizedRect.minX * imgW)
        let pixelY = Int((1.0 - normalizedRect.maxY) * imgH)
        let pixelW = max(1, Int(normalizedRect.width * imgW))
        let pixelH = max(1, Int(normalizedRect.height * imgH))

        // Inset slightly to avoid the border itself
        let inset = max(1, min(pixelW, pixelH) / 4)
        let innerX = pixelX + inset
        let innerY = pixelY + inset
        let innerW = max(1, pixelW - inset * 2)
        let innerH = max(1, pixelH - inset * 2)

        guard let cropped = cgImage.cropping(to: CGRect(x: innerX, y: innerY, width: innerW, height: innerH)) else {
            return false
        }

        // Render to grayscale and compute average intensity
        let w = cropped.width
        let h = cropped.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }

        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return false }

        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h)
        var totalBrightness: Int = 0
        for i in 0..<(w * h) {
            totalBrightness += Int(pixels[i])
        }
        let avgBrightness = CGFloat(totalBrightness) / CGFloat(w * h) / 255.0

        // If average brightness < 0.65, the interior is mostly dark → filled
        return avgBrightness < 0.65
    }

    /// Associate detected checkbox shapes with nearby OCR text to create KTCCheckbox objects.
    private nonisolated static func associateCheckboxesWithText(
        shapes: [CGRect],
        cgImage: CGImage,
        lines: [KTCRecognizedLine],
        logger: Logger
    ) -> [KTCCheckbox] {
        var checkboxes: [KTCCheckbox] = []

        for shape in shapes {
            let filled = isCheckboxFilled(cgImage: cgImage, normalizedRect: shape)

            // Find the closest OCR text to the RIGHT of or immediately after this checkbox
            var bestText: String?
            var bestDistance: CGFloat = .infinity

            for line in lines {
                let lineBox = line.boundingBox
                // Text should be roughly on the same vertical line
                let verticalOverlap = abs(lineBox.midY - shape.midY) < shape.height * 2.0

                if verticalOverlap {
                    // Text to the right of the checkbox
                    let horizDist = lineBox.minX - shape.maxX
                    if horizDist > -shape.width * 0.5 && horizDist < 0.15 && horizDist < bestDistance {
                        bestDistance = horizDist
                        // Take just the first few words that are close
                        let words = line.text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        bestText = words.prefix(3).joined(separator: " ")
                    }
                }
            }

            logger.info("[Checkbox] shape at (\(String(format: "%.3f", shape.midX)), \(String(format: "%.3f", shape.midY))) filled=\(filled) text=\"\(bestText ?? "nil")\"")

            checkboxes.append(KTCCheckbox(
                boundingBox: shape,
                isChecked: filled,
                associatedText: bestText
            ))
        }

        return checkboxes
    }

    // MARK: - UDOP Helpers

    /// Run Vision OCR and return word-level text + bounding boxes.
    private nonisolated static func udopWordOCR(_ cgImage: CGImage) async throws -> [UDOPWordBox] {
        try await withCheckedThrowingContinuation { cont in
            let req = VNRecognizeTextRequest { req, err in
                if let err { cont.resume(throwing: err); return }
                guard let obs = req.results as? [VNRecognizedTextObservation] else {
                    cont.resume(returning: []); return
                }
                var boxes: [UDOPWordBox] = []
                for o in obs {
                    guard let c = o.topCandidates(1).first else { continue }
                    let text = c.string
                    let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                    var search = text.startIndex
                    for w in words {
                        guard let range = text.range(of: w, range: search..<text.endIndex) else { continue }
                        search = range.upperBound
                        if let rect = try? c.boundingBox(for: range) {
                            boxes.append(UDOPWordBox(word: w, boundingBox: rect.boundingBox))
                        } else {
                            boxes.append(UDOPWordBox(word: w, boundingBox: o.boundingBox))
                        }
                    }
                }
                cont.resume(returning: boxes)
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            req.recognitionLanguages = ["en-US"]
            if #available(iOS 16.0, *) {
                req.revision = VNRecognizeTextRequestRevision3
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([req]) }
            catch { cont.resume(throwing: error) }
        }
    }

    /// Tokenize OCR words, align each subword token with its word-level bbox,
    /// and pad/truncate to `maxLength`. Returns (input_ids, bboxes, attention_mask).
    /// If `taskPrefix` is provided, its tokens are prepended with [0,0,0,0] bboxes.
    private nonisolated static func udopTokenize(
        words: [UDOPWordBox],
        tokenizer: SentencePieceTokenizer,
        maxLength: Int,
        taskPrefix: String? = nil
    ) -> (ids: [Int32], bboxes: [[Int32]], mask: [Int32]) {
        var ids: [Int32] = []
        var bboxes: [[Int32]] = []

        if let prefix = taskPrefix {
            let prefixTokens = tokenizer.encode(prefix)
            for t in prefixTokens {
                ids.append(t)
                bboxes.append([0, 0, 0, 0])
                if ids.count >= maxLength - 1 { break }
            }
        }

        for wb in words {
            let toks = tokenizer.encode(wb.word)
            let b = wb.boundingBox
            // Vision (0-1, bottom-left origin) → UDOP (0-1000, top-left origin)
            let box: [Int32] = [
                Int32(max(0, min(1000, Int(b.minX * 1000)))),
                Int32(max(0, min(1000, Int((1 - b.maxY) * 1000)))),
                Int32(max(0, min(1000, Int(b.maxX * 1000)))),
                Int32(max(0, min(1000, Int((1 - b.minY) * 1000))))
            ]
            for t in toks {
                ids.append(t)
                bboxes.append(box)
                if ids.count >= maxLength - 1 { break }
            }
            if ids.count >= maxLength - 1 { break }
        }

        ids.append(tokenizer.eosId)
        bboxes.append([0, 0, 0, 0])

        let realCount = ids.count
        while ids.count < maxLength {
            ids.append(tokenizer.padId)
            bboxes.append([0, 0, 0, 0])
        }

        let mask = (0..<maxLength).map { Int32($0 < realCount ? 1 : 0) }
        return (ids, bboxes, mask)
    }

    /// Resize a CGImage to 512×512 and produce a normalised `pixel_values`
    /// MLMultiArray with shape [1, 3, 512, 512] in float16 (ImageNet stats).
    private nonisolated static func udopPreprocessImage(_ cgImage: CGImage) throws -> MLMultiArray {
        let w = 512, h = 512
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "UDOP", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create CGContext"])
        }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else {
            throw NSError(domain: "UDOP", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "No pixel data from CGContext"])
        }

        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        let arr = try MLMultiArray(
            shape: [1, 3, NSNumber(value: h), NSNumber(value: w)],
            dataType: .float16
        )
        let ptr = UnsafeMutablePointer<Float16>(OpaquePointer(arr.dataPointer))
        let chStride = h * w
        let mean: [Float] = [0.485, 0.456, 0.406]
        let std:  [Float] = [0.229, 0.224, 0.225]

        for row in 0..<h {
            for col in 0..<w {
                let i = (row * w + col) * 4
                let r = Float(px[i])     / 255.0
                let g = Float(px[i + 1]) / 255.0
                let b = Float(px[i + 2]) / 255.0
                ptr[0 * chStride + row * w + col] = Float16((r - mean[0]) / std[0])
                ptr[1 * chStride + row * w + col] = Float16((g - mean[1]) / std[1])
                ptr[2 * chStride + row * w + col] = Float16((b - mean[2]) / std[2])
            }
        }
        return arr
    }

    /// Build MLMultiArrays for encoder inputs and run a single forward pass.
    /// Returns (encoder_hidden_states, encoder_attention_mask).
    private nonisolated static func udopEncode(
        model: MLModel,
        inputIds: [Int32],
        bboxes: [[Int32]],
        mask: [Int32],
        pixels: MLMultiArray
    ) throws -> (hiddenStates: MLMultiArray, attentionMask: MLMultiArray) {
        let seq = inputIds.count

        let idsArr  = try MLMultiArray(shape: [1, NSNumber(value: seq)], dataType: .int32)
        let maskArr = try MLMultiArray(shape: [1, NSNumber(value: seq)], dataType: .int32)
        let bboxArr = try MLMultiArray(shape: [1, NSNumber(value: seq), 4], dataType: .int32)

        let idsPtr  = UnsafeMutablePointer<Int32>(OpaquePointer(idsArr.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(maskArr.dataPointer))
        let bboxPtr = UnsafeMutablePointer<Int32>(OpaquePointer(bboxArr.dataPointer))

        for i in 0..<seq {
            idsPtr[i]  = inputIds[i]
            maskPtr[i] = mask[i]
            for j in 0..<4 { bboxPtr[i * 4 + j] = bboxes[i][j] }
        }

        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids":      MLFeatureValue(multiArray: idsArr),
            "bbox":           MLFeatureValue(multiArray: bboxArr),
            "attention_mask": MLFeatureValue(multiArray: maskArr),
            "pixel_values":   MLFeatureValue(multiArray: pixels),
        ])

        let out = try model.prediction(from: provider)
        let hs = out.featureValue(for: "encoder_hidden_states")!.multiArrayValue!
        let em = out.featureValue(for: "encoder_attention_mask")!.multiArrayValue!
        return (hs, em)
    }

    /// Greedy autoregressive decoding with full-sequence [1,64] decoder.
    /// Maintains persistent input arrays and fills left-to-right, reading
    /// logits at the current step position each iteration.
    private nonisolated static func udopDecode(
        model: MLModel,
        hiddenStates: MLMultiArray,
        encoderMask: MLMultiArray,
        tokenizer: SentencePieceTokenizer,
        maxTokens: Int,
        logger: Logger
    ) throws -> [Int32] {
        let maskInt: MLMultiArray
        if encoderMask.dataType != .int32 {
            let n = encoderMask.count
            maskInt = try MLMultiArray(shape: encoderMask.shape, dataType: .int32)
            let dst = UnsafeMutablePointer<Int32>(OpaquePointer(maskInt.dataPointer))
            if encoderMask.dataType == .float16 {
                let src = UnsafePointer<Float16>(OpaquePointer(encoderMask.dataPointer))
                for i in 0..<n { dst[i] = Int32(src[i]) }
            } else {
                for i in 0..<n { dst[i] = encoderMask[i].int32Value }
            }
        } else {
            maskInt = encoderMask
        }

        let seqLen = 64
        let decIds = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let decMask = try MLMultiArray(shape: [1, NSNumber(value: seqLen)], dataType: .int32)
        let idPtr = UnsafeMutablePointer<Int32>(OpaquePointer(decIds.dataPointer))
        let maskPtr = UnsafeMutablePointer<Int32>(OpaquePointer(decMask.dataPointer))

        for i in 0..<seqLen {
            idPtr[i] = tokenizer.padId
            maskPtr[i] = 0
        }
        idPtr[0] = tokenizer.padId
        maskPtr[0] = 1

        var outputTokens: [Int32] = []

        for step in 0..<min(maxTokens, seqLen - 1) {
            let prov = try MLDictionaryFeatureProvider(dictionary: [
                "decoder_input_ids":     MLFeatureValue(multiArray: decIds),
                "decoder_attention_mask": MLFeatureValue(multiArray: decMask),
                "encoder_hidden_states": MLFeatureValue(multiArray: hiddenStates),
                "encoder_attention_mask": MLFeatureValue(multiArray: maskInt),
            ])

            let result = try model.prediction(from: prov)
            let logits = result.featureValue(for: "logits")!.multiArrayValue!
            let vocab = logits.shape.last!.intValue
            let strides = logits.strides.map { $0.intValue }
            let posStride = strides[1]
            let vocStride = strides[2]

            if step == 0 {
                logger.info("[UDOP] logits shape=\(logits.shape) strides=\(strides) dtype=\(logits.dataType.rawValue)")
                print("[UDOP] logits shape=\(logits.shape) strides=\(strides) dtype=\(logits.dataType.rawValue)")
            }

            let baseOffset = step * posStride
            var bestVal: Float = -.infinity
            var bestId: Int32 = 0

            if logits.dataType == .float16 {
                let lp = UnsafePointer<Float16>(OpaquePointer(logits.dataPointer))
                for v in 0..<vocab {
                    let f = Float(lp[baseOffset + v * vocStride])
                    if f > bestVal { bestVal = f; bestId = Int32(v) }
                }
            } else {
                let lp = UnsafePointer<Float>(OpaquePointer(logits.dataPointer))
                for v in 0..<vocab {
                    let val = lp[baseOffset + v * vocStride]
                    if val > bestVal { bestVal = val; bestId = Int32(v) }
                }
            }

            let name = tokenizer.pieceName(for: bestId)
            let logitStr = String(format: "%.2f", bestVal)
            logger.info("[UDOP] step \(step): id=\(bestId) '\(name)' logit=\(logitStr)")
            print("[UDOP] step \(step): id=\(bestId) '\(name)' logit=\(logitStr)")

            if bestId == tokenizer.eosId { break }

            outputTokens.append(bestId)
            idPtr[step + 1] = bestId
            maskPtr[step + 1] = 1
        }

        return outputTokens
    }

    /// Run VNRecognizeTextRequest and return recognized lines.
    private nonisolated static func performOCR(on cgImage: CGImage, pageIndex: Int) async throws -> [KTCRecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines: [KTCRecognizedLine] = observations.compactMap { obs in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return KTCRecognizedLine(
                        text: candidate.string,
                        boundingBox: obs.boundingBox,
                        confidence: candidate.confidence,
                        pageIndex: pageIndex
                    )
                }
                continuation.resume(returning: lines)
            }

            // Enhanced OCR settings for better form recognition
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = 0.005  // Detect even smaller text
            request.automaticallyDetectsLanguage = false
            // Use latest Vision revision for better accuracy
            if #available(iOS 16.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Manual Field Addition

    /// Add a field manually with specified label and input locations.
    func addManualField(label: String, labelBox: CGRect, inputBox: CGRect?) {
        var field = KTCField(
            label: label,
            labelBoundingBox: labelBox
        )

        // If input box specified, store it for value placement
        if let inputBox = inputBox {
            field.valueBoundingBox = inputBox
        }

        // Try to match to patient data
        if let match = KTCPatientDataLoader.fuzzyMatch(label: label, in: patientData) {
            field.mappedKeypath = match.keypath
            field.value = match.value
            field.matchConfidence = match.confidence
            field.matchMethod = match.method
        }

        fields.append(field)
        logger.info("Added manual field: '\(label)'")
    }

    /// Remove a field by ID.
    func removeField(id: UUID) {
        fields.removeAll { $0.id == id }
        logger.info("Removed field with id: \(id)")
    }

    // MARK: - Heading Detection (to filter out)

    /// Patterns that indicate a line is a section heading, not a field label.
    private static let headingPatterns: [String] = [
        "patient information", "personal information", "insurance information",
        "medical history", "health history", "family history",
        "emergency contact", "contact information", "billing information",
        "authorization", "consent", "agreement", "notice", "acknowledgment",
        "section", "part", "page", "form", "instructions", "please read",
        "important", "required", "office use only", "do not write",
        "demographic", "registration", "intake", "new patient",
        "hipaa", "privacy", "disclosure", "release of information"
    ]

    /// Check if a line appears to be a section heading rather than a field label.
    private nonisolated static func isHeading(_ text: String, boundingBox: CGRect) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)

        // Only filter if it EXACTLY matches a heading pattern (not just contains)
        for pattern in headingPatterns {
            // Must be a significant match, not just contain the word
            if lower == pattern || lower.hasPrefix(pattern + ":") || lower.hasPrefix(pattern + " -") {
                return true
            }
        }

        // All caps text that's relatively long is likely a heading (not short labels like "DOB")
        let stripped = text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if stripped.count >= 10 && stripped.count <= 50 && stripped == stripped.uppercased() && stripped.contains(" ") {
            // Multi-word all-caps longer text is likely a heading
            return true
        }

        // Text that spans a very large horizontal portion is likely a heading/title
        if boundingBox.width > 0.6 && text.count > 30 {
            return true
        }

        return false
    }

    // MARK: - Input Area Detection

    /// Represents a detected input area (underline, box, or blank space).
    struct InputArea {
        let boundingBox: CGRect
        let type: InputType

        enum InputType {
            case underline      // _____ or ------ pattern
            case blankSpace     // Empty area next to label
            case textBox        // Rectangular input area
        }
    }

    /// Detect input areas (underlines, blank spaces) from OCR text.
    nonisolated static func detectInputAreas(from lines: [KTCRecognizedLine]) -> [InputArea] {
        var areas: [InputArea] = []

        for line in lines {
            let text = line.text

            // Detect underline patterns: sequences of _ or -
            let underlinePattern = try? NSRegularExpression(pattern: "[_\\-]{3,}", options: [])
            if let matches = underlinePattern?.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)), !matches.isEmpty {
                // This line contains an underline - the input area is where the underline is
                areas.append(InputArea(boundingBox: line.boundingBox, type: .underline))
            }
        }

        return areas
    }

    // MARK: - Label Detection Heuristics

    /// Common label keywords found on medical forms.
    /// NOTE: Avoid generic words that could match section headings.
    private static let labelKeywords: Set<String> = [
        // Identity - specific field labels
        "name", "first", "last", "middle",
        "full name", "first name", "last name", "middle name", "mi",
        "patient name", "legal name", "print name", "printed name",
        // DOB / Age
        "dob", "date of birth", "birth date", "birthday", "age", "birthdate",
        // Sex / Gender
        "sex", "gender",
        // Contact - specific
        "phone", "telephone", "cell", "mobile", "fax", "phone number",
        "home phone", "cell phone", "work phone", "daytime phone",
        "email", "e-mail", "email address",
        // Address - specific field labels
        "address", "street", "street address", "apt", "suite", "unit",
        "city", "state", "zip", "postal", "zip code", "postal code",
        "county", "country",
        // ID numbers - specific
        "ssn", "social security", "mrn", "medical record number",
        "account number", "id number", "member id", "subscriber id",
        "driver license", "license number",
        // Insurance - specific field labels
        "payer", "carrier", "insurer", "plan name",
        "member id", "subscriber", "group", "group id", "group number",
        "policy number", "copay", "co-pay", "bin", "pcn", "rx bin", "rx pcn",
        // Employment
        "employer", "employer name", "occupation", "company",
        // Emergency contact fields
        "emergency contact", "relationship", "notify",
        // Clinical - specific field labels (not section headers)
        "allergies", "medications", "pharmacy", "pharmacy name", "pharmacy phone",
        "primary diagnosis", "referring physician", "pcp",
        // Administrative - specific field labels
        "signature", "patient signature", "date", "today's date",
        "date signed", "reason for visit",
        // Vitals
        "height", "weight", "blood pressure", "bp", "temperature", "pulse",
        // Demographics - specific
        "race", "ethnicity", "marital status", "preferred language",
        "guarantor", "responsible party",
    ]

    /// Extract field-label candidates from OCR lines using heuristics.
    nonisolated static func extractLabelCandidates(from lines: [KTCRecognizedLine]) -> [KTCField] {
        var fields: [KTCField] = []
        var seenLabels: Set<String> = []

        for line in lines {
            guard line.confidence > 0.3 else { continue }
            guard line.text.count <= 80 else { continue }

            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Skip if this looks like a heading
            if isHeading(trimmed, boundingBox: line.boundingBox) {
                continue
            }

            // Strategy 1: Line contains a colon → text before colon is the label
            // Also extract any value after the colon
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let labelPart = String(trimmed[trimmed.startIndex..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)

                // Skip if the label part looks like a heading
                if isHeading(labelPart, boundingBox: line.boundingBox) {
                    continue
                }

                if !labelPart.isEmpty && labelPart.count >= 2 && labelPart.count <= 50 {
                    let normalized = labelPart.lowercased()
                    if !seenLabels.contains(normalized) {
                        seenLabels.insert(normalized)

                        var field = KTCField(
                            label: labelPart,
                            labelBoundingBox: line.boundingBox
                        )

                        // Check for value after colon (not just underlines)
                        let afterColon = String(trimmed[trimmed.index(after: colonIdx)...])
                            .trimmingCharacters(in: .whitespaces)
                        let cleanedValue = afterColon
                            .replacingOccurrences(of: "_", with: "")
                            .replacingOccurrences(of: "-", with: "")
                            .trimmingCharacters(in: .whitespaces)

                        if !cleanedValue.isEmpty && cleanedValue.count >= 2 {
                            // There's actual text after the colon - it might be pre-filled
                            field.detectedValue = cleanedValue
                        }

                        // Check if there's an underline pattern indicating input area
                        if afterColon.contains("__") || afterColon.contains("--") {
                            field.fieldType = .text  // Explicitly a text input field
                        }

                        fields.append(field)
                    }
                    continue
                }
            }

            // Strategy 2: Line contains underscores/dashes (fill-in-the-blank pattern)
            // e.g. "Name ___________" or "DOB __/__/__"
            // Parse out the label portion before the underlines
            if trimmed.contains("__") || (trimmed.contains("--") && !trimmed.hasPrefix("--")) {
                // Find where the underlines start
                if let underlineStart = trimmed.firstIndex(of: "_") ?? trimmed.range(of: "--")?.lowerBound {
                    let labelPart = String(trimmed[trimmed.startIndex..<underlineStart])
                        .trimmingCharacters(in: .whitespaces)

                    if !labelPart.isEmpty && labelPart.count >= 2 && labelPart.count <= 50 {
                        // Skip if looks like heading
                        if isHeading(labelPart, boundingBox: line.boundingBox) {
                            continue
                        }

                        let normalized = labelPart.lowercased()
                        if !seenLabels.contains(normalized) {
                            seenLabels.insert(normalized)
                            fields.append(KTCField(
                                label: labelPart,
                                labelBoundingBox: line.boundingBox
                            ))
                        }
                        continue
                    }
                }

                // Fallback: clean the whole thing
                let stripped = trimmed
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                if !stripped.isEmpty && stripped.count >= 2 && stripped.count <= 50 {
                    if isHeading(stripped, boundingBox: line.boundingBox) {
                        continue
                    }
                    let normalized = stripped.lowercased()
                    if !seenLabels.contains(normalized) {
                        seenLabels.insert(normalized)
                        fields.append(KTCField(
                            label: stripped,
                            labelBoundingBox: line.boundingBox
                        ))
                    }
                    continue
                }
            }

            // Strategy 3: Line matches a known keyword (but not a heading)
            let lower = trimmed.lowercased()
            let matched = labelKeywords.contains { keyword in
                lower == keyword
                    || lower.hasPrefix(keyword + " ")
                    || lower.hasPrefix(keyword + "/")
                    || lower.hasPrefix(keyword + "(")
                    || lower.hasSuffix(" " + keyword)
            }

            if matched {
                let normalized = lower
                if !seenLabels.contains(normalized) {
                    seenLabels.insert(normalized)
                    fields.append(KTCField(
                        label: trimmed,
                        labelBoundingBox: line.boundingBox
                    ))
                }
            }
        }

        return fields
    }

    // MARK: - Spatial Analysis

    /// Find values on the form that are spatially associated with each label.
    /// Looks for text to the RIGHT of or BELOW each label bounding box.
    nonisolated static func associateValuesWithLabels(_ fields: inout [KTCField], allLines: [KTCRecognizedLine]) {
        // Build a set of label bounding boxes to exclude from value candidates
        let labelBoxes = Set(fields.map { $0.labelBoundingBox })

        for i in fields.indices {
            let label = fields[i]
            let box = label.labelBoundingBox

            // Find candidate value lines (not already used as labels)
            var bestCandidate: (line: KTCRecognizedLine, score: Double)?

            for line in allLines {
                // Skip if this line's box is a label
                if labelBoxes.contains(line.boundingBox) { continue }
                // Skip low confidence
                if line.confidence < 0.5 { continue }
                // Skip very short text (likely noise)
                if line.text.trimmingCharacters(in: .whitespaces).count < 2 { continue }

                let lineBox = line.boundingBox
                let score = spatialScore(labelBox: box, candidateBox: lineBox)

                if score > 0 {
                    if bestCandidate == nil || score > bestCandidate!.score {
                        bestCandidate = (line, score)
                    }
                }
            }

            if let best = bestCandidate {
                fields[i].detectedValue = best.line.text.trimmingCharacters(in: .whitespaces)
                fields[i].valueBoundingBox = best.line.boundingBox
            }
        }
    }

    /// Calculate a spatial affinity score between a label and a potential value.
    /// Higher score = better candidate. Returns 0 if not a valid spatial relationship.
    /// Vision coords: normalized (0-1), origin bottom-left.
    private nonisolated static func spatialScore(labelBox: CGRect, candidateBox: CGRect) -> Double {
        // Horizontal overlap/proximity
        let labelMidY = labelBox.midY
        let candMidY = candidateBox.midY
        let verticalDistance = abs(labelMidY - candMidY)
        let labelHeight = labelBox.height

        // Case 1: Same line (to the RIGHT of label)
        // Candidate should be roughly same Y level and to the right
        if verticalDistance < labelHeight * 1.5 {
            let horizontalGap = candidateBox.minX - labelBox.maxX
            // Must be to the right, with reasonable gap
            if horizontalGap > 0 && horizontalGap < 0.3 {
                // Score: closer horizontally = better, penalize vertical misalignment
                let hScore = 1.0 - (horizontalGap / 0.3)
                let vPenalty = verticalDistance / (labelHeight * 1.5)
                return hScore * (1.0 - vPenalty * 0.5) * 1.0  // weight for "right of"
            }
        }

        // Case 2: Line below (candidate Y is lower in Vision coords)
        // Candidate should be roughly same X (or slightly right) and below
        let labelMidX = labelBox.midX
        let candMidX = candidateBox.midX
        let horizontalDistance = abs(labelMidX - candMidX)

        if candidateBox.maxY < labelBox.minY {  // candidate is below label (lower Y in Vision)
            let verticalGap = labelBox.minY - candidateBox.maxY
            // Must be reasonably close vertically and horizontally aligned
            if verticalGap < 0.1 && horizontalDistance < labelBox.width * 2 {
                let vScore = 1.0 - (verticalGap / 0.1)
                let hPenalty = horizontalDistance / (labelBox.width * 2)
                return vScore * (1.0 - hPenalty * 0.5) * 0.8  // slightly lower weight for "below"
            }
        }

        return 0
    }

    // MARK: - Checkbox Detection

    /// Characters that indicate an unchecked checkbox in OCR.
    private static let uncheckedPatterns: Set<Character> = ["☐", "□", "◯", "○", "◻"]
    /// Characters that indicate a checked checkbox in OCR.
    private static let checkedPatterns: Set<Character> = ["☑", "☒", "■", "●", "◼", "✓", "✔", "✗", "✘", "×"]

    /// Detect checkboxes from OCR lines and return them with associated text.
    nonisolated static func detectCheckboxes(from lines: [KTCRecognizedLine]) -> [KTCCheckbox] {
        var checkboxes: [KTCCheckbox] = []

        for line in lines {
            let text = line.text
            var currentIndex = text.startIndex

            while currentIndex < text.endIndex {
                let char = text[currentIndex]

                // Check for checkbox character patterns
                let isUnchecked = uncheckedPatterns.contains(char)
                let isChecked = checkedPatterns.contains(char)

                if isUnchecked || isChecked {
                    // Extract associated text (after the checkbox on the same line)
                    let afterIndex = text.index(after: currentIndex)
                    let associatedText = afterIndex < text.endIndex
                        ? String(text[afterIndex...]).trimmingCharacters(in: .whitespaces)
                        : nil

                    // Clean up associated text - take first word if it's a simple option
                    var cleanedText = associatedText
                    if let at = associatedText {
                        // If the text contains another checkbox, only take text before it
                        let words = at.components(separatedBy: .whitespaces)
                        if let firstWord = words.first, !firstWord.isEmpty {
                            // Check if first word is a common checkbox option
                            let lower = firstWord.lowercased()
                            if ["male", "female", "yes", "no", "m", "f", "married", "single", "divorced", "widowed"].contains(lower) {
                                cleanedText = firstWord
                            }
                        }
                    }

                    checkboxes.append(KTCCheckbox(
                        boundingBox: line.boundingBox,
                        isChecked: isChecked,
                        associatedText: cleanedText?.isEmpty == true ? nil : cleanedText
                    ))
                }

                // Also check for text patterns like "[x]", "[ ]", "(x)", "( )", "[ x ]"
                if char == "[" || char == "(" {
                    let closeChar: Character = char == "[" ? "]" : ")"
                    if let closeIndex = text[currentIndex...].firstIndex(of: closeChar) {
                        let inside = String(text[text.index(after: currentIndex)..<closeIndex])
                            .trimmingCharacters(in: .whitespaces)
                            .lowercased()

                        let isEmpty = inside.isEmpty || inside == " "
                        let isFilled = inside == "x" || inside == "✓" || inside == "*"

                        if isEmpty || isFilled {
                            let afterClose = text.index(after: closeIndex)
                            var associatedText = afterClose < text.endIndex
                                ? String(text[afterClose...]).trimmingCharacters(in: .whitespaces)
                                : nil

                            // Clean up - take first meaningful word
                            if let at = associatedText {
                                let words = at.components(separatedBy: .whitespaces)
                                if let firstWord = words.first, !firstWord.isEmpty {
                                    let lower = firstWord.lowercased()
                                    if ["male", "female", "yes", "no", "m", "f", "married", "single"].contains(lower) {
                                        associatedText = firstWord
                                    }
                                }
                            }

                            checkboxes.append(KTCCheckbox(
                                boundingBox: line.boundingBox,
                                isChecked: isFilled,
                                associatedText: associatedText?.isEmpty == true ? nil : associatedText
                            ))
                            currentIndex = closeIndex
                        }
                    }
                }

                currentIndex = text.index(after: currentIndex)
            }

            // Also detect implicit checkbox patterns: "☐Male ☐Female" or "□ Male □ Female" style
            // Look for patterns where checkbox-like words appear after common symbols
            let lower = text.lowercased()
            if (lower.contains("male") || lower.contains("female")) && !checkboxes.contains(where: { $0.boundingBox == line.boundingBox }) {
                // This line mentions male/female but we didn't detect explicit checkboxes
                // Create implicit checkboxes based on text patterns
                let patterns = [
                    ("male", false),
                    ("female", false)
                ]
                for (pattern, _) in patterns {
                    if let range = lower.range(of: pattern) {
                        let word = String(text[range])
                        checkboxes.append(KTCCheckbox(
                            boundingBox: line.boundingBox,
                            isChecked: false,
                            associatedText: word.capitalized
                        ))
                    }
                }
            }
        }

        return checkboxes
    }

    // MARK: - Checkbox Grouping

    /// Known checkbox group patterns that should be matched together.
    /// Maps group label patterns → (keypath, option values to match)
    private static let checkboxGroupPatterns: [(labelPatterns: [String], keypath: String, optionMappings: [String: String])] = [
        // Sex/Gender: "M", "F", "Male", "Female" → patient.sex
        (["sex", "gender", "sex gender", "male female", "m f"],
         "patient.sex",
         ["male": "M", "m": "M", "female": "F", "f": "F"]),

        // Yes/No patterns (generic - could map to various fields)
        (["yes no", "y n"],
         "",  // No specific keypath - contextual
         ["yes": "true", "y": "true", "no": "false", "n": "false"]),

        // Marital status
        (["marital", "marital status"],
         "patient.maritalStatus",
         ["single": "S", "married": "M", "divorced": "D", "widowed": "W", "separated": "SEP"]),
    ]

    /// Group checkboxes that appear on the same line or are spatially close.
    nonisolated static func groupCheckboxes(_ checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) -> [KTCCheckboxGroup] {
        var groups: [KTCCheckboxGroup] = []
        var usedCheckboxIndices: Set<Int> = []

        // Strategy 1: Group checkboxes on the same OCR line (same boundingBox Y)
        let checkboxesByLine = Dictionary(grouping: checkboxes.enumerated()) { (_, cb) in
            // Round Y to group checkboxes on same line (within tolerance)
            Int(cb.boundingBox.midY * 1000)
        }

        for (_, lineCheckboxes) in checkboxesByLine {
            let indices = lineCheckboxes.map { $0.offset }
            let cbs = lineCheckboxes.map { $0.element }

            // If 2+ checkboxes on same line, they're likely a group
            if cbs.count >= 2 {
                // Combine bounding boxes
                let minX = cbs.map { $0.boundingBox.minX }.min() ?? 0
                let maxX = cbs.map { $0.boundingBox.maxX }.max() ?? 1
                let minY = cbs.map { $0.boundingBox.minY }.min() ?? 0
                let maxY = cbs.map { $0.boundingBox.maxY }.max() ?? 1
                let combinedBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

                // Try to find a group label from the line text
                let groupLabel = findGroupLabel(for: cbs, allLines: allLines)

                var group = KTCCheckboxGroup(
                    boundingBox: combinedBox,
                    options: cbs,
                    groupLabel: groupLabel
                )

                // Try to match to a known pattern
                if let label = groupLabel?.lowercased() {
                    for pattern in checkboxGroupPatterns {
                        if pattern.labelPatterns.contains(where: { label.contains($0) }) {
                            group.mappedKeypath = pattern.keypath.isEmpty ? nil : pattern.keypath
                            break
                        }
                    }
                }

                // Also check if option texts match known patterns (e.g., "Male", "Female")
                let optionTexts = cbs.compactMap { $0.associatedText?.lowercased() }
                for pattern in checkboxGroupPatterns {
                    let matchCount = optionTexts.filter { pattern.optionMappings.keys.contains($0) }.count
                    if matchCount >= 2 {
                        group.mappedKeypath = pattern.keypath.isEmpty ? nil : pattern.keypath
                        break
                    }
                }

                groups.append(group)
                usedCheckboxIndices.formUnion(indices)
            }
        }

        // Strategy 2: Standalone checkboxes (not part of a group) - create single-option "groups"
        for (idx, cb) in checkboxes.enumerated() {
            if !usedCheckboxIndices.contains(idx) {
                // Single checkbox - might be a yes/no toggle or consent checkbox
                var group = KTCCheckboxGroup(
                    boundingBox: cb.boundingBox,
                    options: [cb],
                    groupLabel: cb.associatedText
                )
                // If it was already checked on the form, mark it
                if cb.isChecked {
                    group.selectedIndex = 0
                }
                groups.append(group)
            }
        }

        return groups
    }

    /// Find a label that describes a checkbox group (e.g., "Sex:" before "Male ☐ Female ☐").
    private nonisolated static func findGroupLabel(for checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) -> String? {
        guard let firstCB = checkboxes.first else { return nil }
        let cbBox = firstCB.boundingBox

        // Look for text to the LEFT of the checkboxes on roughly the same line
        for line in allLines {
            let lineBox = line.boundingBox
            // Same vertical level?
            let verticalOverlap = abs(lineBox.midY - cbBox.midY) < cbBox.height * 1.5
            // To the left?
            let isToLeft = lineBox.maxX < cbBox.minX && (cbBox.minX - lineBox.maxX) < 0.2

            if verticalOverlap && isToLeft {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                // Remove trailing colon
                let cleaned = text.hasSuffix(":") ? String(text.dropLast()) : text
                if !cleaned.isEmpty && cleaned.count < 30 {
                    return cleaned
                }
            }
        }

        // Check if the checkbox option texts themselves indicate the group type
        let optionTexts = checkboxes.compactMap { $0.associatedText?.lowercased() }
        if optionTexts.contains("male") || optionTexts.contains("female") {
            return "Sex"
        }
        if optionTexts.contains("yes") || optionTexts.contains("no") {
            return "Yes/No"
        }
        if optionTexts.contains("married") || optionTexts.contains("single") {
            return "Marital Status"
        }

        return nil
    }

    // MARK: - Auto-Check Logic

    /// Auto-check the correct checkbox in each group based on patient data.
    nonisolated static func autoCheckCheckboxGroups(_ groups: inout [KTCCheckboxGroup], using data: [String: String]) {
        for i in groups.indices {
            // Skip if only one option (standalone checkbox)
            guard groups[i].options.count > 1 else { continue }

            // Try to find the patient value for this group
            var patientValue: String?

            // If group has a mapped keypath, use that
            if let keypath = groups[i].mappedKeypath {
                patientValue = data[keypath]?.lowercased()
            }

            // Also try to infer the keypath from option text
            let optionTexts = groups[i].options.compactMap { $0.associatedText?.lowercased() }
            if optionTexts.contains("male") || optionTexts.contains("female") ||
               optionTexts.contains("m") || optionTexts.contains("f") {
                // This is a sex/gender checkbox - look up patient.sex
                patientValue = data["patient.sex"]?.lowercased()
                groups[i].mappedKeypath = "patient.sex"
            } else if optionTexts.contains("yes") || optionTexts.contains("no") {
                // Yes/No checkbox - might need context
            } else if optionTexts.contains("married") || optionTexts.contains("single") {
                patientValue = data["patient.maritalStatus"]?.lowercased()
                groups[i].mappedKeypath = "patient.maritalStatus"
            }

            guard let value = patientValue else { continue }

            // Find which option matches the patient value
            for (optIdx, option) in groups[i].options.enumerated() {
                guard let optionText = option.associatedText?.lowercased().trimmingCharacters(in: .whitespaces) else { continue }

                // Direct match
                if optionText == value {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }

                // Check against known mappings
                for pattern in checkboxGroupPatterns {
                    if let mappedValue = pattern.optionMappings[optionText],
                       mappedValue.lowercased() == value {
                        groups[i].selectedIndex = optIdx
                        groups[i].options[optIdx].isChecked = true
                        break
                    }
                }

                if groups[i].selectedIndex != nil { break }

                // Fuzzy match for sex/gender: "F" matches "Female", "M" matches "Male"
                if value == "f" && (optionText == "female" || optionText.hasPrefix("female") || optionText == "f") {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
                if value == "m" && (optionText == "male" || optionText.hasPrefix("male") || optionText == "m") {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }

                // Also handle reverse: patient has "female" and checkbox is "F"
                if (value == "female" || value == "f") && (optionText == "f" || optionText == "female" || optionText.contains("female")) {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
                if (value == "male" || value == "m") && (optionText == "m" || optionText == "male" || optionText.contains("male")) {
                    groups[i].selectedIndex = optIdx
                    groups[i].options[optIdx].isChecked = true
                    break
                }
            }
        }
    }

    /// Classify field types and create checkbox fields for detected checkboxes.
    nonisolated static func classifyFieldTypes(_ fields: inout [KTCField], checkboxes: [KTCCheckbox], allLines: [KTCRecognizedLine]) {
        // Mark fields as checkbox type if they contain checkbox-related terms
        let checkboxTerms = ["male", "female", "yes", "no", "married", "single", "divorced", "widowed"]
        let checkboxLabelTerms = ["sex", "gender", "marital status", "marital"]

        for i in fields.indices {
            let lower = fields[i].label.lowercased()

            // Check if label IS a checkbox option (yes/no, male/female, etc.)
            if checkboxTerms.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") }) {
                fields[i].fieldType = .checkbox
            }

            // Check if label is a checkbox GROUP label (sex, gender, marital status)
            // These should NOT be filled with text - they have checkbox options
            if checkboxLabelTerms.contains(where: { lower == $0 || lower.hasPrefix($0 + ":") || lower.hasPrefix($0 + " ") }) {
                fields[i].fieldType = .checkbox
            }

            // Check if label is about signatures
            if lower.contains("signature") || lower.contains("sign here") ||
               lower.contains("participant sign") || lower.contains("patient sign") ||
               lower.contains("authorized sign") || lower.contains("sign below") ||
               lower.contains("sign above") || lower == "sign" {
                fields[i].fieldType = .signature
            }

            // Check if label is specifically a date field
            if lower.contains("date") && !lower.contains("birth") {
                fields[i].fieldType = .date
            }
        }

        // Create fields for standalone checkboxes that aren't part of existing fields
        for checkbox in checkboxes {
            if let text = checkbox.associatedText, !text.isEmpty {
                // Check if this checkbox text is already a field
                let alreadyExists = fields.contains { $0.label.lowercased() == text.lowercased() }
                if !alreadyExists && text.count <= 30 {
                    var field = KTCField(
                        label: text,
                        labelBoundingBox: checkbox.boundingBox
                    )
                    field.fieldType = .checkbox
                    field.isChecked = checkbox.isChecked
                    fields.append(field)
                }
            }
        }
    }
}

// MARK: - Patient Data Loader & Fuzzy Matcher

/// Handles loading the demo JSON, flattening it, and fuzzy-matching labels to keypaths.
enum KTCPatientDataLoader {
    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC-Mapper")

    // MARK: - Load & Flatten

    /// Load ktc-demo-patient.json from the bundle and flatten to [keypath: value].
    static func loadAndFlatten() -> [String: String] {
        guard let url = Bundle.main.url(forResource: "ktc-demo-patient", withExtension: "json") else {
            logger.error("ktc-demo-patient.json not found in bundle")
            return [:]
        }
        do {
            let data = try Data(contentsOf: url)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("JSON root is not a dictionary")
                return [:]
            }
            var flat: [String: String] = [:]
            flatten(json, prefix: "", into: &flat)

            // Computed: fullName
            if let first = flat["patient.firstName"], let last = flat["patient.lastName"] {
                flat["patient.fullName"] = "\(first) \(last)"
            }

            // Computed: fullAddress (single-line)
            let addrParts = [
                flat["patient.address.line1"],
                flat["patient.address.line2"],
                flat["patient.address.city"],
                flat["patient.address.state"],
                flat["patient.address.postalCode"]
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if !addrParts.isEmpty {
                flat["patient.fullAddress"] = addrParts.joined(separator: ", ")
            }

            // Computed: today's date (MM/DD/YYYY — US medical form standard)
            let fmt = DateFormatter()
            fmt.dateFormat = "MM/dd/yyyy"
            flat["_computed.todayDate"] = fmt.string(from: Date())

            // Computed: patient age from DOB
            if let dobStr = flat["patient.dateOfBirth"] {
                let isoFmt = DateFormatter()
                isoFmt.dateFormat = "yyyy-MM-dd"
                if let dob = isoFmt.date(from: dobStr) {
                    let age = Calendar.current.dateComponents([.year], from: dob, to: Date()).year ?? 0
                    flat["_computed.patientAge"] = "\(age)"
                }
            }

            // Computed: DOB formatted as MM/DD/YYYY (common US form format)
            if let dobStr = flat["patient.dateOfBirth"] {
                let isoFmt = DateFormatter()
                isoFmt.dateFormat = "yyyy-MM-dd"
                if let dob = isoFmt.date(from: dobStr) {
                    flat["_computed.dobFormatted"] = fmt.string(from: dob)
                }
            }

            logger.info("Loaded \(flat.count) patient keypaths (incl. computed)")
            return flat
        } catch {
            logger.error("Failed to load patient JSON: \(error.localizedDescription)")
            return [:]
        }
    }

    /// Recursively flatten a JSON dictionary into dot-separated keypaths.
    private static func flatten(_ obj: Any, prefix: String, into result: inout [String: String]) {
        if let dict = obj as? [String: Any] {
            for (key, value) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                flatten(value, prefix: path, into: &result)
            }
        } else if let array = obj as? [Any] {
            for (i, value) in array.enumerated() {
                flatten(value, prefix: "\(prefix)[\(i)]", into: &result)
            }
        } else {
            result[prefix] = "\(obj)"
        }
    }

    // MARK: - Synonym Map

    /// Maps normalized label text → canonical keypath tail.
    /// Multiple synonyms can point to the same keypath.
    private static let synonyms: [(patterns: [String], keypath: String)] = [
        // ===== NAME =====
        (["full name", "patient name", "participant name", "name of patient",
          "patient s name", "patients name", "name last first", "legal name",
          "name last first middle", "print name", "printed name", "name print",
          "name please print", "name of insured", "insured name", "insured s name",
          "name of applicant", "applicant name", "your name", "client name",
          "individual name", "person name", "name of individual"], "patient.fullName"),
        (["first name", "given name", "first", "forename", "fname",
          "patient first name", "legal first name"], "patient.firstName"),
        (["last name", "surname", "family name", "last", "lname",
          "patient last name", "legal last name"], "patient.lastName"),
        (["middle name", "middle initial", "middle", "mi", "m i",
          "middle i", "mname"], "patient.middleName"),

        // ===== DOB / AGE =====
        (["dob", "date of birth", "birth date", "birthday", "birthdate",
          "d o b", "d o b ", "born", "birth", "patient dob", "patient date of birth",
          "patient s date of birth", "date of birth mm dd yyyy", "date of birth mm dd yy",
          "birthdate mm dd yyyy", "b date"], "_computed.dobFormatted"),
        (["age", "patient age", "current age", "age years", "age yrs"], "_computed.patientAge"),

        // ===== SEX / GENDER =====
        (["sex", "gender", "sex gender", "sex or gender", "patient sex",
          "male female", "male   female", "m f", "m or f", "patient gender",
          "biological sex", "sex at birth", "gender identity"], "patient.sex"),

        // ===== PHONE =====
        (["phone", "telephone", "cell", "mobile", "phone number", "tel",
          "cell phone", "home phone", "daytime phone", "phone no", "ph",
          "contact number", "contact phone", "primary phone", "main phone",
          "telephone number", "phone home", "phone cell", "phone mobile",
          "best phone", "preferred phone", "callback number", "patient phone",
          "patient telephone", "evening phone", "day phone"], "patient.phone"),

        // ===== EMAIL =====
        (["email", "e mail", "email address", "e mail address",
          "electronic mail", "patient email", "email id", "e mail id",
          "contact email", "preferred email"], "patient.email"),

        // ===== ADDRESS =====
        (["address", "street", "street address", "address line 1",
          "address 1", "line 1", "mailing address", "home address",
          "street address line 1", "residential address", "residence",
          "current address", "physical address", "patient address",
          "home street address", "street name", "street number",
          "address street", "address number and street"], "patient.address.line1"),
        (["address line 2", "address 2", "line 2", "apt", "suite",
          "unit", "apt suite", "apartment", "apt no", "suite no", "unit no",
          "apt number", "suite number", "unit number", "floor",
          "building", "bldg"], "patient.address.line2"),
        (["city", "city town", "town", "municipality", "city name"], "patient.address.city"),
        (["state", "state province", "st", "province", "state code"], "patient.address.state"),
        (["zip", "zip code", "zipcode", "postal code", "postal",
          "zip postal", "zip 4", "zip 5", "zip plus 4", "zip code 5 digit",
          "postal zip"], "patient.address.postalCode"),
        (["full address", "complete address", "mailing address full",
          "address city state zip", "street city state zip"], "patient.fullAddress"),

        // ===== INSURANCE =====
        (["member id", "member no", "member number", "subscriber id",
          "subscriber", "id number", "identification number",
          "subscriber number", "policy number", "policy no", "policy id",
          "insurance id", "insured id", "insured s id", "contract number",
          "certificate number", "member identification", "id no",
          "insurance member id", "health plan id", "plan id number"], "patient.insurance.memberId"),
        (["group", "group id", "group no", "group number",
          "grp", "grp no", "group plan", "group name", "group policy",
          "employer group", "employer group number", "rx group",
          "rx grp", "rxgrp", "bin", "pcn"], "patient.insurance.groupId"),
        (["payer", "insurance", "insurance company", "plan", "carrier",
          "health plan", "insurance plan", "insurance name",
          "insurance carrier", "plan name", "insurer", "insurance provider",
          "health insurance", "medical insurance", "insurance co",
          "name of insurance", "name of health plan", "name of carrier",
          "primary insurance", "secondary insurance"], "patient.insurance.payer"),

        // ===== TODAY'S DATE =====
        (["today s date", "todays date", "today date", "current date",
          "date signed", "date of signature", "signature date",
          "date today", "today", "date completed", "completion date",
          "form date", "date of form", "effective date",
          "date of authorization", "authorization date"], "_computed.todayDate"),
        // Date (standalone — most forms mean "today's date")
        (["date"], "_computed.todayDate"),
    ]

    // MARK: - Fuzzy Match

    struct MatchResult {
        let keypath: String
        let value: String
        let confidence: Double  // 0-1
        let method: String  // "synonym-exact", "synonym-contains", "token", "embedding"
    }

    /// Try to match a label string to a keypath with confidence scoring.
    static func fuzzyMatch(label: String, in data: [String: String]) -> MatchResult? {
        let normalized = normalize(label)

        // 1. Exact synonym match (confidence: 1.0)
        for entry in synonyms {
            for pattern in entry.patterns {
                if normalized == pattern {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 1.0, method: "synonym-exact")
                    }
                }
            }
        }

        // 2. Whole-word substring match (confidence: 0.9)
        for entry in synonyms {
            for pattern in entry.patterns {
                if pattern.count >= 3 && containsWholeWords(normalized, pattern: pattern) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.9, method: "synonym-contains")
                    }
                }
            }
        }

        // 2b. Partial substring match - pattern found anywhere in label (confidence: 0.8)
        for entry in synonyms {
            for pattern in entry.patterns {
                if pattern.count >= 4 && normalized.contains(pattern) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.8, method: "synonym-partial")
                    }
                }
            }
        }

        // 2c. Label found in pattern (reverse match) - e.g., "city" found in "city town" (confidence: 0.75)
        for entry in synonyms {
            for pattern in entry.patterns {
                if normalized.count >= 3 && pattern.contains(normalized) {
                    if let value = data[entry.keypath] {
                        return MatchResult(keypath: entry.keypath, value: value,
                                           confidence: 0.75, method: "synonym-reverse")
                    }
                }
            }
        }

        // 3. Token overlap with keypath tails (confidence: based on Jaccard score)
        let labelTokens = tokenize(normalized)
        if !labelTokens.isEmpty {
            var bestScore: Double = 0
            var bestKeypath: String?

            for keypath in data.keys {
                let tail = keypath.components(separatedBy: ".").last ?? keypath
                let keypathTokens = tokenize(camelCaseToWords(tail))
                guard !keypathTokens.isEmpty else { continue }

                let labelSet = Set(labelTokens)
                let keypathSet = Set(keypathTokens)
                let intersection = labelSet.intersection(keypathSet).count
                let union = labelSet.union(keypathSet).count
                let score = Double(intersection) / Double(union)

                if score > bestScore {
                    bestScore = score
                    bestKeypath = keypath
                }
            }

            // Lower threshold to 0.3 for more matches
            if bestScore >= 0.3, let keypath = bestKeypath, let value = data[keypath] {
                return MatchResult(keypath: keypath, value: value,
                                   confidence: bestScore * 0.7, method: "token")
            }
        }

        // 4. NLEmbedding semantic similarity (confidence: based on cosine distance)
        if let embeddingMatch = embeddingMatch(label: normalized, in: data) {
            return embeddingMatch
        }

        return nil
    }

    /// Use NLEmbedding to find semantically similar keypaths.
    private static func embeddingMatch(label: String, in data: [String: String]) -> MatchResult? {
        // Get the word embedding model for English
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return nil
        }

        var bestDistance: Double = 2.0  // Max cosine distance is 2.0
        var bestKeypath: String?

        for keypath in data.keys {
            // Convert keypath tail to readable words
            let tail = keypath.components(separatedBy: ".").last ?? keypath
            let readableTail = camelCaseToWords(tail)

            // Compare the main word in the label to the keypath tail
            let labelWords = label.lowercased().components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for labelWord in labelWords {
                // Skip very short words
                if labelWord.count < 3 { continue }

                let tailWords = readableTail.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                for tailWord in tailWords {
                    if tailWord.count < 3 { continue }

                    // NLEmbedding requires lowercase
                    let distance = embedding.distance(between: labelWord, and: tailWord)
                    if distance < bestDistance {
                        bestDistance = distance
                        bestKeypath = keypath
                    }
                }
            }
        }

        // Convert distance to confidence (distance 0 = identical, distance ~1 = unrelated)
        // Require distance < 0.8 for a match (fairly strict)
        if bestDistance < 0.8, let keypath = bestKeypath, let value = data[keypath] {
            let confidence = max(0, (0.8 - bestDistance) / 0.8) * 0.7  // Scale to max 0.7
            return MatchResult(keypath: keypath, value: value,
                               confidence: confidence, method: "embedding")
        }

        return nil
    }

    /// Apply fuzzy matching to all fields with confidence scoring.
    static func applyMappings(to fields: inout [KTCField], using data: [String: String]) {
        for i in fields.indices {
            let label = fields[i].label
            if let match = fuzzyMatch(label: label, in: data) {
                fields[i].mappedKeypath = match.keypath
                fields[i].value = match.value
                fields[i].matchConfidence = match.confidence
                fields[i].matchMethod = match.method
                logger.info("Mapped '\(label)' → \(match.keypath) [\(match.method), \(String(format: "%.0f", match.confidence * 100))%]")
            } else {
                logger.info("No match for '\(label)'")
            }
        }
    }

    // MARK: - Text Helpers

    /// Normalize a label: lowercase, strip punctuation, collapse whitespace.
    private static func normalize(_ text: String) -> String {
        let lower = text.lowercased()
        let cleaned = lower.unicodeScalars.map { char -> Character in
            if CharacterSet.alphanumerics.contains(char) || char == " " {
                return Character(char)
            }
            return " "
        }
        return String(cleaned)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Tokenize a string into lowercase words.
    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && $0.count > 1 }
    }

    /// Check if `pattern` appears in `text` at word boundaries.
    /// e.g. "city" is found in "my city name" but NOT in "ethnicity".
    private static func containsWholeWords(_ text: String, pattern: String) -> Bool {
        let padded = " \(text) "
        return padded.contains(" \(pattern) ")
    }

    /// Convert camelCase to space-separated words. "postalCode" → "postal code"
    private static func camelCaseToWords(_ text: String) -> String {
        var result = ""
        for char in text {
            if char.isUppercase && !result.isEmpty {
                result += " "
            }
            result += String(char).lowercased()
        }
        return result
    }
}
