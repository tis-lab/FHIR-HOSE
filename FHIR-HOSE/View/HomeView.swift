//
//  HomeView.swift
//  FHIR-HOSE
//
//  Created by Claude Code on 6/7/25.
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var recordStore: HealthRecordStore
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 20) {
                
                NavigationLink(destination: ClinicalTrialView(recordStore: recordStore)) {
                    HealthAppCard(
                        title: "Clinical Trial Matcher",
                        subtitle: "Find relevant clinical trials",
                        systemImage: "stethoscope",
                        color: .blue
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                NavigationLink(destination: ChatWithRecordsView(recordStore: recordStore)) {
                    HealthAppCard(
                        title: "Chat with My Records",
                        subtitle: "AI-powered health insights",
                        systemImage: "message.circle",
                        color: .green
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                NavigationLink(destination: OutliveChecklistView(records: recordStore.records)) {
                    HealthAppCard(
                        title: "Outlive Checklist",
                        subtitle: "Longevity assessment",
                        systemImage: "heart.text.square",
                        color: .purple
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                NavigationLink(destination: UndiagnosedDiseasesView(records: recordStore.records)) {
                    HealthAppCard(
                        title: "Undiagnosed Diseases Network",
                        subtitle: "UDN application assistant",
                        systemImage: "cross.case",
                        color: .indigo
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                NavigationLink(destination: CBTAlcoholCoachView(records: recordStore.records)) {
                    HealthAppCard(
                        title: "CBT Recovery Coach",
                        subtitle: "Alcohol recovery support",
                        systemImage: "brain.head.profile",
                        color: .mint
                    )
                }
                .buttonStyle(PlainButtonStyle())
                
                NavigationLink(destination: COPDView(records: recordStore.records)) {
                    HealthAppCard(
                        title: "COPD Prediction",
                        subtitle: "Generate prediction data",
                        systemImage: "lungs.fill",
                        color: .blue
                    )
                }
                .buttonStyle(PlainButtonStyle())

                NavigationLink(destination: KTCDemoView()) {
                    HealthAppCard(
                        title: "Form Autofill",
                        subtitle: "Scan & auto-fill medical forms",
                        systemImage: "doc.text.viewfinder",
                        color: .indigo
                    )
                }
                .buttonStyle(PlainButtonStyle())

                NavigationLink(destination: DeIDTestView(recordStore: recordStore)) {
                    HealthAppCard(
                        title: "FHIR De-ID Test",
                        subtitle: "De-identify FHIR-JSON on device",
                        systemImage: "lock.shield",
                        color: .orange
                    )
                }
                .buttonStyle(PlainButtonStyle())

                if #available(iOS 26, macOS 26, visionOS 26, *) {
                    NavigationLink(destination: OnDeviceChatView(recordStore: recordStore)) {
                        HealthAppCard(
                            title: "On-Device AI Chat",
                            subtitle: "Apple Intelligence with your records",
                            systemImage: "apple.intelligence",
                            color: .purple
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding()
        }
        .navigationTitle("Health Apps")
    }
}

struct HealthAppCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(color)
            
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
}
