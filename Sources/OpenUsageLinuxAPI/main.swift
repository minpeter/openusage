import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Glibc
import OpenUsageLinuxCore

@main
struct OpenUsageLinuxAPI {
    static func main() async {
        let arguments: LinuxAPIArguments
        do {
            arguments = try LinuxAPIArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch LinuxCLIError.usage(let message) {
            StandardIO.writeError("openusage-api: \(message)\nRun 'openusage-api --help' for usage.\n")
            Glibc.exit(2)
        } catch {
            StandardIO.writeError("openusage-api: \(error.localizedDescription)\n")
            Glibc.exit(4)
        }

        if arguments.showHelp {
            StandardIO.writeOutput("""
            Usage: openusage-api [--port PORT]

            Serve OpenUsage JSON on the IPv4 loopback interface. The port defaults to
            OPENUSAGE_PORT or 6736.

            Options:
              --port PORT  Listen on 127.0.0.1:PORT
              -v, --version
              -h, --help

            """)
            return
        }
        if arguments.showVersion {
            StandardIO.writeOutput("openusage-api \(ProcessInfo.processInfo.environment["OPENUSAGE_VERSION"] ?? "(development build)")\n")
            return
        }

        do {
            let server = try LoopbackHTTPServer(port: arguments.port, source: LinuxUsageRepository())
            let relay = SignalRelay(server: server)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let signalQueue = DispatchQueue(label: "openusage.api.signals")
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
            let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
            interrupt.setEventHandler(handler: SignalRelay.handler(for: relay))
            terminate.setEventHandler(handler: SignalRelay.handler(for: relay))
            interrupt.resume()
            terminate.resume()
            try server.start()
            StandardIO.writeError("openusage-api: listening on 127.0.0.1:\(server.port)\n")
            server.waitUntilStopped()
            interrupt.cancel()
            terminate.cancel()
        } catch {
            StandardIO.writeError("openusage-api: \(error.localizedDescription)\n")
            Glibc.exit(4)
        }
    }
}

/// Creates signal callbacks outside async-main's inferred executor. Dispatch invokes these closures
/// on `signalQueue`; capturing an async-main-isolated local directly causes Swift 6's executor check
/// to trap in libdispatch before `LoopbackHTTPServer.stop()` can run.
private struct SignalRelay: Sendable {
    let server: LoopbackHTTPServer

    nonisolated func stop() {
        server.stop()
    }

    nonisolated static func handler(for relay: SignalRelay) -> @Sendable () -> Void {
        { relay.stop() }
    }
}

private enum StandardIO {
    static func writeOutput(_ value: String) {
        FileHandle.standardOutput.write(Data(value.utf8))
    }

    static func writeError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }
}
