import Foundation
import Testing

@Suite("Linux distribution manifest")
struct LinuxDistributionManifestTests {
    @Test("Flatpak exposes the AGY credential directory read-only")
    func flatpakAgyCredentials() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = root.appendingPathComponent("linux/io.github.minpeter.OpenUsage.yml")

        #expect(try String(contentsOf: manifest, encoding: .utf8)
            .contains("--filesystem=~/.gemini/antigravity-cli:ro"))
    }
}
