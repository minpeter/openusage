import Foundation

public protocol OpenCodeSQLiteAccessing: Sendable {
    func query(path: URL, sql: String, maximumBytes: Int) throws -> Data?
}

/// Read-only sqlite3 adapter. Output is drained incrementally and terminated at the provider read cap.
public struct OpenCodeSQLiteCLI: OpenCodeSQLiteAccessing {
    public init() {}

    public func query(path: URL, sql: String, maximumBytes: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-batch", "-noheader", "-readonly", "-cmd", ".timeout 1000", path.path, sql]
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw OpenCodeLinuxError.databaseUnreadable }

        var data = Data()
        do {
            while true {
                let chunk = try output.fileHandleForReading.read(upToCount: 32 * 1024) ?? Data()
                if chunk.isEmpty { break }
                guard data.count <= maximumBytes - chunk.count else {
                    process.terminate()
                    process.waitUntilExit()
                    throw OpenCodeLinuxError.queryTooLarge(maximumBytes: maximumBytes)
                }
                data.append(chunk)
            }
        } catch let error as OpenCodeLinuxError {
            throw error
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw OpenCodeLinuxError.databaseUnreadable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw OpenCodeLinuxError.databaseUnreadable }
        while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
        return data.isEmpty ? nil : data
    }
}
