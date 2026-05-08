//
//  CharmonizerModels.swift
//  FHIR-HOSE
//
//  Created by ChatGPT on 2/25/25.
//

import Foundation

// Basic structs for decoding the Charmonizer job statuses and doc objects:

struct JobIDReply: Decodable {
    let job_id: String?
}

struct DocConversionStatus: Decodable {
    let status: String
    let error: String?
    let pages_total: Int?
    let pages_converted: Int?
}

struct SummaryStatus: Decodable {
    let status: String
    let error: String?
    let chunks_total: Int?
    let chunks_completed: Int?
}

/// A JSON document from Charmonizer, which may contain child chunks, metadata, and annotations
struct JSONDocument: Codable {
    var id: String
    var content: String?
    var annotations: [String: AnyCodable]?
    var metadata: [String: AnyCodable]?
    var chunks: [String: [JSONDocument]]? // groupName -> array of JSONDocument

    // Because we have arbitrary JSON in `annotations`/`metadata`,
    // we store them with `[String: AnyCodable]`.
}

/// Summarize request structure used in the POST /summaries call.

struct SummarizeRequest: Codable {
    let document: JSONDocument
    let method: String
    let model: String
    
    // Just store it as a string:
    let json_schema: String?

    init(document: JSONDocument,
         method: String,
         model: String,
         json_schema: String?)
    {
        self.document = document
        self.method = method
        self.model = model
        self.json_schema = json_schema
    }
}

/*
struct SummarizeRequest: Codable {
    let document: JSONDocument
    let method: String      // "full", "map", etc.
    let model: String       // "gpt-4o" or another
    var json_schema: [String: AnyCodable]?

    /// Custom initializer that takes a regular `[String: Any]?` and
    /// converts it into `[String: AnyCodable]?`.
    init(document: JSONDocument,
         method: String,
         model: String,
         json_schema: [String: Any]? = nil)
    {
        self.document = document
        self.method = method
        self.model = model
        
        if let rawSchema = json_schema {
            // Convert each value into AnyCodable
            self.json_schema = rawSchema.mapValues { AnyCodable($0) }
        } else {
            self.json_schema = nil
        }
    }
}
 */

