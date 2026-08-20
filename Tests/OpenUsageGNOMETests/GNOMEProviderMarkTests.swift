import Foundation
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME provider marks")
struct GNOMEProviderMarkTests {
    @Test("Bundled symbolic marks use the shared monochrome fill")
    func symbolicMarksUseCurrentColor() throws {
        let directory = providerIconDirectory()
        let copilot = try String(
            contentsOf: directory.appendingPathComponent("copilot-symbolic.svg"),
            encoding: .utf8
        )
        let antigravity = try String(
            contentsOf: directory.appendingPathComponent("antigravity-symbolic.svg"),
            encoding: .utf8
        )
        let claude = try String(
            contentsOf: directory.appendingPathComponent("claude-symbolic.svg"),
            encoding: .utf8
        )

        #expect(copilot.contains("fill=\"currentColor\""))
        #expect(!copilot.contains("fill=\"white\""))
        #expect(antigravity.contains("fill=\"currentColor\""))
        #expect(!antigravity.contains("#4285F4"))
        #expect(claude.contains("fill=\"currentColor\"") || claude.contains("fill=\"currentColor\""))
    }

    private func providerIconDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" && url.path != "/" {
            url.deleteLastPathComponent()
        }
        return url
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenUsage/Resources/ProviderIcons", isDirectory: true)
    }
}
