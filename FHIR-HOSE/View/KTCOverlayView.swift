//
//  KTCOverlayView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import SwiftUI
import UIKit

/// Displays the scanned image with bounding-box overlays for detected fields.
struct KTCOverlayView: View {
    let image: UIImage
    let fields: [KTCField]
    let showLabelBoxes: Bool
    var checkboxGroups: [KTCCheckboxGroup] = []
    var onFieldValueDrag: ((UUID, CGRect) -> Void)?  // fieldId, new normalized box
    var signatureImage: UIImage?
    var signatureField: KTCField?
    var signatureSize: CGSize = CGSize(width: 60, height: 24)
    var signatureNormalizedPos: CGPoint? = nil  // Normalized position (0-1)
    var onSignatureDrag: ((CGPoint) -> Void)?  // Returns normalized position

    // For Add Field mode
    var availableLines: [KTCRecognizedLine] = []
    var isAddingField: Bool = false
    var onLineSelected: ((KTCRecognizedLine) -> Void)?

    // Edit mode
    var isEditingPositions: Bool = false

    // Zoom scale (for adjusting drag coordinates)
    var zoomScale: CGFloat = 1.0

    // Debug mode: show detected rectangles and OCR lines
    var debugRects: [KTCRectangleDetector.DetectedRect] = []
    var debugOCRLines: [KTCRecognizedLine] = []

    var body: some View {
        GeometryReader { geo in
            let fittedRect = Self.aspectFitRect(
                imageSize: image.size,
                containerSize: geo.size
            )

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .topLeading) {
                    // In Add Field mode, show available OCR lines
                    if isAddingField {
                        ForEach(availableLines) { line in
                            let rect = Self.visionToSwiftUI(
                                visionBox: line.boundingBox,
                                fittedRect: fittedRect
                            )
                            Rectangle()
                                .fill(Color.orange.opacity(0.2))
                                .frame(width: rect.width, height: rect.height)
                                .overlay(Rectangle().stroke(Color.orange, lineWidth: 1))
                                .position(x: rect.midX, y: rect.midY)
                                .onTapGesture { onLineSelected?(line) }
                        }
                    }

                    // Debug: Draw OCR line bounding boxes
                    if !debugOCRLines.isEmpty {
                        ForEach(debugOCRLines) { line in
                            let rect = Self.visionToSwiftUI(
                                visionBox: line.boundingBox,
                                fittedRect: fittedRect
                            )
                            Rectangle()
                                .stroke(Color.yellow.opacity(0.5), lineWidth: 0.5)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                        }
                    }

                    // Debug: Draw detected rectangles color-coded by type
                    ForEach(Array(debugRects.enumerated()), id: \.offset) { _, dRect in
                        let rect = Self.visionToSwiftUI(
                            visionBox: dRect.boundingBox,
                            fittedRect: fittedRect
                        )
                        let color: Color = switch dRect.type {
                        case .checkbox: .green
                        case .textField: .blue
                        case .signatureLine: .orange
                        case .unknown: .gray
                        }
                        Rectangle()
                            .stroke(color, lineWidth: 2)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        // Type label
                        let typeLabel: String = {
                            switch dRect.type {
                            case .checkbox: return "CB"
                            case .textField: return "TF"
                            case .signatureLine: return "SIG"
                            case .unknown: return "?"
                            }
                        }()
                        Text(typeLabel)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundColor(color)
                            .position(x: rect.midX, y: rect.minY - 4)
                    }

                    // Draw field overlays
                    ForEach(fields) { field in
                        let labelRect = Self.visionToSwiftUI(
                            visionBox: field.labelBoundingBox,
                            fittedRect: fittedRect
                        )

                        // Label box outline
                        if showLabelBoxes && !isAddingField {
                            Rectangle()
                                .stroke(Color.indigo, lineWidth: 1.5)
                                .frame(width: labelRect.width, height: labelRect.height)
                                .position(x: labelRect.midX, y: labelRect.midY)
                        }

                        // Value badge
                        if !field.value.isEmpty && field.fieldType != .checkbox && !isAddingField {
                            // Get value position - either from adjustedValueBox or calculate default
                            let valueRect = field.adjustedValueBox.map {
                                Self.visionToSwiftUI(visionBox: $0, fittedRect: fittedRect)
                            } ?? calculateDefaultValueRect(for: field, labelRect: labelRect, fittedRect: fittedRect)

                            SimpleDraggableBadge(
                                text: field.value,
                                rect: valueRect,
                                editMode: isEditingPositions,
                                fittedRect: fittedRect,
                                zoomScale: zoomScale,
                                onDragEnd: { newNormalizedBox in
                                    onFieldValueDrag?(field.id, newNormalizedBox)
                                }
                            )
                        }
                    }

                    // Draw checkbox marks
                    if !isAddingField {
                        ForEach(checkboxGroups) { group in
                            if let selectedIdx = group.selectedIndex, selectedIdx < group.options.count {
                                let option = group.options[selectedIdx]
                                let rect = Self.visionToSwiftUI(
                                    visionBox: option.boundingBox,
                                    fittedRect: fittedRect
                                )
                                Text("X")
                                    .font(.system(size: max(10, min(16, rect.height * 0.8)), weight: .bold))
                                    .foregroundColor(.black)
                                    .position(x: rect.midX, y: rect.midY)
                            }
                        }
                    }

                    // Draw signature (scaled proportionally to fitted image)
                    if let sigImage = signatureImage, !isAddingField {
                        let scaledSigSize = CGSize(
                            width: signatureSize.width * (fittedRect.width / 400),
                            height: signatureSize.height * (fittedRect.height / 600)
                        )
                        let sigPos = calculateSignaturePosition(
                            normalizedPos: signatureNormalizedPos,
                            signatureField: signatureField,
                            signatureSize: scaledSigSize,
                            fittedRect: fittedRect
                        )

                        SimpleDraggableSignature(
                            image: sigImage,
                            position: sigPos,
                            size: scaledSigSize,
                            editMode: isEditingPositions,
                            fittedRect: fittedRect,
                            zoomScale: zoomScale,
                            onDragEnd: { newNormalizedPos in
                                onSignatureDrag?(newNormalizedPos)
                            }
                        )
                    }
                }
        }
    }

    private func calculateSignaturePosition(
        normalizedPos: CGPoint?,
        signatureField: KTCField?,
        signatureSize: CGSize,
        fittedRect: CGRect
    ) -> CGPoint {
        if let normalizedPos = normalizedPos {
            return CGPoint(
                x: fittedRect.origin.x + normalizedPos.x * fittedRect.width,
                y: fittedRect.origin.y + (1.0 - normalizedPos.y) * fittedRect.height
            )
        } else if let sigField = signatureField {
            // Place to the right of the label (same approach as text value badges)
            let sigRect = Self.visionToSwiftUI(
                visionBox: sigField.labelBoundingBox,
                fittedRect: fittedRect
            )
            return CGPoint(
                x: sigRect.maxX + signatureSize.width / 2 + 4,
                y: sigRect.midY
            )
        } else {
            return CGPoint(x: fittedRect.midX, y: fittedRect.maxY - signatureSize.height)
        }
    }

    private func calculateDefaultValueRect(for field: KTCField, labelRect: CGRect, fittedRect: CGRect) -> CGRect {
        let isShortLabel = field.label.count < 20 && !field.label.contains(":")
        let badgeWidth = estimateBadgeWidth(field.value, height: labelRect.height)
        let badgeHeight = labelRect.height * 0.8

        if isShortLabel {
            return CGRect(
                x: labelRect.minX,
                y: labelRect.maxY + 2,
                width: badgeWidth,
                height: badgeHeight
            )
        } else {
            return CGRect(
                x: min(labelRect.maxX + 4, fittedRect.maxX - badgeWidth - 4),
                y: labelRect.midY - badgeHeight / 2,
                width: badgeWidth,
                height: badgeHeight
            )
        }
    }

    private func estimateBadgeWidth(_ text: String, height: CGFloat) -> CGFloat {
        let fontSize = max(10, min(14, height * 0.7))
        return CGFloat(text.count) * fontSize * 0.6 + 16
    }

    // MARK: - Coordinate Conversion

    /// Compute the rect where an image is displayed within a container using aspectFit.
    /// Returns a valid rect even with zero/invalid inputs to prevent crashes.
    static func aspectFitRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        // Guard against invalid sizes
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            // Return a minimal valid rect to prevent division by zero downstream
            let safeWidth = max(1, containerSize.width)
            let safeHeight = max(1, containerSize.height)
            return CGRect(origin: .zero, size: CGSize(width: safeWidth, height: safeHeight))
        }

        let scaleX = containerSize.width / imageSize.width
        let scaleY = containerSize.height / imageSize.height
        let scale = min(scaleX, scaleY)

        let displayW = imageSize.width * scale
        let displayH = imageSize.height * scale
        let offsetX = (containerSize.width - displayW) / 2
        let offsetY = (containerSize.height - displayH) / 2

        return CGRect(x: offsetX, y: offsetY, width: displayW, height: displayH)
    }

    /// Convert a Vision boundingBox (normalized, origin bottom-left)
    /// to a SwiftUI rect (points, origin top-left) within the fitted image area.
    static func visionToSwiftUI(visionBox: CGRect, fittedRect: CGRect) -> CGRect {
        let x = fittedRect.origin.x + visionBox.origin.x * fittedRect.width
        let y = fittedRect.origin.y + (1.0 - visionBox.origin.y - visionBox.height) * fittedRect.height
        let w = visionBox.width * fittedRect.width
        let h = visionBox.height * fittedRect.height
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Rough estimate of badge width for positioning.
    private func badgeWidth(_ text: String, height: CGFloat) -> CGFloat {
        let fontSize = max(10, min(14, height * 0.7))
        return CGFloat(text.count) * fontSize * 0.6 + 8
    }
}

// MARK: - Simple Draggable Badge

/// A value badge that can be dragged. Returns normalized coordinates.
struct SimpleDraggableBadge: View {
    let text: String
    let rect: CGRect  // Screen coordinates (in overlay's unscaled coordinate space)
    let editMode: Bool
    let fittedRect: CGRect  // Image bounds for coordinate conversion
    var zoomScale: CGFloat = 1.0  // Current zoom scale to adjust drag translation
    let onDragEnd: (CGRect) -> Void  // Returns normalized Vision box

    @State private var currentRect: CGRect? = nil
    @State private var isDragging = false

    private var displayRect: CGRect {
        currentRect ?? rect
    }

    /// Safe zoom scale that prevents division by zero
    private var safeZoomScale: CGFloat {
        max(0.1, zoomScale)
    }

    var body: some View {
        Text(text)
            .font(.system(size: max(8, min(12, rect.height * 0.6))))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isDragging ? Color.orange : (editMode ? Color.orange.opacity(0.85) : Color.indigo.opacity(0.85)))
            .cornerRadius(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(editMode ? Color.orange : Color.clear, lineWidth: 2)
            )
            .position(x: displayRect.midX, y: displayRect.midY)
            .gesture(
                DragGesture(minimumDistance: editMode ? 0 : .infinity)
                    .onChanged { value in
                        guard editMode else { return }
                        isDragging = true
                        let adjustedWidth = value.translation.width / safeZoomScale
                        let adjustedHeight = value.translation.height / safeZoomScale
                        currentRect = CGRect(
                            x: rect.origin.x + adjustedWidth,
                            y: rect.origin.y + adjustedHeight,
                            width: rect.width,
                            height: rect.height
                        )
                    }
                    .onEnded { value in
                        guard editMode else { return }
                        isDragging = false
                        let adjustedWidth = value.translation.width / safeZoomScale
                        let adjustedHeight = value.translation.height / safeZoomScale
                        let finalRect = CGRect(
                            x: rect.origin.x + adjustedWidth,
                            y: rect.origin.y + adjustedHeight,
                            width: rect.width,
                            height: rect.height
                        )
                        currentRect = nil
                        let normalizedBox = screenToVision(screenRect: finalRect, fittedRect: fittedRect)
                        onDragEnd(normalizedBox)
                    }
            )
    }

    /// Convert screen rect to Vision normalized coordinates (0-1, origin bottom-left).
    /// Clamps output to valid range.
    private func screenToVision(screenRect: CGRect, fittedRect: CGRect) -> CGRect {
        // Guard against zero-size fittedRect
        guard fittedRect.width > 0, fittedRect.height > 0 else {
            return CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        }

        let x = (screenRect.origin.x - fittedRect.origin.x) / fittedRect.width
        // Vision Y: origin at bottom, so we flip. screenRect.origin.y is TOP of rect.
        // Vision's origin.y should be the BOTTOM of the rect in normalized space.
        let y = 1.0 - (screenRect.origin.y - fittedRect.origin.y + screenRect.height) / fittedRect.height
        let w = screenRect.width / fittedRect.width
        let h = screenRect.height / fittedRect.height

        // Clamp to valid normalized range [0, 1]
        let clampedW = max(0.01, min(1.0, w))
        let clampedH = max(0.01, min(1.0, h))
        let clampedX = max(0, min(1.0 - clampedW, x))
        let clampedY = max(0, min(1.0 - clampedH, y))

        return CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }
}

/// A signature that can be dragged. Returns normalized coordinates.
struct SimpleDraggableSignature: View {
    let image: UIImage
    let position: CGPoint  // Screen coordinates (center) in overlay's unscaled space
    let size: CGSize
    let editMode: Bool
    let fittedRect: CGRect
    var zoomScale: CGFloat = 1.0  // Current zoom scale to adjust drag translation
    let onDragEnd: (CGPoint) -> Void  // Returns normalized position

    @State private var currentPosition: CGPoint? = nil
    @State private var isDragging = false

    private var displayPosition: CGPoint {
        currentPosition ?? position
    }

    /// Safe zoom scale that prevents division by zero
    private var safeZoomScale: CGFloat {
        max(0.1, zoomScale)
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .overlay(
                Rectangle()
                    .stroke(
                        editMode ? Color.orange : Color.black.opacity(0.5),
                        style: StrokeStyle(lineWidth: editMode ? 2 : 1, dash: editMode ? [] : [3])
                    )
            )
            .position(displayPosition)
            .gesture(
                DragGesture(minimumDistance: editMode ? 0 : .infinity)
                    .onChanged { value in
                        guard editMode else { return }
                        isDragging = true
                        let adjustedWidth = value.translation.width / safeZoomScale
                        let adjustedHeight = value.translation.height / safeZoomScale
                        currentPosition = CGPoint(
                            x: position.x + adjustedWidth,
                            y: position.y + adjustedHeight
                        )
                    }
                    .onEnded { value in
                        guard editMode else { return }
                        isDragging = false
                        let adjustedWidth = value.translation.width / safeZoomScale
                        let adjustedHeight = value.translation.height / safeZoomScale
                        let finalPos = CGPoint(
                            x: position.x + adjustedWidth,
                            y: position.y + adjustedHeight
                        )
                        currentPosition = nil
                        let normalizedPos = screenToNormalized(screenPos: finalPos, fittedRect: fittedRect)
                        onDragEnd(normalizedPos)
                    }
            )
    }

    /// Convert screen position to normalized Vision coordinates (0-1, origin bottom-left).
    /// Clamps output to valid range.
    private func screenToNormalized(screenPos: CGPoint, fittedRect: CGRect) -> CGPoint {
        // Guard against zero-size fittedRect
        guard fittedRect.width > 0, fittedRect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let x = (screenPos.x - fittedRect.origin.x) / fittedRect.width
        let y = 1.0 - (screenPos.y - fittedRect.origin.y) / fittedRect.height

        // Clamp to valid normalized range [0, 1]
        return CGPoint(
            x: max(0, min(1.0, x)),
            y: max(0, min(1.0, y))
        )
    }
}

// MARK: - Expanded Image Sheet

/// Full-screen view for inspecting the overlay in detail with zoom support and manual field addition.
struct KTCExpandedImageView: View {
    let image: UIImage
    let fields: [KTCField]
    var checkboxGroups: [KTCCheckboxGroup] = []
    @Binding var showLabelBoxes: Bool
    @ObservedObject var vm: KTCDemo  // Need VM for manual field addition
    var showDebugOverlay: Bool = false
    @Environment(\.dismiss) private var dismiss

    // Zoom state
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    // Manual field addition state
    @State private var isAddingField = false
    @State private var isEditingPositions = false

    private let minScale: CGFloat = 1.0
    private let maxScale: CGFloat = 5.0

    /// Get OCR lines that aren't already used as fields
    private var availableLines: [KTCRecognizedLine] {
        let existingBoxes = Set(vm.fields.map { $0.labelBoundingBox })
        return vm.recognizedLines.filter { line in
            // Filter out lines that are already fields
            !existingBoxes.contains(line.boundingBox) &&
            // Filter out very short text
            line.text.trimmingCharacters(in: .whitespaces).count >= 2 &&
            // Filter out very long text (likely paragraphs)
            line.text.count <= 60
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Instructions when adding field
                if isAddingField {
                    HStack {
                        Image(systemName: "hand.tap")
                            .foregroundColor(.orange)
                        Text("Tap on any highlighted text to add it as a field")
                            .font(.subheadline)
                        Spacer()
                        Button("Done") {
                            isAddingField = false
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                // Instructions when editing positions
                if isEditingPositions {
                    HStack {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .foregroundColor(.orange)
                        Text("Drag value badges to reposition them")
                            .font(.subheadline)
                        Spacer()
                        Button("Done") {
                            isEditingPositions = false
                        }
                        .font(.subheadline)
                        .foregroundColor(.blue)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                GeometryReader { geometry in
                    ZoomableOverlayView(
                        image: image,
                        fields: vm.fields,
                        checkboxGroups: checkboxGroups,
                        showLabelBoxes: showLabelBoxes,
                        scale: $scale,
                        lastScale: $lastScale,
                        offset: $offset,
                        lastOffset: $lastOffset,
                        minScale: minScale,
                        maxScale: maxScale,
                        containerSize: geometry.size,
                        isAddingField: isAddingField,
                        onFieldValueDrag: { fieldId, normalizedBox in
                            vm.updateFieldValueBox(id: fieldId, normalizedBox: normalizedBox)
                        },
                        signatureImage: vm.hasSignature ? vm.signatureImage : nil,
                        signatureField: vm.signatureField,
                        signatureSize: vm.signatureSize,
                        signatureNormalizedPos: vm.signatureNormalizedPosition,
                        onSignatureDrag: { normalizedPos in
                            vm.updateSignatureNormalizedPosition(normalizedPos)
                        },
                        availableLines: isAddingField ? availableLines : [],
                        onLineSelected: { line in
                            addFieldFromLine(line)
                        },
                        isEditingPositions: isEditingPositions,
                        debugRects: showDebugOverlay ? vm.debugRects : [],
                        debugOCRLines: showDebugOverlay ? vm.recognizedLines : []
                    )
                }
                .clipped()

                // Bottom toolbar - compact layout
                HStack(spacing: 8) {
                    if !isAddingField && !isEditingPositions {
                        // Labels toggle - compact
                        HStack(spacing: 4) {
                            Toggle("", isOn: $showLabelBoxes)
                                .labelsHidden()
                                .scaleEffect(0.8)
                                .frame(width: 44)
                            Text("Labels")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        // Move button - icon only with small label
                        Button {
                            isEditingPositions = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                    .font(.system(size: 16))
                                Text("Move")
                                    .font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.blue)

                        // Add Field button - icon only with small label
                        Button {
                            isAddingField = true
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "plus.rectangle")
                                    .font(.system(size: 16))
                                Text("Add")
                                    .font(.system(size: 9))
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else if isAddingField {
                        Text("Tap a line to add")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Spacer()
                        Button("Cancel") {
                            isAddingField = false
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    } else if isEditingPositions {
                        Text("Drag to reposition")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Spacer()
                        Button("Done") {
                            isEditingPositions = false
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .tint(.blue)
                    }

                    // Zoom indicator - always show when zoomed
                    if scale > 1.0 {
                        Text("\(Int(scale * 100))%")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(.systemGray5))
                            .cornerRadius(4)

                        // Reset zoom button
                        if !isAddingField && !isEditingPositions {
                            Button {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Scan Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Add a field from a selected OCR line.
    private func addFieldFromLine(_ line: KTCRecognizedLine) {
        vm.addManualField(label: line.text, labelBox: line.boundingBox, inputBox: nil)
    }
}

/// Zoomable and pannable overlay view with gestures.
struct ZoomableOverlayView: View {
    let image: UIImage
    let fields: [KTCField]
    var checkboxGroups: [KTCCheckboxGroup] = []
    let showLabelBoxes: Bool

    @Binding var scale: CGFloat
    @Binding var lastScale: CGFloat
    @Binding var offset: CGSize
    @Binding var lastOffset: CGSize

    let minScale: CGFloat
    let maxScale: CGFloat
    let containerSize: CGSize

    var isAddingField: Bool = false
    var onFieldValueDrag: ((UUID, CGRect) -> Void)?
    var signatureImage: UIImage?
    var signatureField: KTCField?
    var signatureSize: CGSize = CGSize(width: 60, height: 24)
    var signatureNormalizedPos: CGPoint? = nil
    var onSignatureDrag: ((CGPoint) -> Void)?

    // For Add Field mode
    var availableLines: [KTCRecognizedLine] = []
    var onLineSelected: ((KTCRecognizedLine) -> Void)?

    // Edit positions mode
    var isEditingPositions: Bool = false

    // Debug mode
    var debugRects: [KTCRectangleDetector.DetectedRect] = []
    var debugOCRLines: [KTCRecognizedLine] = []

    var body: some View {
        KTCOverlayView(
            image: image,
            fields: fields,
            showLabelBoxes: showLabelBoxes,
            checkboxGroups: checkboxGroups,
            onFieldValueDrag: onFieldValueDrag,
            signatureImage: signatureImage,
            signatureField: signatureField,
            signatureSize: signatureSize,
            signatureNormalizedPos: signatureNormalizedPos,
            onSignatureDrag: onSignatureDrag,
            availableLines: availableLines,
            isAddingField: isAddingField,
            onLineSelected: onLineSelected,
            isEditingPositions: isEditingPositions,
            zoomScale: scale,
            debugRects: debugRects,
            debugOCRLines: debugOCRLines
        )
        .scaleEffect(scale)
        .offset(offset)
        .contentShape(Rectangle())  // Make entire area tappable
        .gesture(
            // Pinch to zoom (disabled when adding field)
            MagnificationGesture()
                .onChanged { value in
                    guard !isAddingField else { return }
                    let newScale = lastScale * value
                    scale = min(max(newScale, minScale), maxScale)
                }
                .onEnded { _ in
                    guard !isAddingField else { return }
                    lastScale = scale
                    if scale <= 1.0 {
                        withAnimation(.easeOut(duration: 0.2)) {
                            offset = .zero
                            lastOffset = .zero
                        }
                    } else {
                        clampOffset()
                    }
                }
        )
        .simultaneousGesture(
            // Drag to pan (only when zoomed in, not adding field, and not editing positions)
            DragGesture()
                .onChanged { value in
                    guard !isAddingField && !isEditingPositions && scale > 1.0 else { return }
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
                .onEnded { _ in
                    guard !isAddingField && !isEditingPositions else { return }
                    lastOffset = offset
                    clampOffset()
                }
        )
        .onTapGesture(count: 2) {
            guard !isAddingField else { return }
            // Double-tap to zoom in/out
            withAnimation(.easeInOut(duration: 0.25)) {
                if scale > 1.0 {
                    scale = 1.0
                    lastScale = 1.0
                    offset = .zero
                    lastOffset = .zero
                } else {
                    scale = 2.5
                    lastScale = 2.5
                }
            }
        }
    }

    private func clampOffset() {
        let maxOffsetX = (containerSize.width * (scale - 1)) / 2
        let maxOffsetY = (containerSize.height * (scale - 1)) / 2

        withAnimation(.easeOut(duration: 0.1)) {
            offset.width = min(max(offset.width, -maxOffsetX), maxOffsetX)
            offset.height = min(max(offset.height, -maxOffsetY), maxOffsetY)
            lastOffset = offset
        }
    }
}
