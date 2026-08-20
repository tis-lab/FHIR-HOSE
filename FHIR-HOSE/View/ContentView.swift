//
//  ContentView.swift
//  FHIR-HOSE
//
//  Created by Eric Hurwitz on 12/3/24.
//

import SwiftUI


struct ContentView: View {
    @StateObject private var recordStore = HealthRecordStore()
    @State private var showingDocumentPicker = false
    @State private var showingImagePicker = false
    @State private var selectedTab = 0
    
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
            
            // Settings Tab
            NavigationView {
                SettingsView()
                    .navigationTitle("Settings")
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
            .tag(2)
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
}
