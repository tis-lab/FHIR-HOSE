import SwiftUI

struct COPDView: View {
    let records: [HealthRecord]
    @StateObject private var viewModel = COPDViewModel()
    @State private var showingJSONSheet = false
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header Section
                VStack(spacing: 12) {
                    Image(systemName: "lungs.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text("COPD Risk Assessment")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                    
                    Text("Complete your health profile for accurate COPD risk analysis")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top)
                
                // Direct to JSON Collection
                Button(action: {
                    generateCOPDData()
                    showingJSONSheet = true
                }) {
                    HStack {
                        Image(systemName: "doc.text.fill")
                        Text("Start Survey")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                
                // Status Section
                if viewModel.isProcessing {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Processing health records...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
                
                if let errorMessage = viewModel.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.title2)
                        Text("Error")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(12)
                    .padding(.horizontal)
                }
                
                Spacer(minLength: 50)
            }
            .padding()
        }
        .navigationTitle("COPD Prediction")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingJSONSheet) {
            COPDSurveySheet(jsonString: viewModel.generatedJSON, healthRecords: records)
        }
    }
    
    private func generateCOPDData() {
        viewModel.generateCOPDData(from: records)
    }
}

struct DataSummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(8)
    }
}

struct COPDSurveySheet: View {
    let jsonString: String
    let healthRecords: [HealthRecord]
    @Environment(\.dismiss) private var dismiss
    @StateObject private var healthKitManager = HealthKitManager()
    
    // Prediction state
    @State private var predictionResult: COPDPredictionResult?
    @State private var isLoadingPrediction = false
    @State private var predictionError: String?
    @State private var showingResults = false
    
    // State for user inputs - simplified to binary where possible
    @State private var ethnicity: Int = 2 // 0 = Not Hispanic/Latino, 1 = Hispanic/Latino, 2 = Prefer not to answer
    @State private var sexAtBirth: Int = 1 // 0 = Female, 1 = Male, 2 = Prefer not to answer
    @State private var obesity: Int = 2 // 0 = No, 1 = Yes, 2 = Prefer not to answer
    @State private var diabetes: Int = 2 // 0 = No, 1 = Yes, 2 = Prefer not to answer
    @State private var cardiovascularDisease: Int = 2 // 0 = No, 1 = Yes, 2 = Prefer not to answer
    @State private var smokingStatus: Int = 2 // 0 = No, 1 = Yes, 2 = Prefer not to answer
    @State private var alcoholUse: Int = 2 // 0 = No, 1 = Yes, 2 = Prefer not to answer
    @State private var bmi: Double = 0 // Default BMI, user can override
    @State private var ageAtTime0: Int = 0 // Default from HealthKit, but user can override
    
    // BMI and HealthKit state
    @State private var isFetchingBMI = false
    @State private var showBMIInputSheet = false
    @State private var heightInMeters: Double = 1.7 // Default height for input
    @State private var weightInKg: Double = 70.0 // Default weight for input
    
    // Validation state
    @State private var showValidationWarning = false
    @State private var validationMessage = ""
    
    // Picker options
    private let ethnicityOptions = [
        (0, "Not Hispanic or Latino"),
        (1, "Hispanic or Latino"),
        (2, "Prefer not to answer")
    ]
    
    private let binaryOptions = [
        (0, "No"),
        (1, "Yes"),
        (2, "Prefer not to answer")
    ]
    
    private let sexOptions = [
        (0, "Female"),
        (1, "Male"),
        (2, "Prefer not to answer")
    ]
    
    // BMI options (15-50 range)
    private var bmiOptions: [(Int, String)] {
        return (15...50).map { ($0, "\($0)") }
    }
    
    // Age options (18-100)
    private var ageOptions: [(Int, String)] {
        return (18...100).map { ($0, "\($0) years old") }
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("COPD Risk Assessment")
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Please answer these questions to help us assess your COPD risk. Information from your HealthKit is pre-filled but can be edited.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    
                    // Survey Questions
                    VStack(spacing: 20) {
                        // Basic Demographics
                        surveySection(title: "Basic Information", icon: "person.fill") {
                            VStack(spacing: 16) {
                                surveyQuestion(
                                    title: "What is your age?",
                                    subtitle: "This helps us understand your risk profile",
                                    isFromHealthKit: true
                                ) {
                                    Picker("Age", selection: $ageAtTime0) {
                                        ForEach(18...100, id: \.self) { age in
                                            Text("\(age) years").tag(age)
                                        }
                                    }
                                    .pickerStyle(.wheel)
                                    .frame(height: 120)
                                }
                                
                                surveyQuestion(
                                    title: "What is your sex assigned at birth?",
                                    subtitle: "This information is used for medical risk calculation",
                                    isFromHealthKit: true
                                ) {
                                    radioButtonGroup(options: sexOptions, selection: $sexAtBirth)
                                }
                                
                                surveyQuestion(
                                    title: "Are you Hispanic or Latino?",
                                    subtitle: "Ethnicity can affect health risk factors"
                                ) {
                                    radioButtonGroup(options: ethnicityOptions, selection: $ethnicity)
                                }
                            }
                        }
                        
                        // Physical Health
                        surveySection(title: "Physical Health", icon: "heart.fill") {
                            VStack(spacing: 16) {
                                surveyQuestion(
                                    title: "What is your current BMI (Body Mass Index)?",
                                    subtitle: "BMI is calculated from height and weight",
                                    isFromHealthKit: true
                                ) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack {
                                            if isFetchingBMI {
                                                ProgressView()
                                                    .scaleEffect(0.8)
                                                Text("Fetching from HealthKit...")
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                            } else {
                                                TextField("BMI", value: $bmi, formatter: NumberFormatter())
                                                    .textFieldStyle(.roundedBorder)
                                                    .keyboardType(.decimalPad)
                                                    .frame(width: 80)
                                                Text("kg/m²")
                                                    .foregroundColor(.secondary)
                                                Spacer()
                                            }
                                        }
                                        
                                        if bmi == 0 && !isFetchingBMI {
                                            Button(action: {
                                                showBMIInputSheet = true
                                            }) {
                                                HStack {
                                                    Image(systemName: "plus.circle.fill")
                                                    Text("Enter Height & Weight")
                                                }
                                                .font(.subheadline)
                                                .foregroundColor(.blue)
                                            }
                                        }
                                    }
                                }
                                
                                surveyQuestion(
                                    title: "Do you have obesity?",
                                    subtitle: "Generally defined as BMI ≥ 30"
                                ) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        radioButtonGroup(options: binaryOptions, selection: $obesity)
                                        
                                        // Show validation warning if BMI and obesity don't match
                                        if showBMIObesityWarning() {
                                            HStack(spacing: 8) {
                                                Image(systemName: "exclamationmark.triangle.fill")
                                                    .foregroundColor(.orange)
                                                    .font(.caption)
                                                Text(getBMIObesityWarningMessage())
                                                    .font(.caption)
                                                    .foregroundColor(.orange)
                                            }
                                            .padding(.top, 4)
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Medical Conditions
                        surveySection(title: "Medical History", icon: "cross.case.fill") {
                            VStack(spacing: 16) {
                                surveyQuestion(
                                    title: "Do you have diabetes?",
                                    subtitle: "Type 1 or Type 2 diabetes"
                                ) {
                                    radioButtonGroup(options: binaryOptions, selection: $diabetes)
                                }
                                
                                surveyQuestion(
                                    title: "Do you have heart disease or cardiovascular problems?",
                                    subtitle: "Including heart attack, heart failure, or coronary artery disease"
                                ) {
                                    radioButtonGroup(options: binaryOptions, selection: $cardiovascularDisease)
                                }
                            }
                        }
                        
                        // Lifestyle Factors
                        surveySection(title: "Lifestyle", icon: "leaf.fill") {
                            VStack(spacing: 16) {
                                surveyQuestion(
                                    title: "Do you currently smoke or have you smoked in the past?",
                                    subtitle: "Smoking is a major risk factor for COPD"
                                ) {
                                    radioButtonGroup(options: binaryOptions, selection: $smokingStatus)
                                }
                                
                                surveyQuestion(
                                    title: "Do you regularly consume alcohol?",
                                    subtitle: "More than 1-2 drinks per day"
                                ) {
                                    radioButtonGroup(options: binaryOptions, selection: $alcoholUse)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Action buttons
                    VStack(spacing: 12) {
                        Button(action: {
                            if validateResponses() {
                                Task {
                                    await sendToModel()
                                }
                            }
                        }) {
                            HStack {
                                if isLoadingPrediction {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                } else {
                                    Image(systemName: "brain.head.profile")
                                }
                                Text(isLoadingPrediction ? "Predicting..." : "Send to Model")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isLoadingPrediction ? Color.gray : Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isLoadingPrediction)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    
                    
                    if let error = predictionError {
                        VStack(spacing: 8) {
                            Text("Prediction Error")
                                .font(.headline)
                                .foregroundColor(.red)
                            Text(error)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }
                    
                    Spacer()
                }
                .padding(.vertical)
            }
            .navigationTitle("COPD Survey")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                initializeHealthData()
            }
            .alert("Validation Warning", isPresented: $showValidationWarning) {
                Button("OK") {
                    showValidationWarning = false
                }
            } message: {
                Text(validationMessage)
            }
            .sheet(isPresented: $showingResults) {
                COPDResultsView(
                    predictionResult: predictionResult,
                    predictionError: predictionError
                )
            }
            .sheet(isPresented: $showBMIInputSheet) {
                BMIInputSheet(
                    heightInMeters: $heightInMeters,
                    weightInKg: $weightInKg,
                    onSave: saveBMIData,
                    onCancel: { showBMIInputSheet = false }
                )
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private func surveySection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.blue)
                    .font(.title3)
                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            content()
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @ViewBuilder
    private func surveyQuestion<Content: View>(title: String, subtitle: String? = nil, isFromHealthKit: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                if isFromHealthKit {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            content()
        }
    }
    
    @ViewBuilder
    private func radioButtonGroup(options: [(Int, String)], selection: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(options, id: \.0) { option in
                Button(action: {
                    selection.wrappedValue = option.0
                }) {
                    HStack {
                        Image(systemName: selection.wrappedValue == option.0 ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selection.wrappedValue == option.0 ? .blue : .gray)
                        Text(option.1)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
    
    @ViewBuilder
    private func jsonField(key: String, value: Any, options: [(Int, String)]? = nil, binding: Binding<Int>? = nil, isStatic: Bool = false, isFromHealthKit: Bool = false, isLast: Bool = false, fieldLabel: String? = nil) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text("    \"\(key)\" : ")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
            
            if isStatic {
                // Static value (not editable)
                Text("\(value)")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(6)
            } else if let options = options, let binding = binding {
                // Interactive picker with optional field label
                Menu {
                    if let fieldLabel = fieldLabel {
                        Text(fieldLabel)
                            .font(.headline)
                        Divider()
                    }
                    ForEach(options, id: \.0) { option in
                        Button(option.1) {
                            binding.wrappedValue = option.0
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("\(binding.wrappedValue)")
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)
                            .foregroundColor(getValueColor(binding.wrappedValue, isFromHealthKit: isFromHealthKit))
                        
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(getBackgroundColor(binding.wrappedValue, isFromHealthKit: isFromHealthKit))
                    .cornerRadius(6)
                }
            }
            
            if !isLast {
                Text(",")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func jsonFieldFloat(key: String, value: Double, binding: Binding<Double>, isFromHealthKit: Bool = false, isLast: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text("    \"\(key)\" : ")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
            
            // Float value
            TextField("25.0", value: binding, formatter: NumberFormatter())
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(isFromHealthKit ? .green : .primary)
                .multilineTextAlignment(.center)
                .frame(width: 60)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isFromHealthKit ? Color.green.opacity(0.1) : Color.blue.opacity(0.1))
                .cornerRadius(6)
            
            if !isLast {
                Text(",")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
    
    @ViewBuilder
    private func jsonFieldAge(key: String, value: Int, binding: Binding<Int>, isFromHealthKit: Bool = false, isLast: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text("    \"\(key)\" : ")
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
            
            // Age picker
            Menu {
                Text("Select your age")
                    .font(.headline)
                Divider()
                ForEach(ageOptions, id: \.0) { option in
                    Button(option.1) {
                        binding.wrappedValue = option.0
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("\(binding.wrappedValue)")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                        .foregroundColor(isFromHealthKit ? .green : .primary)
                    
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isFromHealthKit ? Color.green.opacity(0.1) : Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
            
            if !isLast {
                Text(",")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
            }
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 2)
    }
    
    private func getValueColor(_ value: Int, isFromHealthKit: Bool) -> Color {
        if isFromHealthKit {
            return .green
        } else if value == 2 { // "Prefer not to answer" is now the default/unset state
            return .orange
        } else {
            return .primary
        }
    }
    
    private func getBackgroundColor(_ value: Int, isFromHealthKit: Bool) -> Color {
        if isFromHealthKit {
            return Color.green.opacity(0.1)
        } else if value == 2 { // "Prefer not to answer" is now the default/unset state
            return Color.orange.opacity(0.15)
        } else {
            return Color.blue.opacity(0.1)
        }
    }
    
    private func generateUpdatedJSON() -> String {
        let data: [String: Any] = [
            "ethnicity": ethnicity == 2 ? NSNull() : getOptionLabel(ethnicity, from: ethnicityOptions),
            "sex_at_birth": getSexString(sexAtBirth),
            "obesity": obesity == 2 ? NSNull() : obesity,
            "diabetes": diabetes == 2 ? NSNull() : diabetes,
            "cardiovascular_disease": cardiovascularDisease == 2 ? NSNull() : cardiovascularDisease,
            "smoking_status": smokingStatus == 2 ? NSNull() : smokingStatus,
            "alcohol_use": alcoholUse == 2 ? NSNull() : alcoholUse,
            "bmi": bmi,
            "age_at_time_0": ageAtTime0
        ]
        
        let jsonArray = [data]
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted)
            return String(data: jsonData, encoding: .utf8) ?? jsonString
        } catch {
            return jsonString
        }
    }
    
    private func getSexString(_ value: Int) -> String {
        switch value {
        case 0: return "Female"
        case 1: return "Male"
        case 2: return "Prefer not to answer"
        default: return "Unknown"
        }
    }
    
    private func getOptionLabel(_ value: Int, from options: [(Int, String)]) -> String {
        return options.first { $0.0 == value }?.1 ?? "Unknown"
    }
    
    private func sendToModel() async {
        isLoadingPrediction = true
        predictionError = nil
        
        let inputData = COPDModelRequest.COPDInputData(
            ethnicity: ethnicity == 2 ? "Unknown" : getOptionLabel(ethnicity, from: ethnicityOptions),
            sex_at_birth: getSexString(sexAtBirth),
            obesity: obesity == 2 ? 0.0 : Double(obesity),
            diabetes: diabetes == 2 ? 0.0 : Double(diabetes),
            cardiovascular_disease: cardiovascularDisease == 2 ? 0.0 : Double(cardiovascularDisease),
            smoking_status: smokingStatus == 2 ? 0.0 : Double(smokingStatus),
            alcohol_use: alcoholUse == 2 ? 0.0 : Double(alcoholUse),
            bmi: bmi,
            age_at_time_0: Double(ageAtTime0)
        )
        
        do {
            let result = try await COPDModelService.shared.predictCOPD(data: inputData)
            predictionResult = result
            showingResults = true
        } catch {
            predictionError = error.localizedDescription
            showingResults = true
        }
        
        isLoadingPrediction = false
    }
    
    private func initializeHealthData() {
        print("🔍 Initializing health data from \(healthRecords.count) records...")
        
        // First, try to fetch BMI directly from HealthKit using HealthKitManager
        fetchBMIFromHealthKit()
        
        // Fetch age and sex directly from HealthKit
        fetchAgeAndSexFromHealthKit()
        
        // Extract data from HealthKit records
        for record in healthRecords {
            if let healthKitData = record.healthKitData,
               let type = record.healthKitType?.lowercased() {
                
                // Extract BMI
                if type.contains("bodymassindex") || type.contains("bmi") {
                    if let bmiValue = healthKitData["value"] as? Double {
                        bmi = bmiValue
                        print("✅ Initialized BMI from HealthKit: \(bmiValue)")
                    } else if let bmiValue = healthKitData["value"] as? NSNumber {
                        bmi = bmiValue.doubleValue
                        print("✅ Initialized BMI from HealthKit (NSNumber): \(bmiValue.doubleValue)")
                    }
                }
                
                // Extract biological sex
                if type.contains("biologicalsex") {
                    if let sexValue = healthKitData["value"] as? Int {
                        // Apple HealthKit HKBiologicalSex enum:
                        // HKBiologicalSex.female = 1, HKBiologicalSex.male = 2
                        switch sexValue {
                        case 1:
                            sexAtBirth = 0 // Female
                            print("✅ Initialized sex as Female from HealthKit")
                        case 2:
                            sexAtBirth = 1 // Male
                            print("✅ Initialized sex as Male from HealthKit")
                        default:
                            sexAtBirth = 2 // Prefer not to answer
                            print("⚠️ Unknown sex value from HealthKit: \(sexValue)")
                        }
                    }
                }
                
                // Extract age from date of birth
                if type.contains("dateofbirth") {
                    if let birthDate = healthKitData["value"] as? Date {
                        let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 35
                        ageAtTime0 = age
                        print("✅ Initialized age from HealthKit: \(age)")
                    }
                }
                
                // Check for BMI in Clinical Vital Sign Records
                if type.contains("vitalsignrecord") {
                    if let fhirResourceString = healthKitData["fhirResource"] as? String,
                       let fhirData = decodeFHIRResource(fhirResourceString) as? [String: Any] {
                        if let bmiValue = extractBMIFromFHIRData(fhirData) {
                            bmi = bmiValue
                            print("✅ Initialized BMI from FHIR Vital Sign: \(bmiValue)")
                        }
                    }
                }
                
                // Extract ethnicity and other data from Patient FHIR resources
                if type.contains("patientfhirresource") {
                    if let fhirResourceString = healthKitData["fhirResource"] as? String,
                       let fhirData = decodeFHIRResource(fhirResourceString) as? [String: Any] {
                        extractPatientDataFromFHIR(fhirData)
                    }
                }
            }
        }
        
        print("💡 Health data initialization complete")
        print("   BMI: \(bmi)")
        print("   Age: \(ageAtTime0)")
        print("   Sex: \(sexAtBirth)")
        print("   Ethnicity: \(ethnicity)")
    }
    
    private func extractPatientDataFromFHIR(_ fhirData: [String: Any]) {
        // Extract ethnicity from Patient FHIR resource extensions
        if let extensions = fhirData["extension"] as? [[String: Any]] {
            for ext in extensions {
                if let url = ext["url"] as? String,
                   url.contains("us-core-ethnicity") || url.contains("ethnicity") {
                    
                    if let nestedExtensions = ext["extension"] as? [[String: Any]] {
                        for nestedExt in nestedExtensions {
                            if let nestedUrl = nestedExt["url"] as? String,
                               nestedUrl == "ombCategory" {
                                if let valueCoding = nestedExt["valueCoding"] as? [String: Any],
                                   let display = valueCoding["display"] as? String {
                                    if display.lowercased().contains("hispanic") {
                                        ethnicity = 1 // Hispanic or Latino
                                        print("✅ Initialized ethnicity as Hispanic/Latino from FHIR")
                                    } else if display.lowercased().contains("not hispanic") {
                                        ethnicity = 0 // Not Hispanic or Latino
                                        print("✅ Initialized ethnicity as Not Hispanic/Latino from FHIR")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Validation Functions
    
    private func showBMIObesityWarning() -> Bool {
        // Only show warning if user has made explicit choices (not "prefer not to answer")
        guard obesity != 2 else { return false }
        
        let isObese = bmi >= 30.0
        let userSaysObese = obesity == 1
        
        return isObese != userSaysObese
    }
    
    private func getBMIObesityWarningMessage() -> String {
        let isObese = bmi >= 30.0
        let userSaysObese = obesity == 1
        
        if isObese && !userSaysObese {
            return "Your BMI (\(String(format: "%.1f", bmi))) suggests obesity (≥30), but you selected 'No'"
        } else if !isObese && userSaysObese {
            return "Your BMI (\(String(format: "%.1f", bmi))) is below the obesity threshold (<30), but you selected 'Yes'"
        }
        return ""
    }
    
    private func validateResponses() -> Bool {
        // Check BMI-obesity consistency
        if showBMIObesityWarning() {
            validationMessage = "Please review the BMI and obesity responses for consistency."
            showValidationWarning = true
            return false
        }
        
        return true
    }
    
    private func decodeFHIRResource(_ base64String: String) -> Any? {
        guard let data = Data(base64Encoded: base64String) else {
            guard let jsonData = base64String.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: jsonData)
        }
        
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            if let jsonString = String(data: data, encoding: .utf8),
               let jsonData = jsonString.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: jsonData)
            }
            return nil
        }
    }
    
    private func extractBMIFromFHIRData(_ fhirData: [String: Any]) -> Double? {
        if let code = fhirData["code"] as? [String: Any],
           let text = code["text"] as? String,
           (text.lowercased().contains("bmi") || text.lowercased().contains("body mass index")),
           let valueQuantity = fhirData["valueQuantity"] as? [String: Any],
           let value = valueQuantity["value"] as? Double {
            return value
        }
        return nil
    }
    
    private func extractBMIFromFHIR(fhirData: [String: Any]) {
        // Check for Observation resources with BMI
        if let observation = fhirData["Observation"] as? [String: Any] {
            checkObservationForBMI(observation: observation)
        } else if let entries = fhirData["entry"] as? [[String: Any]] {
            for entry in entries {
                if let resource = entry["resource"] as? [String: Any],
                   let resourceType = resource["resourceType"] as? String,
                   resourceType == "Observation" {
                    checkObservationForBMI(observation: resource)
                }
            }
        }
    }
    
    private func checkObservationForBMI(observation: [String: Any]) {
        if let code = observation["code"] as? [String: Any],
           let coding = code["coding"] as? [[String: Any]] {
            
            for codeEntry in coding {
                // Check for BMI LOINC code or display text
                if let loincCode = codeEntry["code"] as? String,
                   let system = codeEntry["system"] as? String,
                   system.contains("loinc.org") && loincCode == "39156-5" {
                    
                    if let valueQuantity = observation["valueQuantity"] as? [String: Any],
                       let value = valueQuantity["value"] as? Double {
                        bmi = value
                        print("✅ Initialized BMI from FHIR: \(value)")
                        return
                    }
                } else if let display = codeEntry["display"] as? String,
                          display.lowercased().contains("body mass index") || display.lowercased().contains("bmi") {
                    
                    if let valueQuantity = observation["valueQuantity"] as? [String: Any],
                       let value = valueQuantity["value"] as? Double {
                        bmi = value
                        print("✅ Initialized BMI from FHIR (by display): \(value)")
                        return
                    }
                }
            }
        }
    }
    
    // MARK: - BMI Fetching Functions
    
    private func fetchBMIFromHealthKit() {
        print("🔍 Fetching BMI from HealthKit...")
        isFetchingBMI = true
        
        healthKitManager.fetchOrCalculateBMI { bmiValue in
            DispatchQueue.main.async {
                self.isFetchingBMI = false
                
                if let bmiValue = bmiValue {
                    self.bmi = bmiValue
                    print("✅ Successfully fetched BMI from HealthKit: \(bmiValue)")
                } else {
                    print("⚠️ No BMI found in HealthKit - will prompt user for height/weight")
                    self.showBMIInputSheet = true
                }
            }
        }
    }
    
    private func saveBMIData() {
        print("💾 Saving height (\(heightInMeters)m) and weight (\(weightInKg)kg) to HealthKit...")
        
        healthKitManager.saveHeightWeightAndCalculateBMI(
            heightInMeters: heightInMeters,
            weightInKg: weightInKg
        ) { calculatedBMI in
            DispatchQueue.main.async {
                if let calculatedBMI = calculatedBMI {
                    self.bmi = calculatedBMI
                    self.showBMIInputSheet = false
                    print("✅ Successfully saved data and calculated BMI: \(calculatedBMI)")
                } else {
                    print("❌ Failed to save BMI data to HealthKit")
                    // Still calculate BMI locally if HealthKit save fails
                    let calculatedBMI = self.weightInKg / pow(self.heightInMeters, 2)
                    self.bmi = calculatedBMI
                    self.showBMIInputSheet = false
                }
            }
        }
    }
    
    private func fetchAgeAndSexFromHealthKit() {
        print("🔍 Fetching age and sex from HealthKit...")
        
        // Fetch biological sex
        do {
            let biologicalSex = try healthKitManager.healthStore.biologicalSex()
            switch biologicalSex.biologicalSex {
            case .female:
                sexAtBirth = 0
                print("✅ Fetched sex from HealthKit: Female")
            case .male:
                sexAtBirth = 1
                print("✅ Fetched sex from HealthKit: Male")
            case .other:
                sexAtBirth = 2
                print("⚠️ Fetched sex from HealthKit: Other (setting to prefer not to answer)")
            case .notSet:
                print("⚠️ Biological sex not set in HealthKit")
            @unknown default:
                print("⚠️ Unknown biological sex value from HealthKit")
            }
        } catch {
            print("❌ Error fetching biological sex: \(error.localizedDescription)")
        }
        
        // Fetch date of birth and calculate age
        do {
            if let birthDate = try healthKitManager.healthStore.dateOfBirthComponents().date {
                let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
                if age > 0 {
                    ageAtTime0 = age
                    print("✅ Fetched age from HealthKit: \(age)")
                } else {
                    print("⚠️ Invalid age calculated from birth date")
                }
            }
        } catch {
            print("❌ Error fetching date of birth: \(error.localizedDescription)")
        }
    }
}

struct BMIInputSheet: View {
    @Binding var heightInMeters: Double
    @Binding var weightInKg: Double
    let onSave: () -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    // Imperial unit states
    @State private var feet: Int = 5
    @State private var inches: Int = 9
    @State private var pounds: Int = 154
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(spacing: 12) {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 50))
                        .foregroundColor(.blue)
                    
                    Text("Height & Weight")
                        .font(.title)
                        .fontWeight(.bold)
                    
                    Text("We need your height and weight to calculate BMI. This data will be saved to Apple Health.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 8)
                
                HStack(spacing: 32) {
                    // Height Section
                    VStack(spacing: 8) {
                        Text("Height")
                            .font(.headline)
                        
                        HStack(spacing: 4) {
                            // Feet picker
                            Picker("Feet", selection: $feet) {
                                ForEach(3...8, id: \.self) { foot in
                                    Text("\(foot)").tag(foot)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 50, height: 100)
                            .clipped()
                            
                            Text("ft")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                            
                            // Inches picker
                            Picker("Inches", selection: $inches) {
                                ForEach(0...11, id: \.self) { inch in
                                    Text("\(inch)").tag(inch)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 50, height: 100)
                            .clipped()
                            
                            Text("in")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 20)
                        }
                    }
                    
                    // Weight Section
                    VStack(spacing: 8) {
                        Text("Weight")
                            .font(.headline)
                        
                        HStack(spacing: 4) {
                            Picker("Weight", selection: $pounds) {
                                ForEach(80...400, id: \.self) { pound in
                                    Text("\(pound)").tag(pound)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 70, height: 100)
                            .clipped()
                            
                            Text("lbs")
                                .font(.body)
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                        }
                    }
                }
                .padding(.horizontal, 16)
                
                VStack(spacing: 8) {
                    Text("Calculated BMI")
                        .font(.headline)
                    Text(String(format: "%.1f", calculateBMI()))
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)
                .padding(.bottom, 20)
                
                HStack(spacing: 16) {
                    Button("Cancel") {
                        onCancel()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .foregroundColor(.primary)
                    .cornerRadius(12)
                    
                    Button("Save to Health") {
                        convertAndSave()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .navigationBarHidden(true)
            .onAppear {
                initializeFromMetricValues()
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func initializeFromMetricValues() {
        // Convert existing metric values to imperial for display
        if heightInMeters > 0 {
            let totalInches = heightInMeters * 39.3701 // meters to inches
            feet = Int(totalInches / 12)
            inches = Int(totalInches.truncatingRemainder(dividingBy: 12))
        }
        
        if weightInKg > 0 {
            pounds = Int(weightInKg * 2.20462) // kg to pounds
        }
    }
    
    private func calculateBMI() -> Double {
        let heightInMeters = convertHeightToMeters()
        let weightInKg = convertWeightToKg()
        return weightInKg / (heightInMeters * heightInMeters)
    }
    
    private func convertHeightToMeters() -> Double {
        let totalInches = Double(feet * 12 + inches)
        return totalInches * 0.0254 // inches to meters
    }
    
    private func convertWeightToKg() -> Double {
        return Double(pounds) * 0.453592 // pounds to kg
    }
    
    private func convertAndSave() {
        // Update the binding values with converted metric values
        heightInMeters = convertHeightToMeters()
        weightInKg = convertWeightToKg()
        
        // Call the save function
        onSave()
    }
}

struct COPDResultsView: View {
    let predictionResult: COPDPredictionResult?
    let predictionError: String?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "lungs.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)
                        
                        Text("COPD Risk Assessment Results")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.center)
                        
                        Text("Based on your health profile and survey responses")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top)
                    
                    // Results or Error
                    if let result = predictionResult {
                        let copdRisk = (1.0 - result.survivalProbability5Years) * 100
                        
                        // Success Results - Consistent Design System
                        VStack(spacing: 20) {
                            // COPD Risk Card
                            VStack(spacing: 16) {
                                Text("5-Year COPD Risk")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Text(String(format: "%.1f%%", copdRisk))
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .foregroundColor(copdRisk > 10 ? .red : copdRisk > 5 ? .orange : .green)
                                
                                Text("Probability of developing COPD within 5 years")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                            
                            // Hazard Ratio Card
                            VStack(spacing: 16) {
                                Text("Partial Hazard Ratio")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                Text(String(format: "%.3f", result.partialHazard))
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .foregroundColor(.blue)
                                
                                Text("Your relative risk compared to average population")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(20)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                            
                            // Risk Assessment Card
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Risk Assessment")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(copdRisk > 10 ? .red : copdRisk > 5 ? .orange : .green)
                                        .frame(width: 8, height: 8)
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(getRiskLevelText(copdRisk))
                                            .font(.headline)
                                            .fontWeight(.semibold)
                                        
                                        Text(getRiskDescription(copdRisk))
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                            
                            // Understanding Results Card
                            VStack(alignment: .leading, spacing: 16) {
                                Text("Understanding Your Results")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                
                                VStack(alignment: .leading, spacing: 16) {
                                    // COPD Risk Explanation
                                    HStack(alignment: .top, spacing: 12) {
                                        Circle()
                                            .fill(.blue)
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 6)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("COPD Risk Percentage")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("Shows your likelihood of developing COPD in the next 5 years")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    // Hazard Ratio Explanation
                                    HStack(alignment: .top, spacing: 12) {
                                        Circle()
                                            .fill(.blue)
                                            .frame(width: 8, height: 8)
                                            .padding(.top, 6)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Hazard Ratio")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("Values above 1.0 = higher risk, below 1.0 = lower risk than average")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(16)
                        }
                        
                    } else if let error = predictionError {
                        // Error State
                        VStack(spacing: 16) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 48))
                                .foregroundColor(.red)
                            
                            Text("Prediction Error")
                                .font(.headline)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                            
                            Text(error)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(12)
                    }
                    
                    // Action Buttons
                    VStack(spacing: 16) {
                        Button("Retake Survey") {
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(16)
                        
                        Button("Done") {
                            dismiss()
                        }
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color(UIColor.secondarySystemBackground))
                        .foregroundColor(.primary)
                        .cornerRadius(16)
                    }
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Results")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func getRiskLevelText(_ risk: Double) -> String {
        if risk > 10 {
            return "High Risk"
        } else if risk > 5 {
            return "Moderate Risk"
        } else {
            return "Low Risk"
        }
    }
    
    private func getRiskDescription(_ risk: Double) -> String {
        if risk > 10 {
            return "Your risk is elevated. Consider discussing these results with your healthcare provider for personalized advice and potential preventive measures."
        } else if risk > 5 {
            return "Your risk is moderate. Maintaining healthy lifestyle choices and regular check-ups with your healthcare provider is recommended."
        } else {
            return "Your risk is relatively low based on the current assessment. Continue maintaining healthy lifestyle choices."
        }
    }
}
