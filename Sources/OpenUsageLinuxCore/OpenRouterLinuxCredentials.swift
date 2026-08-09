import Foundation

extension OpenRouterLinuxProvider {
    public static let environmentNames = ["OPENROUTER_API_KEY", "OPENROUTER_KEY"]
    public static let configPaths = ["~/.config/openusage/openrouter.json", "~/.config/openrouter/key.json"]

    public static func defaultKeySource(
        secretService: (any ProviderAPIKeySource)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CompositeAPIKeySource {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        var sources: [any ProviderAPIKeySource] = []
        if let secretService { sources.append(secretService) }
        sources.append(FileAPIKeySource(urls: [
            home.appendingPathComponent(".config/openusage/openrouter.json"),
            home.appendingPathComponent(".config/openrouter/key.json"),
        ]))
        sources.append(EnvironmentAPIKeySource(names: environmentNames, environment: environment))
        return CompositeAPIKeySource(sources: sources)
    }

}
