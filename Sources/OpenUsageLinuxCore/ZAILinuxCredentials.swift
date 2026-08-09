import Foundation

extension ZAILinuxProvider {
    public static let environmentNames = ["ZAI_API_KEY", "GLM_API_KEY"]
    public static let configPaths = ["~/.config/openusage/zai.json", "~/.config/zai/key.json"]

    public static func defaultKeySource(
        secretService: (any ProviderAPIKeySource)? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CompositeAPIKeySource {
        let home = environment["HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        var sources: [any ProviderAPIKeySource] = []
        if let secretService { sources.append(secretService) }
        sources.append(FileAPIKeySource(urls: [
            home.appendingPathComponent(".config/openusage/zai.json"),
            home.appendingPathComponent(".config/zai/key.json"),
        ]))
        sources.append(EnvironmentAPIKeySource(names: environmentNames, environment: environment))
        return CompositeAPIKeySource(sources: sources)
    }

}
