import Foundation
import OSLog

class FileLogger: ObservableObject {
    static let shared = FileLogger()
    private let logger = Logger(subsystem: "com.example.fhirhose", category: "FileLogger")
    private let logFileURL: URL
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.fhirhose.filelogger", qos: .utility)
    
    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        #if DEBUG
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let logsDir = projectRoot.appendingPathComponent("logs")
        
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        let timestamp = DateFormatter().then {
            $0.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        }.string(from: Date())
        
        logFileURL = logsDir.appendingPathComponent("fhir-hose-\(timestamp).log")
        #else
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        logFileURL = documentsPath.appendingPathComponent("fhir-hose.log")
        #endif
        
        createLogFileIfNeeded()
        log(.info, message: "FileLogger initialized. Log file: \(logFileURL.path)")
    }
    
    private func createLogFileIfNeeded() {
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        }
    }
    
    func log(_ level: OSLogType, message: String, category: String = "General") {
        let timestamp = dateFormatter.string(from: Date())
        let levelString = logLevelString(for: level)
        let logEntry = "[\(timestamp)] [\(levelString)] [\(category)] \(message)\n"
        
        logger.log(level: level, "\(message, privacy: .public)")
        
        queue.async { [weak self] in
            guard let self = self else { return }
            
            if let data = logEntry.data(using: .utf8) {
                if let fileHandle = try? FileHandle(forWritingTo: self.logFileURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                } else {
                    try? data.write(to: self.logFileURL, options: .atomic)
                }
            }
        }
    }
    
    func info(_ message: String, category: String = "General") {
        log(.info, message: message, category: category)
    }
    
    func debug(_ message: String, category: String = "General") {
        log(.debug, message: message, category: category)
    }
    
    func error(_ message: String, category: String = "General") {
        log(.error, message: message, category: category)
    }
    
    func warning(_ message: String, category: String = "General") {
        log(.default, message: message, category: category)
    }
    
    private func logLevelString(for level: OSLogType) -> String {
        switch level {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .default: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        default: return "LOG"
        }
    }
    
    func getLogFileURL() -> URL {
        return logFileURL
    }
    
    func clearLogs() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
        log(.info, message: "Log file cleared")
    }
}

extension DateFormatter {
    func then(_ block: (DateFormatter) -> Void) -> DateFormatter {
        block(self)
        return self
    }
}