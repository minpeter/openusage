import Foundation

public struct LinuxCLIArguments: Equatable, Sendable {
    public var providerID: String?
    public var force = false
    public var showHelp = false
    public var showVersion = false

    public init() {}

    public static func parse(_ arguments: [String]) throws -> LinuxCLIArguments {
        var parsed = LinuxCLIArguments()
        for argument in arguments {
            switch argument {
            case "--force": parsed.force = true
            case "-h", "--help": parsed.showHelp = true
            case "-v", "--version": parsed.showVersion = true
            default:
                if argument.hasPrefix("-") { throw LinuxCLIError.usage("Unknown option: \(argument)") }
                guard parsed.providerID == nil else {
                    throw LinuxCLIError.usage("Only one provider can be requested at a time.")
                }
                parsed.providerID = argument.lowercased()
            }
        }
        return parsed
    }
}

public enum LinuxCLIError: Error, Equatable, Sendable {
    case usage(String)
}

public struct LinuxCLIOutput: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitCode: Int32

    public init(standardOutput: Data, standardError: Data, exitCode: Int32) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitCode = exitCode
    }
}

public enum LinuxCLIRunner {
    public static let help = """
    Usage: openusage [provider] [--force]

    Read limits through OpenUsage's shared five-minute cache and exit. Output is always JSON.

    Options:
      --force      Refresh even when the shared cache is still fresh
      -v, --version
      -h, --help
    """

    public static func run(
        arguments: [String],
        source: any ProviderSnapshotSource,
        version: String? = nil
    ) async -> LinuxCLIOutput {
        let parsed: LinuxCLIArguments
        do {
            parsed = try LinuxCLIArguments.parse(arguments)
        } catch LinuxCLIError.usage(let message) {
            return failure("\(message)\nRun 'openusage --help' for usage.", code: 2)
        } catch {
            return failure(error.localizedDescription, code: 4)
        }

        if parsed.showHelp {
            return success(Data((help + "\n").utf8))
        }
        if parsed.showVersion {
            return success(Data("openusage \(version ?? "(development build)")\n".utf8))
        }

        let snapshots = await source.snapshots(force: parsed.force)
        let known = await source.knownProviderIDs()
        let state = LinuxUsageAPIState(knownProviderIDs: known, snapshots: snapshots)
        let path = parsed.providerID.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LinuxUsageAPI.respond(method: "GET", path: path, state: state)
        if response.status == 404, let providerID = parsed.providerID {
            return failure("Unknown provider: \(providerID)", code: 2)
        }
        guard response.status == 200, let body = response.body else {
            return failure("Could not encode usage JSON.", code: 4)
        }

        let selected = parsed.providerID.flatMap { state.matchingSnapshots($0) } ?? snapshots
        let warnings = selected.compactMap { snapshot in
            snapshot.errorMessage.map { "\(snapshot.instanceID): \($0)" }
        }
        var output = body
        output.append(0x0A)
        guard !warnings.isEmpty else { return success(output) }
        let stderr = warnings.map { "openusage: warning: \($0)\n" }.joined()
        return LinuxCLIOutput(standardOutput: output, standardError: Data(stderr.utf8), exitCode: 4)
    }

    private static func success(_ data: Data) -> LinuxCLIOutput {
        LinuxCLIOutput(standardOutput: data, standardError: Data(), exitCode: 0)
    }

    private static func failure(_ message: String, code: Int32) -> LinuxCLIOutput {
        LinuxCLIOutput(
            standardOutput: Data(),
            standardError: Data("openusage: \(message)\n".utf8),
            exitCode: code
        )
    }
}
