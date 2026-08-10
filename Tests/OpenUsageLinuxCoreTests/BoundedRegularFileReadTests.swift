import Foundation
import Glibc
import Testing
@testable import OpenUsageLinuxCore

@Suite("Bounded regular-file reads")
struct BoundedRegularFileReadTests {
    @Test("Provider reads reject a FIFO instead of parsing streamed credentials")
    func providerReaderRejectsFIFO() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("credentials.fifo")
        #expect(fifo.path.withCString { Glibc.mkfifo($0, mode_t(0o600)) } == 0)

        let descriptor = fifo.path.withCString {
            Glibc.open($0, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        }
        #expect(descriptor >= 0)
        defer { _ = Glibc.close(descriptor) }
        var byte: UInt8 = 0x78
        #expect(Glibc.write(descriptor, &byte, 1) == 1)

        #expect(throws: ProviderFileReadError.unreadable(path: fifo.path)) {
            try BoundedProviderFileReader(maximumBytes: 8).read(fifo)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
}
