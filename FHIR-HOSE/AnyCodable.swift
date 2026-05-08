//
//  AnyCodable.swift
//  FHIR-HOSE
//
//  Created by ChatGPT on 2/25/25.
//

import Foundation

/// A minimal "AnyCodable" type to decode arbitrary JSON structures.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        switch value {
        case let bool as Bool:
            // Directly store Swift Bool
            self.value = bool

        case let num as NSNumber:
            // Check if it's actually a boolean
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                // It's a boolean disguised as NSNumber
                self.value = num.boolValue
            } else {
                // It's a numeric type
                self.value = num.doubleValue
            }

        case let dict as [String: Any]:
            // Recursively wrap each value
            self.value = dict.mapValues { AnyCodable($0) }

        case let arr as [Any]:
            // Recursively wrap each element
            self.value = arr.map { AnyCodable($0) }

        case is NSNull:
            self.value = NSNull()

        default:
            // Strings, etc. remain as-is
            self.value = value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // Try decoding in multiple ways:
        if let str = try? container.decode(String.self) {
            self.value = str
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let dbl = try? container.decode(Double.self) {
            self.value = dbl
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            // Convert [String: AnyCodable] -> [String: Any]
            self.value = dict.mapValues { $0.value }
        } else if let arr = try? container.decode([AnyCodable].self) {
            self.value = arr.map { $0.value }
        } else if container.decodeNil() {
            self.value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON type in AnyCodable."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let str as String:
            try container.encode(str)
        case let dbl as Double:
            try container.encode(dbl)
        case let int as Int:
            try container.encode(int)
        case let dict as [String: Any]:
            let converted = dict.mapValues { AnyCodable($0) }
            try container.encode(converted)
        case let arr as [Any]:
            let converted = arr.map { AnyCodable($0) }
            try container.encode(converted)
        case is NSNull:
            try container.encodeNil()
        default:
            // If there's some other numeric (Float, etc), you might handle it:
            if let floatVal = value as? Float {
                try container.encode(Double(floatVal))
            } else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: container.codingPath,
                    debugDescription: "AnyCodable encoding: Unrecognized type \(type(of: value))"
                ))
            }
        }
    }
}
