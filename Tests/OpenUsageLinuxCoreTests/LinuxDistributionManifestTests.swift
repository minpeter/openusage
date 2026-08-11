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

    @Test("Packaged StatusNotifierItem XML matches the live Ayatana contract")
    func statusNotifierItemXML() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let xmlURL = root.appendingPathComponent(
            "linux/io.github.minpeter.OpenUsage.StatusNotifierItem.xml"
        )
        let xml = try String(contentsOf: xmlURL, encoding: .utf8)

        #expect(xml.contains(#"<property name="Menu" type="o" access="read"/>"#))
        #expect(xml.contains(#"<property name="XAyatanaLabel" type="s" access="read"/>"#))
        #expect(xml.contains(#"<property name="XAyatanaLabelGuide" type="s" access="read"/>"#))
        #expect(xml.contains(#"<signal name="XAyatanaNewLabel">"#))
    }

    @Test("CI runs the Linux lockfile build test and packaging gates")
    func linuxCIWorkflow() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let workflow = try String(
            contentsOf: root.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        #expect(workflow.contains("linux:\n    name: Linux Build, Test, and Package"))
        #expect(workflow.contains("runs-on: ubuntu-24.04"))
        #expect(workflow.contains("./scripts/validate-flatpak.sh"))
        #expect(workflow.contains("cp linux/Package.resolved Package.resolved"))
        #expect(workflow.contains(
            "swift test --disable-automatic-resolution --disable-prefetching"
        ))
        #expect(workflow.contains(
            "swift build -c release --disable-automatic-resolution --disable-prefetching"
        ))
    }
}
