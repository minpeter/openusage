import Foundation
#if canImport(FoundationNetworking)
@_exported import FoundationNetworking
#endif

public struct HTTPResult: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> HTTPResult
}

public enum UsageRequests {
    private static let codexClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public static func claude(accessToken: String) throws -> URLRequest {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw LinuxUsageError.invalidResponse("Claude")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.69", forHTTPHeaderField: "User-Agent")
        return request
    }

    public static func codex(credentials: CodexCredentials) throws -> URLRequest {
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            throw LinuxUsageError.invalidResponse("Codex")
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("openusage-linux", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return request
    }

    public static func codexRefresh(refreshToken: String) throws -> URLRequest {
        guard let url = URL(string: "https://auth.openai.com/oauth/token") else {
            throw LinuxUsageError.invalidResponse("Codex")
        }
        let body = [
            "grant_type=refresh_token",
            "client_id=\(formEncoded(codexClientID))",
            "refresh_token=\(formEncoded(refreshToken))",
        ].joined(separator: "&")
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    private static func formEncoded(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
