import Foundation
import OpenUsageLinuxCore

enum GNOMEAppLog {
    static let file = LinuxLogPaths().file
    private static let logger = LinuxFileLogger(file: file)

    static func configure(level: LinuxLogLevel) {
        logger.setLevel(level)
    }

    static func error(_ message: String) {
        emit(.error, message)
    }

    static func warning(_ message: String) {
        emit(.warn, message)
    }

    static func info(_ message: String) {
        emit(.info, message)
    }

    static func debug(_ message: String) {
        emit(.debug, message)
    }

    private static func emit(_ level: LinuxLogLevel, _ message: String) {
        NSLog("OpenUsage: \(message)")
        do {
            try logger.write(level, message)
        } catch {
            NSLog("OpenUsage: could not write file log: \(error.localizedDescription)")
        }
    }
}
