//
//  ServerConfig.swift
//  FHIR-HOSE
//
//  Created by Matthew Might on 2/26/25.
//


import Foundation

struct ServerConfig: Codable {
    let serverBase: String
    let baseUrlPrefix: String
    
    static func current() -> ServerConfig {
        #if DEBUG
        return ServerConfig(
            serverBase: "http://localhost:5002",
            baseUrlPrefix: "/charm/api/charmonizer/v1"
        )
        #else
        return loadProductionConfig() ?? ServerConfig(
            serverBase: "https://matt.might.net",
            baseUrlPrefix: "/charm/api/charmonizer/v1"
        )
        #endif
    }
    
    private static func loadProductionConfig() -> ServerConfig? {
        guard let url = Bundle.main.url(forResource: "server-config", withExtension: "json") else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ServerConfig.self, from: data)
        } catch {
            return nil
        }
    }
}
