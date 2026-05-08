//
//  KTCRectangleDetector.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 3/31/26.
//

import OSLog
import UIKit
import Vision

/// Detects rectangular input areas on scanned forms using VNDetectRectanglesRequest.
/// Classifies detected rectangles as text fields, checkboxes, or signature lines
/// based on geometry, and associates them with nearby OCR text labels.
enum KTCRectangleDetector {

    private static let logger = Logger(subsystem: "com.fhirhose.app", category: "KTC.Rects")

    /// Classification of a detected rectangle based on its geometry.
    enum RectType {
        case checkbox       // roughly square, small
        case textField      // wide, medium height
        case signatureLine  // very wide, short height
        case unknown
    }

    /// A detected rectangle with its classification and associated OCR text.
    struct DetectedRect {
        let boundingBox: CGRect   // Vision normalized coords (0-1, origin bottom-left)
        let corners: (topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint)
        let type: RectType
        let confidence: Float
    }

    // MARK: - Detection

    /// Detect rectangles in a form image and classify them by geometry.
    static func detect(in cgImage: CGImage) throws -> [DetectedRect] {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Run multiple passes with different configs to catch both
        // small checkboxes and large text fields
        var allRects: [DetectedRect] = []

        // Pass 1: Small squares (checkboxes)
        let checkboxRects = try detectPass(
            cgImage: cgImage,
            minimumSize: 0.008,
            maximumObservations: 40,
            minimumAspectRatio: 0.7,
            maximumAspectRatio: 1.4,
            minimumConfidence: 0.6,
            quadratureTolerance: 15.0
        )
        allRects.append(contentsOf: checkboxRects)

        // Pass 2: Wide rectangles (text fields, signature lines)
        let fieldRects = try detectPass(
            cgImage: cgImage,
            minimumSize: 0.02,
            maximumObservations: 30,
            minimumAspectRatio: 1.5,
            maximumAspectRatio: 15.0,
            minimumConfidence: 0.5,
            quadratureTolerance: 20.0
        )
        allRects.append(contentsOf: fieldRects)

        // Deduplicate overlapping rectangles
        let deduped = deduplicateRects(allRects)

        let elapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        let checkboxCount = deduped.filter { $0.type == .checkbox }.count
        let textFieldCount = deduped.filter { $0.type == .textField }.count
        let sigCount = deduped.filter { $0.type == .signatureLine }.count
        logger.info("Detected \(deduped.count) rectangles in \(elapsed)ms (\(checkboxCount) checkboxes, \(textFieldCount) text fields, \(sigCount) signature lines)")

        return deduped
    }

    private static func detectPass(
        cgImage: CGImage,
        minimumSize: Float,
        maximumObservations: Int,
        minimumAspectRatio: Float,
        maximumAspectRatio: Float,
        minimumConfidence: Float,
        quadratureTolerance: Float
    ) throws -> [DetectedRect] {
        let request = VNDetectRectanglesRequest()
        request.minimumSize = minimumSize
        request.maximumObservations = maximumObservations
        request.minimumAspectRatio = minimumAspectRatio
        request.maximumAspectRatio = maximumAspectRatio
        request.minimumConfidence = minimumConfidence
        request.quadratureTolerance = quadratureTolerance

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let results = request.results else { return [] }

        return results.map { obs in
            let box = obs.boundingBox
            let corners = (
                topLeft: obs.topLeft,
                topRight: obs.topRight,
                bottomLeft: obs.bottomLeft,
                bottomRight: obs.bottomRight
            )
            let type = classify(boundingBox: box)
            return DetectedRect(
                boundingBox: box,
                corners: corners,
                type: type,
                confidence: obs.confidence
            )
        }
    }

    // MARK: - Classification

    /// Classify a rectangle by its aspect ratio and size.
    /// Coordinates are Vision-normalized (0-1).
    private static func classify(boundingBox box: CGRect) -> RectType {
        let aspect = box.width / max(box.height, 0.001)

        // Checkbox: roughly square, small
        if aspect >= 0.6 && aspect <= 1.6 && box.width < 0.06 && box.height < 0.06 {
            return .checkbox
        }

        // Signature line: very wide, short
        if aspect > 5.0 && box.height < 0.03 {
            return .signatureLine
        }

        // Text field: wider than tall, reasonable size
        if aspect > 1.5 && box.width > 0.05 {
            return .textField
        }

        return .unknown
    }

    // MARK: - Association with OCR text

    /// Associate detected rectangles with nearby OCR text labels.
    /// Returns new KTCFields created from rectangles that have a nearby label,
    /// and KTCCheckboxes for checkbox-type rectangles.
    static func associateWithText(
        rects: [DetectedRect],
        ocrLines: [KTCRecognizedLine],
        existingFields: [KTCField]
    ) -> (fields: [KTCField], checkboxes: [KTCCheckbox]) {
        var newFields: [KTCField] = []
        var newCheckboxes: [KTCCheckbox] = []

        // Build set of existing field label boxes to avoid duplicates
        let existingBoxes = existingFields.map(\.labelBoundingBox)

        for rect in rects {
            // Skip if this rectangle overlaps with an already-detected field
            let overlapsExisting = existingBoxes.contains { existing in
                existing.intersects(rect.boundingBox.insetBy(dx: -0.005, dy: -0.005))
            }
            if overlapsExisting { continue }

            switch rect.type {
            case .checkbox:
                let checkbox = makeCheckbox(from: rect, ocrLines: ocrLines)
                newCheckboxes.append(checkbox)

            case .textField:
                if let field = makeTextField(from: rect, ocrLines: ocrLines) {
                    // Check we haven't already created a field with the same label
                    let isDupe = newFields.contains { $0.label.lowercased() == field.label.lowercased() }
                        || existingFields.contains { $0.label.lowercased() == field.label.lowercased() }
                    if !isDupe {
                        newFields.append(field)
                    }
                }

            case .signatureLine:
                var field = KTCField(
                    label: findNearestLabel(for: rect, in: ocrLines, direction: .left) ?? "Signature",
                    labelBoundingBox: rect.boundingBox
                )
                field.fieldType = .signature
                field.valueBoundingBox = rect.boundingBox
                newFields.append(field)

            case .unknown:
                break
            }
        }

        logger.info("Associated \(newFields.count) new fields and \(newCheckboxes.count) new checkboxes from rectangles")
        return (newFields, newCheckboxes)
    }

    // MARK: - Helpers

    private enum SearchDirection {
        case left       // look for text to the left of the rect
        case above      // look for text above the rect
        case any        // nearest in any direction
    }

    /// Find the nearest OCR text line to a rectangle in a given direction.
    private static func findNearestLabel(
        for rect: DetectedRect,
        in lines: [KTCRecognizedLine],
        direction: SearchDirection
    ) -> String? {
        let box = rect.boundingBox
        var best: (text: String, distance: CGFloat) = ("", .greatestFiniteMagnitude)

        for line in lines {
            let lb = line.boundingBox
            let distance: CGFloat

            switch direction {
            case .left:
                // Text should be to the left and vertically aligned
                let verticalOverlap = min(lb.maxY, box.maxY) - max(lb.minY, box.minY)
                guard verticalOverlap > box.height * 0.3 else { continue }
                let gap = box.minX - lb.maxX
                guard gap > -0.01 && gap < 0.15 else { continue }
                distance = max(0, gap)

            case .above:
                // Text should be above (higher Y in Vision coords) and horizontally aligned
                let horizontalOverlap = min(lb.maxX, box.maxX) - max(lb.minX, box.minX)
                guard horizontalOverlap > box.width * 0.2 else { continue }
                let gap = lb.minY - box.maxY
                guard gap > -0.01 && gap < 0.08 else { continue }
                distance = max(0, gap)

            case .any:
                let dx = lb.midX - box.midX
                let dy = lb.midY - box.midY
                distance = sqrt(dx * dx + dy * dy)
                guard distance < 0.12 else { continue }
            }

            if distance < best.distance {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                // Skip very long lines (likely paragraphs, not labels)
                guard text.count >= 2 && text.count <= 60 else { continue }
                best = (text, distance)
            }
        }

        return best.text.isEmpty ? nil : best.text
    }

    /// Create a KTCCheckbox from a checkbox-type rectangle.
    private static func makeCheckbox(from rect: DetectedRect, ocrLines: [KTCRecognizedLine]) -> KTCCheckbox {
        // Look for text to the right of the checkbox (most common layout)
        let box = rect.boundingBox
        var associatedText: String?

        for line in ocrLines {
            let lb = line.boundingBox
            // Text to the right, vertically aligned
            let verticalOverlap = min(lb.maxY, box.maxY) - max(lb.minY, box.minY)
            guard verticalOverlap > box.height * 0.3 else { continue }
            let gap = lb.minX - box.maxX
            guard gap > -0.01 && gap < 0.08 else { continue }

            let text = line.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty && text.count <= 40 {
                associatedText = text
                break
            }
        }

        // If nothing to the right, try left
        if associatedText == nil {
            associatedText = findNearestLabel(for: rect, in: ocrLines, direction: .left)
        }

        return KTCCheckbox(
            boundingBox: box,
            isChecked: false,
            associatedText: associatedText
        )
    }

    /// Create a KTCField from a text-field-type rectangle.
    private static func makeTextField(from rect: DetectedRect, ocrLines: [KTCRecognizedLine]) -> KTCField? {
        // Look for a label to the left first (most common: "Name: [____]")
        // Then try above (column layout: "Name\n[____]")
        let label = findNearestLabel(for: rect, in: ocrLines, direction: .left)
            ?? findNearestLabel(for: rect, in: ocrLines, direction: .above)

        guard let label else { return nil }

        // Check if there's text inside the rectangle (pre-filled value)
        var detectedValue: String?
        for line in ocrLines {
            let lb = line.boundingBox
            // Line center is inside the rectangle
            let insetBox = rect.boundingBox.insetBy(dx: -0.005, dy: -0.005)
            if insetBox.contains(CGPoint(x: lb.midX, y: lb.midY)) {
                let text = line.text.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "_", with: "")
                    .replacingOccurrences(of: "-", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if text.count >= 2 {
                    detectedValue = text
                    break
                }
            }
        }

        var field = KTCField(
            label: label,
            labelBoundingBox: rect.boundingBox
        )
        field.fieldType = .text
        field.valueBoundingBox = rect.boundingBox
        field.detectedValue = detectedValue
        return field
    }

    /// Remove rectangles that overlap significantly (keep higher confidence).
    private static func deduplicateRects(_ rects: [DetectedRect]) -> [DetectedRect] {
        guard rects.count > 1 else { return rects }

        var kept: [DetectedRect] = []
        let sorted = rects.sorted { $0.confidence > $1.confidence }

        for rect in sorted {
            let dominated = kept.contains { existing in
                let intersection = existing.boundingBox.intersection(rect.boundingBox)
                guard !intersection.isNull else { return false }
                let overlapArea = intersection.width * intersection.height
                let rectArea = rect.boundingBox.width * rect.boundingBox.height
                return rectArea > 0 && overlapArea / rectArea > 0.5
            }
            if !dominated {
                kept.append(rect)
            }
        }

        return kept
    }
}
