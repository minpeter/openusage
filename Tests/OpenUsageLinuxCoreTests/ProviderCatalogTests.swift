import Testing
@testable import OpenUsageLinuxCore

@Suite("Provider catalog")
struct ProviderCatalogTests {
    @Test("Catalog covers every current Swift provider")
    func catalogCoversEveryProvider() {
        #expect(Set(ProviderCatalog.entries.map(\.id)) == [
            "antigravity",
            "claude",
            "codex",
            "copilot",
            "cursor",
            "devin",
            "grok",
            "opencode",
            "openrouter",
            "pi",
            "zai",
        ])
        #expect(ProviderCatalog.entries.map(\.id).count == Set(ProviderCatalog.entries.map(\.id)).count)
        #expect(ProviderCatalog.cardEntries.allSatisfy { !$0.isFoldIn })
    }
}
