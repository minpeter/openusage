#if os(Linux)
import Foundation

public enum LinuxPricingResources {
    public static func data(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public static func providerIconURL(for providerID: String) -> URL? {
        Bundle.module.url(
            forResource: "\(providerID)-symbolic",
            withExtension: "svg",
            subdirectory: "ProviderIcons"
        )
    }
}
#endif
