//
//  ContentView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI
import UniformTypeIdentifiers

private let fileLogger = FileLogger.shared


struct ContentView: View {
    @StateObject private var recordStore = HealthRecordStore()
    @State private var showingDocumentPicker = false
    @State private var showingImagePicker = false
    @State private var selectedTab = 0
    @State private var healthDataMessage = "Press the button to fetch HealthKit data."
        private let healthKitManager = HealthKitManager()
    
    var body: some View {
        TabView(selection: $selectedTab) {
            
            // Home Tab
            NavigationView {
                HomeView()
                    .environmentObject(recordStore)
            }
            .tabItem {
                Label("Home", systemImage: "house")
            }
            .tag(0)
            
            // Records Tab
            NavigationView {
                RecordsListView(recordStore: recordStore)
                    .navigationTitle("Health Records")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button(action: { showingDocumentPicker = true }) {
                                    Label("Upload Document", systemImage: "doc")
                                }
                                Button(action: { showingImagePicker = true }) {
                                    Label("Upload Image", systemImage: "photo")
                                }
                            } label: {
                                Image(systemName: "plus")
                            }
                        }
                    }
            }
            .tabItem {
                Label("Records", systemImage: "list.bullet")
            }
            .tag(1)
            
            // Clinical Trial Matcher Tab
            NavigationView {
                ClinicalTrialView(recordStore: recordStore)
            }
            .tabItem {
                Label("Trial Matcher", systemImage: "stethoscope")
            }
            .tag(2)
            
            // Settings Tab
            NavigationView {
                SettingsView()
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(3)
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker(recordStore: recordStore)
        }
        .sheet(isPresented: $showingImagePicker) {
            ImagePicker(recordStore: recordStore)
        }
        .onAppear {
            recordStore.loadHealthKitRecords()
        }
    }
    
    private func fetchHealthData() {
            healthKitManager.requestAuthorization { success, error in
                if success {
                    if let result = healthKitManager.fetchNameAndBirthday() {
                        DispatchQueue.main.async {
                            if let birthday = result.birthday {
                                healthDataMessage = """
                                User's Name: \(result.name ?? "Unknown")
                                User's Birthday: \(birthday)
                                """
                                fileLogger.info(healthDataMessage, category: "UI-HealthKit")
                            } else {
                                healthDataMessage = "Could not retrieve birthday."
                                fileLogger.warning(healthDataMessage, category: "UI-HealthKit")
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        healthDataMessage = "HealthKit authorization failed: \(error?.localizedDescription ?? "Unknown error")"
                        fileLogger.error(healthDataMessage, category: "UI-HealthKit")
                    }
                }
            }
        }
}



