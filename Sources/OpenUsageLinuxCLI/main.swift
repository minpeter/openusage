import Foundation
import Glibc
import OpenUsageLinuxCore

@main
struct OpenUsageLinuxCLI {
    static func main() async {
        let result = await LinuxCLIRunner.run(
            arguments: Array(CommandLine.arguments.dropFirst()),
            source: LinuxUsageRepository(),
            version: ProcessInfo.processInfo.environment["OPENUSAGE_VERSION"]
        )
        StandardIO.writeOutput(result.standardOutput)
        StandardIO.writeError(result.standardError)
        // `exit` runs FoundationNetworking's global URLSession teardown while Swift's async-main
        // task is still unwinding. corelibs-foundation can then deallocate its curl `_MultiHandle`
        // with outstanding internal retains, losing output and printing a runtime warning. Both
        // FileHandle writes above are synchronous; terminate without running that unsafe teardown.
        Glibc._exit(result.exitCode)
    }
}

private enum StandardIO {
    static func writeOutput(_ data: Data) {
        FileHandle.standardOutput.write(data)
    }

    static func writeError(_ data: Data) {
        FileHandle.standardError.write(data)
    }
}
