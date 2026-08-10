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
}
