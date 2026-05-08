//
//  DocumentPicker.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DocumentPicker: UIViewControllerRepresentable {
    @ObservedObject var recordStore: HealthRecordStore
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf])
        picker.delegate = context.coordinator
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            
            // Copy file to app's documents directory
            let filename = url.lastPathComponent
            if let destinationURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent(filename) {
                try? FileManager.default.copyItem(at: url, to: destinationURL)
                
                // Add record to store
                DispatchQueue.main.async {
                    let newRecord = HealthRecord(filename: filename, type: .pdf)
                    self.parent.recordStore.records.append(newRecord)

                    // Now actually process it:
                    self.parent.recordStore.processPDFRecord(newRecord)
                }
            }
        }
    }
}
