import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CopilotLinuxClient {
    public static let usageURL = URL(string: "https://api.github.com/copilot_internal/user")!
    public static let userOrgsURL = URL(string: "https://api.github.com/user/orgs?per_page=100")!

    public static func usageRequest(token: String) throws -> URLRequest {
        request(url: usageURL, token: token, usageHeaders: true)
    }

    public static func organizationsRequest(token: String) -> URLRequest {
        request(url: userOrgsURL, token: token, usageHeaders: false)
    }

    public static func organizationBillingRequest(org: String, token: String) throws -> URLRequest {
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
        else { throw CopilotLinuxError.invalidResponse }
        return request(url: url, token: token, usageHeaders: false)
    }

    private static func request(url: URL, token: String, usageHeaders: Bool) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        if usageHeaders {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
            request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
            request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
            request.setValue("2025-04-01", forHTTPHeaderField: "X-Github-Api-Version")
        } else {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("OpenUsage", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return request
    }
}
