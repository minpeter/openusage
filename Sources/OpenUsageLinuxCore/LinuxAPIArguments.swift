import Foundation

public struct LinuxAPIArguments: Equatable, Sendable {
    public var port: Int
    public var showHelp = false
    public var showVersion = false

    public init(port: Int = LoopbackHTTPServer.defaultPort) {
        self.port = port
    }

    public static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LinuxAPIArguments {
        let environmentPort: Int
        if let raw = environment["OPENUSAGE_PORT"] {
            guard let parsed = Int(raw), (1...65_535).contains(parsed) else {
                throw LinuxCLIError.usage("Invalid OPENUSAGE_PORT: \(raw)")
            }
            environmentPort = parsed
        } else {
            environmentPort = LoopbackHTTPServer.defaultPort
        }
        var result = LinuxAPIArguments(port: environmentPort)
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "-h", "--help": result.showHelp = true
            case "-v", "--version": result.showVersion = true
            case "--port":
                index += 1
                guard index < arguments.count, let port = Int(arguments[index]), (0...65_535).contains(port) else {
                    throw LinuxCLIError.usage("--port requires a value from 0 through 65535.")
                }
                result.port = port
            default:
                throw LinuxCLIError.usage("Unknown option: \(arguments[index])")
            }
            index += 1
        }
        return result
    }
}
