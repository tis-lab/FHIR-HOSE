//
//  KTCDemoView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 1/27/26.
//

import SwiftUI
import UIKit
import VisionKit
import OSLog

// MARK: - Haptic Feedback Helper

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

struct KTCDemoView: View {
    @StateObject private var vm = KTCDemo()
    @State private var showScanner = false
    @State private var showPhotoPicker = false
    @State private var showImageExpanded = false
    @State private var showLabelBoxes = true
    @State private var showCopiedToast = false
    @State private var showShareSheet = false
    @State private var exportPDFURL: URL?
    @State private var showSignatureCanvas = false
    @State private var showPDFPreview = false
    @State private var previewPDFURL: URL?
    @State private var showStartOverConfirmation = false
    private let logger = Logger(subsystem: "com.fhirhose.app", category: "KTCDemoView")

    // Completion tracking
    private var completionProgress: Double {
        let eligibleFields = vm.fields.filter { $0.fieldType != .signature && $0.fieldType != .checkbox && !$0.isSkipped }
        let totalFields = eligibleFields.count + (vm.signatureField != nil ? 1 : 0)
        guard totalFields > 0 else { return 0 }
        let filledFields = eligibleFields.filter { !$0.value.isEmpty }.count
        let signatureFilled = vm.hasSignature ? 1 : 0
        return Double(filledFields + signatureFilled) / Double(totalFields)
    }

    private var isComplete: Bool {
        completionProgress >= 1.0
    }

    var body: some View {
        Group {
            switch vm.phase {
            case .landing:
                landingView
            case .scanning:
                scanningView
            case .analyzing:
                analyzingView
            case .editing:
                editingView
            case .error(let message):
                errorView(message)
            }
        }
        .navigationTitle("Form Autofill")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showScanner) {
            KTCDocumentScanner(
                onScan: { images in
                    vm.handleScannedPages(images)
                },
                onCancel: {
                    vm.cancelScan()
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPhotoPicker) {
            KTCPhotoPicker(
                onPick: { image in
                    vm.handlePickedPhoto(image)
                },
                onCancel: {
                    vm.cancelScan()
                }
            )
        }
        .sheet(isPresented: $showImageExpanded) {
            if let firstPage = vm.pages.first {
                KTCExpandedImageView(
                    image: firstPage,
                    fields: vm.fields,
                    checkboxGroups: vm.checkboxGroups,
                    showLabelBoxes: $showLabelBoxes,
                    vm: vm
                )
            }
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = exportPDFURL {
                ShareSheetView(url: url)
            }
        }
        .sheet(isPresented: $showPDFPreview) {
            if let url = previewPDFURL {
                PDFPreviewSheet(
                    url: url,
                    onShare: {
                        exportPDFURL = url
                        showPDFPreview = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showShareSheet = true
                        }
                    },
                    onDismiss: {
                        showPDFPreview = false
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showSignatureCanvas) {
            KTCSignatureCanvas(
                signatureImage: $vm.signatureImage,
                onSave: { image in
                    vm.updateSignature(image)
                    Haptics.success()
                    showSignatureCanvas = false
                },
                onCancel: {
                    showSignatureCanvas = false
                }
            )
        }
    }

    // MARK: - Landing

    private var landingView: some View {
        VStack(spacing: 30) {
            VStack(spacing: 15) {
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 60))
                    .foregroundColor(.indigo)

                Text("Form Autofill (KTC Demo)")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("Scan a paper medical form, auto-fill it with patient data, and export the result.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 8) {
                FeatureRow(icon: "camera.viewfinder", text: "Scan a form, paper or on-screen")
                FeatureRow(icon: "text.viewfinder", text: "Vision technology detects form fields")
                FeatureRow(icon: "person.text.rectangle", text: "Patient data auto-fills matching fields")
                FeatureRow(icon: "pencil.and.list.clipboard", text: "Review, edit, and export the result")
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)

            VStack(spacing: 6) {
                Text("Detection Method")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("Detection Method", selection: $vm.backend) {
                    ForEach(FormAutofillBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal)

            VStack(spacing: 12) {
                if VNDocumentCameraViewController.isSupported {
                    Button {
                        logger.info("User tapped Scan Document")
                        vm.phase = .scanning
                        showScanner = true
                    } label: {
                        Label("Scan Document", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.large)
                }

                Button {
                    logger.info("User tapped Pick Photo")
                    vm.phase = .scanning
                    showPhotoPicker = true
                } label: {
                    Label("Pick from Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.indigo)
                .controlSize(.large)
            }
        }
        .padding()
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Waiting for scan...")
                .font(.headline)
                .foregroundColor(.secondary)

            Button("Cancel") {
                vm.cancelScan()
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Analyzing

    private var analyzingView: some View {
        VStack(spacing: 20) {
            if let firstPage = vm.pages.first {
                Image(uiImage: firstPage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
                    .cornerRadius(12)
                    .shadow(radius: 4)
            }

            ProgressView("Detecting fields...")
                .font(.headline)

            Text("Running OCR and matching patient data")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    // MARK: - Editing (full interactive UI)

    private var editingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Tappable image with overlay
                if let firstPage = vm.pages.first {
                    KTCOverlayView(
                        image: firstPage,
                        fields: vm.fields,
                        showLabelBoxes: showLabelBoxes,
                        checkboxGroups: vm.checkboxGroups,
                        signatureImage: vm.hasSignature ? vm.signatureImage : nil,
                        signatureField: vm.signatureField,
                        signatureSize: vm.signatureSize,
                        signatureNormalizedPos: vm.signatureNormalizedPosition
                    )
                    .frame(height: 220)
                    .cornerRadius(8)
                    .shadow(radius: 2)
                    .onTapGesture {
                        showImageExpanded = true
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .cornerRadius(6)
                            .padding(8)
                    }
                }

                Divider()

                // Checkbox Groups Section
                if !vm.checkboxGroups.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "checkmark.square")
                                .foregroundColor(.indigo)
                            Text("Checkbox Groups")
                                .font(.headline)
                            Spacer()
                            let autoChecked = vm.checkboxGroups.filter { $0.selectedIndex != nil }.count
                            Text("\(autoChecked)/\(vm.checkboxGroups.count) auto-filled")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        ForEach(vm.checkboxGroups.indices, id: \.self) { groupIdx in
                            let group = vm.checkboxGroups[groupIdx]
                            // Only show groups with 2+ options (actual choice groups)
                            if group.options.count > 1 {
                                VStack(alignment: .leading, spacing: 6) {
                                    // Group label
                                    HStack {
                                        if let label = group.groupLabel {
                                            Text(label)
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                        } else {
                                            Text("Choice")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        if let keypath = group.mappedKeypath {
                                            Text("→ \(vm.displayName(for: keypath))")
                                                .font(.caption)
                                                .foregroundColor(.indigo)
                                        }
                                        Spacer()
                                        if group.selectedIndex != nil {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                                .font(.caption)
                                        }
                                    }

                                    // Checkbox options - use FlowLayout for wrapping
                                    FlowLayout(spacing: 12) {
                                        ForEach(group.options.indices, id: \.self) { optIdx in
                                            let option = group.options[optIdx]
                                            Button {
                                                Haptics.selection()
                                                vm.toggleCheckbox(groupIndex: groupIdx, optionIndex: optIdx)
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: option.isChecked ? "checkmark.square.fill" : "square")
                                                        .foregroundColor(option.isChecked ? .indigo : .gray)
                                                    Text(option.associatedText ?? "Option \(optIdx + 1)")
                                                        .font(.subheadline)
                                                        .foregroundColor(option.isChecked ? .primary : .secondary)
                                                        .lineLimit(1)
                                                }
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color(.systemGray6))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    Divider()
                }

                // Field list
                if vm.fields.isEmpty && vm.checkboxGroups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No field labels detected.")
                            .font(.headline)
                        Text("Try scanning a form with clear labels like \"Name:\", \"DOB:\", etc.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 30)
                } else if !vm.fields.isEmpty {
                    // "Auto-filled" section — mapped fields with values OR skipped (N/A) fields, excluding signature/checkbox types
                    let autoFilledCount = vm.fields.filter {
                        $0.fieldType != .signature && $0.fieldType != .checkbox &&
                        ($0.isSkipped || ($0.mappedKeypath != nil && !$0.value.isEmpty))
                    }.count
                    if autoFilledCount > 0 {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Auto-filled")
                                .font(.headline)
                            Spacer()
                            Text("\(autoFilledCount) fields")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 4)

                        ForEach($vm.fields) { $field in
                            if field.fieldType != .signature && field.fieldType != .checkbox &&
                               (field.isSkipped || (field.mappedKeypath != nil && !field.value.isEmpty)) {
                                KTCFieldCard(field: $field, vm: vm)
                            }
                        }
                    }

                    // Inline Signature Section
                    signatureInlineView

                    // "Needs Review" section — unmapped or empty fields (not skipped), excluding signature/checkbox types
                    let needsReviewCount = vm.fields.filter {
                        $0.fieldType != .signature && $0.fieldType != .checkbox &&
                        !$0.isSkipped && ($0.mappedKeypath == nil || $0.value.isEmpty)
                    }.count
                    if needsReviewCount > 0 {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.orange)
                            Text("Needs Review")
                                .font(.headline)
                            Spacer()
                            Text("\(needsReviewCount) fields")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 8)

                        ForEach($vm.fields) { $field in
                            if field.fieldType != .signature && field.fieldType != .checkbox &&
                               !field.isSkipped && (field.mappedKeypath == nil || field.value.isEmpty) {
                                KTCFieldCard(field: $field, vm: vm)
                            }
                        }
                    }
                }

                Divider()

                // Completion indicator
                VStack(spacing: 8) {
                    HStack {
                        Text("Form Completion")
                            .font(.headline)
                        Spacer()
                        Text("\(Int(completionProgress * 100))%")
                            .font(.headline)
                            .foregroundColor(isComplete ? .green : .indigo)
                    }

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(.systemGray5))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isComplete ? Color.green : Color.indigo)
                                .frame(width: geo.size.width * completionProgress)
                                .animation(.easeInOut(duration: 0.3), value: completionProgress)
                        }
                    }
                    .frame(height: 8)

                    if isComplete {
                        HStack {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundColor(.green)
                            Text("All fields complete!")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.vertical, 8)

                // Export action
                Button {
                    if let url = vm.generateFilledPDF() {
                        Haptics.success()
                        shareFile(url: url)
                    }
                } label: {
                    Label("Export Filled PDF", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)
                .controlSize(.large)

                Divider()

                Button("Start Over") {
                    Haptics.warning()
                    showStartOverConfirmation = true
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .alert("Start Over?", isPresented: $showStartOverConfirmation) {
                    Button("Cancel", role: .cancel) { }
                    Button("Clear Everything", role: .destructive) {
                        vm.phase = .landing
                        vm.pages = []
                        vm.recognizedLines = []
                        vm.fields = []
                        vm.checkboxGroups = []
                        vm.clearSignature()
                    }
                } message: {
                    Text("This will discard all scanned data, field mappings, and your signature.")
                }
            }
            .padding()
        }
        .overlay {
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("Copied to clipboard!")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.indigo)
                        .cornerRadius(20)
                        .shadow(radius: 4)
                        .padding(.bottom, 30)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut, value: showCopiedToast)
            }
        }
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.orange)

            Text("Something went wrong")
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Back to Start") {
                vm.phase = .landing
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Signature Inline View

    private var signatureInlineView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack {
                Image(systemName: "signature")
                    .foregroundColor(.indigo)
                Text("Signature")
                    .font(.headline)
                Spacer()
                if vm.hasSignature {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            if vm.hasSignature {
                if let sigImage = vm.signatureImage {
                    Image(uiImage: sigImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 60)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(white: 0.9))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                }

                let signatureFields = vm.fields.filter { $0.fieldType == .signature || $0.label.lowercased().contains("sign") }
                if !signatureFields.isEmpty {
                    HStack {
                        Text("Place at:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Picker("", selection: Binding<String>(
                            get: { vm.signatureFieldId?.uuidString ?? "" },
                            set: { newVal in
                                if newVal.isEmpty {
                                    vm.setSignatureField(id: nil)
                                } else if let uuid = UUID(uuidString: newVal) {
                                    vm.setSignatureField(id: uuid)
                                }
                            }
                        )) {
                            Text("Auto").tag("")
                            ForEach(signatureFields) { field in
                                Text(field.label).tag(field.id.uuidString)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.indigo)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Size:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(vm.signatureSize.width)) × \(Int(vm.signatureSize.height))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { vm.signatureSize.width },
                            set: { newWidth in
                                vm.signatureSize = CGSize(width: newWidth, height: newWidth / 2.5)
                            }
                        ),
                        in: 20...120,
                        step: 5
                    )
                    .tint(.indigo)
                }

                HStack(spacing: 12) {
                    Button {
                        showSignatureCanvas = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .tint(.indigo)

                    Button {
                        vm.clearSignature()
                    } label: {
                        Label("Clear", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            } else {
                Button {
                    showSignatureCanvas = true
                } label: {
                    HStack {
                        Image(systemName: "pencil.tip.crop.circle")
                        Text("Add Signature")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(Color(.systemGray5))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(style: StrokeStyle(lineWidth: 2, dash: [5]))
                            .foregroundColor(.gray.opacity(0.5))
                    )
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Divider()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Share Helper

    private func shareFile(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            var topVC = rootVC
            while let presented = topVC.presentedViewController {
                topVC = presented
            }
            topVC.present(activityVC, animated: true)
        }
    }
}

// MARK: - Field Card (Cleaner UI)

struct KTCFieldCard: View {
    @Binding var field: KTCField
    @ObservedObject var vm: KTCDemo

    @State private var isExpanded = false

    private var isMapped: Bool { field.mappedKeypath != nil }
    private var hasValue: Bool { !field.value.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - always visible
            HStack(spacing: 10) {
                // Status indicator
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                // Label
                Text(field.label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .strikethrough(field.isSkipped, color: .secondary)

                Spacer()

                // Value preview, N/A badge, or status
                if field.isSkipped {
                    Text("N/A")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray4).opacity(0.5))
                        .cornerRadius(4)
                } else if hasValue {
                    Text(field.value)
                        .font(.subheadline)
                        .foregroundColor(.indigo)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(minWidth: 60, alignment: .trailing)
                } else {
                    Text(isMapped ? "Empty" : "Not mapped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Expand/collapse chevron
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            }

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    Divider()

                    // Mapping selector
                    HStack {
                        Text("Map to:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)

                        Picker("", selection: Binding<String>(
                            get: { field.mappedKeypath ?? "" },
                            set: { newVal in
                                let kp = newVal.isEmpty ? nil : newVal
                                vm.updateFieldKeypath(id: field.id, newKeypath: kp)
                            }
                        )) {
                            Text("— None —").tag("")
                            ForEach(vm.sortedKeypaths, id: \.self) { kp in
                                Text(vm.displayName(for: kp)).tag(kp)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.indigo)
                        .labelsHidden()
                    }

                    // Value editor
                    HStack {
                        Text("Value:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .leading)

                        TextField("Enter value", text: $field.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.subheadline)

                        if isMapped {
                            Button {
                                vm.resetField(id: field.id)
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .tint(.indigo)
                        }
                    }

                    // Show detected value if different from current
                    if let detected = field.detectedValue, !detected.isEmpty, detected != field.value {
                        HStack {
                            Text("Found:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .leading)

                            Text(detected)
                                .font(.caption)
                                .foregroundColor(.orange)

                            Spacer()

                            Button("Use") {
                                field.value = detected
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .tint(.orange)
                        }
                    }

                    // N/A toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if field.isSkipped {
                                // Undo: restore stashed value
                                field.isSkipped = false
                                if let stashed = field.skippedValue {
                                    field.value = stashed
                                    field.skippedValue = nil
                                }
                            } else {
                                // Mark N/A: stash current value and clear it
                                field.skippedValue = field.value
                                field.value = ""
                                field.isSkipped = true
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: field.isSkipped ? "arrow.uturn.backward" : "minus.circle")
                                .font(.caption)
                            Text(field.isSkipped ? "Undo N/A" : "Mark as N/A")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(field.isSkipped ? .indigo : .orange)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(isMapped || field.isSkipped ? Color.indigo.opacity(0.05) : Color(.systemGray6))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isMapped || field.isSkipped ? Color.indigo.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .opacity(field.isSkipped ? 0.7 : 1.0)
    }

    private var statusColor: Color {
        if field.isSkipped { return .green }
        if isMapped && hasValue { return .green }
        if isMapped { return .orange }
        return .gray
    }
}

// MARK: - Feature Row

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundColor(.indigo)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Flow Layout (wrapping HStack)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}

// MARK: - Stat Badge

struct StatBadge: View {
    let icon: String
    let value: String
    let label: String
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
            Text(value)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - PDF Preview Sheet

struct PDFPreviewSheet: View {
    let url: URL
    let onShare: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            PDFKitView(url: url)
                .navigationTitle("Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            onDismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Haptics.success()
                            onShare()
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                }
        }
    }
}

// MARK: - Share Sheet View

struct ShareSheetView: UIViewControllerRepresentable {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        // Create a wrapper view controller
        let controller = UIViewController()
        controller.view.backgroundColor = .clear

        // Present the activity view controller after a brief delay
        DispatchQueue.main.async {
            let activityVC = UIActivityViewController(
                activityItems: [url],
                applicationActivities: nil
            )

            // Handle completion
            activityVC.completionWithItemsHandler = { _, _, _, _ in
                dismiss()
            }

            // For iPad - set source view
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            controller.present(activityVC, animated: true)
        }

        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFDisplayView {
        let view = PDFDisplayView()
        view.loadPDF(from: url)
        return view
    }

    func updateUIView(_ uiView: PDFDisplayView, context: Context) {
        uiView.loadPDF(from: url)
    }
}

class PDFDisplayView: UIView {
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])
    }

    func loadPDF(from url: URL) {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1) else { return }

        let pageRect = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 2.0  // Render at 2x for clarity
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        UIGraphicsBeginImageContextWithOptions(size, true, 0)
        guard let context = UIGraphicsGetCurrentContext() else { return }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))

        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.drawPDFPage(page)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        imageView.image = image
    }
}

extension PDFDisplayView: UIScrollViewDelegate {
    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        return imageView
    }
}

// MARK: - Signature Canvas

struct KTCSignatureCanvas: View {
    @Binding var signatureImage: UIImage?
    let onSave: (UIImage?) -> Void
    let onCancel: () -> Void

    @State private var localSignature: UIImage? = nil

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                let isLandscape = geometry.size.width > geometry.size.height
                let canvasHeight: CGFloat = isLandscape ? geometry.size.height - 120 : 200

                VStack(spacing: 0) {
                    // Instructions - compact in landscape
                    if !isLandscape {
                        Text("Sign below using your finger")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        Text("Sign here")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }

                    // Canvas - expands in landscape
                    // Light background so black signature strokes are visible
                    SignatureCanvasRepresentable(signatureImage: $localSignature)
                        .frame(height: canvasHeight)
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.indigo.opacity(0.5), lineWidth: 2)
                        )
                        .padding(.horizontal)

                    // Clear button
                    Button {
                        localSignature = nil
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .padding(.vertical, isLandscape ? 8 : 16)

                    if !isLandscape {
                        Spacer()
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Add Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(localSignature)
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            localSignature = signatureImage
        }
    }
}

// MARK: - UIKit PKCanvasView Wrapper

/// Simple drawing view for signatures using Core Graphics (works reliably with finger)
class SignatureDrawingView: UIView {
    private var path = UIBezierPath()
    private var points: [CGPoint] = []
    var onDrawingChanged: ((UIImage?) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .white  // Light background for visibility while signing
        isOpaque = true
        isMultipleTouchEnabled = false
        path.lineWidth = 3.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
    }

    override func draw(_ rect: CGRect) {
        UIColor.black.setStroke()
        path.stroke()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        path.move(to: point)
        points.append(point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        path.addLine(to: point)
        points.append(point)
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        onDrawingChanged?(getImage())
    }

    func clear() {
        path.removeAllPoints()
        points.removeAll()
        setNeedsDisplay()
        onDrawingChanged?(nil)
    }

    func getImage() -> UIImage? {
        guard !points.isEmpty else { return nil }
        // Render with transparent background (false = not opaque)
        UIGraphicsBeginImageContextWithOptions(bounds.size, false, UIScreen.main.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        // Clear the context to transparent
        context.clear(bounds)
        // Draw the signature path
        UIColor.black.setStroke()
        path.stroke()
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return image
    }

    var hasSignature: Bool {
        !points.isEmpty
    }
}

struct SignatureCanvasRepresentable: UIViewRepresentable {
    @Binding var signatureImage: UIImage?
    var onClear: (() -> Void)?

    func makeUIView(context: Context) -> SignatureDrawingView {
        let view = SignatureDrawingView(frame: .zero)
        view.onDrawingChanged = { image in
            DispatchQueue.main.async {
                self.signatureImage = image
            }
        }
        return view
    }

    func updateUIView(_ uiView: SignatureDrawingView, context: Context) {
        // If signatureImage is nil, clear the view
        if signatureImage == nil && uiView.hasSignature {
            uiView.clear()
        }
    }
}

#Preview {
    NavigationView {
        KTCDemoView()
    }
}
