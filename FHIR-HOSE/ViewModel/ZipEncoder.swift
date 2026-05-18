//
//  ZipEncoder.swift
//  FHIR-HOSE
//

import Foundation

/// Produces a PKZIP "stored" (uncompressed) archive from a list of named in-memory files.
/// The output is a standard `.zip` readable by Finder, `unzip`, the iOS Files app, etc.
///
/// Stored mode is used because the payloads here are small JSON files and avoiding
/// compression keeps the implementation dependency-free (no zlib deflate stream wiring).
enum ZipEncoder {

    struct File {
        let name: String
        let data: Data
    }

    static func makeArchive(files: [File]) -> Data {
        var output = Data()
        var centralDirectory = Data()
        let now = dosDateTime(Date())

        for file in files {
            let nameBytes = Array(file.name.utf8)
            let size = UInt32(file.data.count)
            let crc = crc32(file.data)
            let localOffset = UInt32(output.count)

            // Local file header
            output.append(uint32: 0x04034b50)            // signature
            output.append(uint16: 20)                    // version needed
            output.append(uint16: 0)                     // general purpose bit flag
            output.append(uint16: 0)                     // compression method (0 = stored)
            output.append(uint16: now.time)
            output.append(uint16: now.date)
            output.append(uint32: crc)
            output.append(uint32: size)                  // compressed size
            output.append(uint32: size)                  // uncompressed size
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)                     // extra field length
            output.append(Data(nameBytes))
            output.append(file.data)

            // Central directory entry
            centralDirectory.append(uint32: 0x02014b50)
            centralDirectory.append(uint16: 20)          // version made by
            centralDirectory.append(uint16: 20)          // version needed
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: 0)
            centralDirectory.append(uint16: now.time)
            centralDirectory.append(uint16: now.date)
            centralDirectory.append(uint32: crc)
            centralDirectory.append(uint32: size)
            centralDirectory.append(uint32: size)
            centralDirectory.append(uint16: UInt16(nameBytes.count))
            centralDirectory.append(uint16: 0)           // extra
            centralDirectory.append(uint16: 0)           // comment
            centralDirectory.append(uint16: 0)           // disk number
            centralDirectory.append(uint16: 0)           // internal attrs
            centralDirectory.append(uint32: 0)           // external attrs
            centralDirectory.append(uint32: localOffset)
            centralDirectory.append(Data(nameBytes))
        }

        let centralDirOffset = UInt32(output.count)
        output.append(centralDirectory)

        // End of central directory record
        output.append(uint32: 0x06054b50)
        output.append(uint16: 0)                          // disk number
        output.append(uint16: 0)                          // disk with central dir
        output.append(uint16: UInt16(files.count))
        output.append(uint16: UInt16(files.count))
        output.append(uint32: UInt32(centralDirectory.count))
        output.append(uint32: centralDirOffset)
        output.append(uint16: 0)                          // comment length

        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(max(1980, c.year ?? 1980) - 1980)
        let month = UInt16(c.month ?? 1)
        let day = UInt16(c.day ?? 1)
        let hour = UInt16(c.hour ?? 0)
        let minute = UInt16(c.minute ?? 0)
        let second = UInt16((c.second ?? 0) / 2)
        let dosDate = (year << 9) | (month << 5) | day
        let dosTime = (hour << 11) | (minute << 5) | second
        return (dosDate, dosTime)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
