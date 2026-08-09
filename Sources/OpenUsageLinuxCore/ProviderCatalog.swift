public struct ProviderCatalogEntry: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let isFoldIn: Bool

    public init(id: String, displayName: String, isFoldIn: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.isFoldIn = isFoldIn
    }
}

public enum ProviderCatalog {
    public static let entries = [
        ProviderCatalogEntry(id: "claude", displayName: "Claude"),
        ProviderCatalogEntry(id: "codex", displayName: "Codex"),
        ProviderCatalogEntry(id: "cursor", displayName: "Cursor"),
        ProviderCatalogEntry(id: "copilot", displayName: "GitHub Copilot"),
        ProviderCatalogEntry(id: "antigravity", displayName: "Antigravity"),
        ProviderCatalogEntry(id: "opencode", displayName: "OpenCode"),
        ProviderCatalogEntry(id: "openrouter", displayName: "OpenRouter"),
        ProviderCatalogEntry(id: "grok", displayName: "Grok"),
        ProviderCatalogEntry(id: "zai", displayName: "Z.ai"),
        ProviderCatalogEntry(id: "devin", displayName: "Devin"),
        ProviderCatalogEntry(id: "pi", displayName: "Pi", isFoldIn: true),
    ]

    public static var cardEntries: [ProviderCatalogEntry] {
        entries.filter { !$0.isFoldIn }
    }
}
