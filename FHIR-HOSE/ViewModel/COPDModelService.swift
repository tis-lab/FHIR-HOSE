import Foundation

struct COPDPredictionResult {
    let partialHazard: Double
    let survivalProbability5Years: Double
}

struct COPDModelRequest: Codable {
    let image: String = "coxcopdmodel:latest"
    let input: [COPDInputData]
    
    struct COPDInputData: Codable {
        let ethnicity: String
        let sex_at_birth: String
        let obesity: Double
        let diabetes: Double
        let cardiovascular_disease: Double
        let smoking_status: Double
        let alcohol_use: Double
        let bmi: Double
        let age_at_time_0: Double
    }
}

struct COPDModelResponse: Codable {
    let predictions: [COPDPrediction]
    
    struct COPDPrediction: Codable {
        let partial_hazard: Double
        let survival_probability_5_years: Double
    }
}

class COPDModelService {
    static let shared = COPDModelService()
    private let baseURL = "http://localhost:8000"
    
    private init() {}
    
    func predictCOPD(data: COPDModelRequest.COPDInputData) async throws -> COPDPredictionResult {
        guard let url = URL(string: "\(baseURL)/modeling/predict") else {
            throw URLError(.badURL)
        }
        
        let request = COPDModelRequest(input: [data])
        
        // Debug: Print the request JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let jsonData = try? encoder.encode(request),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("🚀 Sending request to API:")
            print(jsonString)
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        
        let (responseData, httpResponse) = try await URLSession.shared.data(for: urlRequest)
        
        // Debug: Print the response
        if let httpResponse = httpResponse as? HTTPURLResponse {
            print("📡 API Response Status: \(httpResponse.statusCode)")
        }
        
        if let responseString = String(data: responseData, encoding: .utf8) {
            print("📡 API Response Body:")
            print(responseString)
        }
        
        let response = try JSONDecoder().decode(COPDModelResponse.self, from: responseData)
        
        guard let firstPrediction = response.predictions.first else {
            throw NSError(domain: "COPDModelService", code: 1, userInfo: [NSLocalizedDescriptionKey: "No predictions returned"])
        }
        
        return COPDPredictionResult(
            partialHazard: firstPrediction.partial_hazard,
            survivalProbability5Years: firstPrediction.survival_probability_5_years
        )
    }
}
