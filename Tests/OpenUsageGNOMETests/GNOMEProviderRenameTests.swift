import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME provider rename")
struct GNOMEProviderRenameTests {
    @Test("Provider rename trims, resolves, and survives settings JSON")
    func persistence() throws {
        var settings = GNOMESettings()

        settings.renameProvider("claude", to: "  Claude Work  ")
        #expect(settings.displayName(providerID: "claude", fallback: "Claude") == "Claude Work")
        #expect(settings.displayName(providerID: "codex", fallback: "Codex") == "Codex")

        let decoded = try JSONDecoder().decode(
            GNOMESettings.self,
            from: JSONEncoder().encode(settings)
        )
        #expect(decoded.providerRenames == ["claude": "Claude Work"])
        #expect(decoded.displayName(providerID: "claude", fallback: "Claude") == "Claude Work")
    }

    @Test("Blank rename restores the provider default")
    func blankClearsRename() {
        var settings = GNOMESettings()
        settings.renameProvider("claude", to: "Claude Work")

        settings.renameProvider("claude", to: " \n ")

        #expect(settings.providerRenames["claude"] == nil)
        #expect(settings.displayName(providerID: "claude", fallback: "Claude") == "Claude")
    }

    @Test("Snapshot rename preserves account metrics and stale state")
    func snapshotProjection() {
        var settings = GNOMESettings()
        settings.renameProvider("claude", to: "Claude Work")
        let original = ProviderUsageSnapshot(
            providerID: "claude",
            instanceID: "claude-team",
            displayName: "Claude",
            accountLabel: "Team",
            plan: "Max",
            metrics: [
                UsageMetric(kind: .progress, label: "Weekly", used: 90, limit: 100),
            ],
            links: [],
            refreshedAt: Date(timeIntervalSince1970: 0),
            errorMessage: "Offline",
            warning: "Near limit"
        )

        let renamed = original.applyingProviderRenames(settings.providerRenames)

        #expect(renamed.displayName == "Claude Work")
        #expect(renamed.providerID == original.providerID)
        #expect(renamed.instanceID == original.instanceID)
        #expect(renamed.accountLabel == original.accountLabel)
        #expect(renamed.plan == original.plan)
        #expect(renamed.metrics == original.metrics)
        #expect(renamed.warning == original.warning)
        #expect(renamed.errorMessage == original.errorMessage)
    }
}
