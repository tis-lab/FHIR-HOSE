//
//  KTCPDFGenerator.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 3/31/26.
//

import OSLog
import PDFKit
import UIKit

/// Generates filled PDFs using PDFKit annotations.
/// Text values are vector/searchable FreeText annotations instead of rasterized draws.
enum KTCPDFGenerator {

    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC.PDF")

    /// Generate a filled PDF with PDFKit annotations.
    /// Returns a temporary file URL, or nil on failure.
    static func generate(
        image: UIImage,
        fields: [KTCField],
        checkboxGroups: [KTCCheckboxGroup],
        signatureImage: UIImage?,
        signatureSize: CGSize,
        signatureNormalizedPosition: CGPoint?,
        signatureField: KTCField?
    ) -> URL? {
        let t0 = CFAbsoluteTimeGetCurrent()
        let pageSize = CGSize(width: image.size.width, height: image.size.height)

        // Step 1: Create base PDF with scanned image + signature baked in
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize))
        let baseData = renderer.pdfData { ctx in
            ctx.beginPage()
            image.draw(in: CGRect(origin: .zero, size: pageSize))

            // Draw signature into the base image (annotations can't embed images easily)
            if let sigImage = signatureImage {
                let sigWidth = signatureSize.width * (pageSize.width / 400)
                let sigHeight = signatureSize.height * (pageSize.height / 600)
                let sigRect: CGRect

                if let normalizedPos = signatureNormalizedPosition {
                    let x = normalizedPos.x * pageSize.width - sigWidth / 2
                    let y = (1.0 - normalizedPos.y) * pageSize.height - sigHeight / 2
                    sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
                } else if let field = signatureField {
                    let box = field.labelBoundingBox
                    let x = (box.origin.x + box.width) * pageSize.width + 6
                    let y = (1.0 - box.origin.y - box.height) * pageSize.height
                    sigRect = CGRect(x: x, y: y, width: sigWidth, height: sigHeight)
                } else {
                    sigRect = CGRect(
                        x: pageSize.width - sigWidth - 40,
                        y: pageSize.height - sigHeight - 60,
                        width: sigWidth,
                        height: sigHeight
                    )
                }

                sigImage.draw(in: sigRect)
            }
        }

        // Step 2: Open with PDFKit and add annotations
        guard let pdfDoc = PDFDocument(data: baseData),
              let page = pdfDoc.page(at: 0) else {
            logger.error("Failed to create PDFDocument from rendered image")
            return nil
        }

        let checkboxKeypaths = Set(checkboxGroups.compactMap { $0.mappedKeypath })
        var annotationCount = 0

        // Add text value annotations
        let filledFields = fields.filter { !$0.value.isEmpty }
        for field in filledFields {
            if let keypath = field.mappedKeypath, checkboxKeypaths.contains(keypath) { continue }
            if field.fieldType == .checkbox || field.fieldType == .signature { continue }
            let trimmed = field.value.trimmingCharacters(in: .whitespaces)
            if trimmed.count == 1 && "MFYNmfyn".contains(trimmed) { continue }

            let labelBox = field.labelBoundingBox
            let labelH = labelBox.height * pageSize.height
            let fontSize = max(10, min(18, labelH * 0.8))

            let (valueX, valueY, textSize) = calculateValuePosition(
                field: field, pageSize: pageSize, fontSize: fontSize
            )

            // PDFKit uses bottom-left origin (same as PDF spec), but page.bounds
            // may differ. Convert from top-left draw coords to PDF coords.
            let pdfY = pageSize.height - valueY - textSize.height

            let annotBounds = CGRect(
                x: valueX - 2,
                y: pdfY - 1,
                width: textSize.width + 4,
                height: textSize.height + 2
            )

            let annotation = PDFAnnotation(bounds: annotBounds, forType: .freeText, withProperties: nil)
            annotation.contents = field.value
            annotation.font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
            annotation.fontColor = .black
            annotation.color = UIColor.white.withAlphaComponent(0.85)
            annotation.alignment = .left

            page.addAnnotation(annotation)
            annotationCount += 1
        }

        // Add checkbox marks
        for group in checkboxGroups {
            guard let selectedIdx = group.selectedIndex, selectedIdx < group.options.count else { continue }
            let option = group.options[selectedIdx]
            let box = option.boundingBox

            let x = box.origin.x * pageSize.width
            let pdfY = box.origin.y * pageSize.height  // PDF coords = Vision coords (both bottom-left)
            let h = box.height * pageSize.height
            let checkSize = max(10, min(18, h * 0.7))

            let annotBounds = CGRect(x: x, y: pdfY, width: checkSize + 4, height: h)
            let annotation = PDFAnnotation(bounds: annotBounds, forType: .freeText, withProperties: nil)
            annotation.contents = "X"
            annotation.font = UIFont.systemFont(ofSize: checkSize, weight: .bold)
            annotation.fontColor = .black
            annotation.color = .clear
            annotation.alignment = .left

            page.addAnnotation(annotation)
            annotationCount += 1
        }

        // Step 3: Write to temp file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("KTC-FilledForm-v2.pdf")

        guard pdfDoc.write(to: tempURL) else {
            logger.error("Failed to write annotated PDF")
            return nil
        }

        let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int) ?? 0
        logger.info("Generated annotated PDF in \(elapsed)ms (\(annotationCount) annotations, \(fileSize) bytes)")

        return tempURL
    }

    // MARK: - AcroForm Detection

    /// Check if a PDF has existing form fields (AcroForm widgets).
    /// Returns the field names and types if found.
    static func detectFormFields(in pdfDoc: PDFDocument) -> [(name: String, type: String, page: Int)] {
        var fields: [(name: String, type: String, page: Int)] = []

        for pageIdx in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIdx) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let name = annotation.fieldName ?? "unnamed"
                let type: String
                switch annotation.widgetFieldType {
                case .text: type = "text"
                case .button: type = "button"
                case .choice: type = "choice"
                default: type = "unknown"
                }
                fields.append((name: name, type: type, page: pageIdx))
            }
        }

        if !fields.isEmpty {
            logger.info("Detected \(fields.count) AcroForm fields in PDF")
        }

        return fields
    }

    /// Fill existing AcroForm fields in a PDF with patient data.
    /// Returns the modified PDF document.
    static func fillFormFields(
        in pdfDoc: PDFDocument,
        using patientData: [String: String]
    ) -> PDFDocument {
        for pageIdx in 0..<pdfDoc.pageCount {
            guard let page = pdfDoc.page(at: pageIdx) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                guard let fieldName = annotation.fieldName else { continue }

                // Try to match field name to patient data
                if let match = KTCPatientDataLoader.fuzzyMatch(label: fieldName, in: patientData) {
                    switch annotation.widgetFieldType {
                    case .text:
                        annotation.setValue(match.value, forAnnotationKey: .widgetValue)
                        // Force appearance refresh
                        page.removeAnnotation(annotation)
                        page.addAnnotation(annotation)
                        logger.info("Filled AcroForm field '\(fieldName)' = '\(match.value)'")
                    case .button:
                        if match.value.lowercased() == "yes" || match.value.lowercased() == "true" {
                            annotation.buttonWidgetState = .onState
                        }
                    default:
                        break
                    }
                }
            }
        }

        return pdfDoc
    }

    // MARK: - Helpers

    private static func calculateValuePosition(
        field: KTCField,
        pageSize: CGSize,
        fontSize: CGFloat
    ) -> (x: CGFloat, y: CGFloat, textSize: CGSize) {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (field.value as NSString).size(withAttributes: attributes)

        if let adjustedBox = field.adjustedValueBox {
            let charCount = CGFloat(field.value.count)
            let estBadgeWidth = max(30.0, charCount * 6.0 + 16.0)
            let padFraction = 10.0 / estBadgeWidth
            let x = (adjustedBox.origin.x + padFraction * adjustedBox.width) * pageSize.width
            let centerY = (1.0 - adjustedBox.origin.y - adjustedBox.height / 2) * pageSize.height
            let y = centerY - textSize.height / 2
            return (x, y, textSize)
        }

        let box = field.labelBoundingBox
        let x = box.origin.x * pageSize.width
        let y = (1.0 - box.origin.y - box.height) * pageSize.height
        let w = box.width * pageSize.width
        let h = box.height * pageSize.height

        let isShortLabel = field.label.count < 20 && !field.label.contains(":")
        if isShortLabel {
            return (x, y + h + 2, textSize)
        } else {
            return (x + w + 4, y + (h - textSize.height) / 2, textSize)
        }
    }

}
