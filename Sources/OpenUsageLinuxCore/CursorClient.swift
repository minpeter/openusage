import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CursorLinuxClient {
    public static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    public static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    public static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    public static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    public static let requestUsageURL = URL(string: "https://cursor.com/api/usage")!
    public static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    public static let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!
    public static let exportCSVURL = URL(string: "https://cursor.com/api/dashboard/export-usage-events-csv")!
    private static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    public static func usageRequest(accessToken: String) throws -> URLRequest {
        connectRequest(url: usageURL, accessToken: accessToken)
    }

    public static func planRequest(accessToken: String) -> URLRequest { connectRequest(url: planURL, accessToken: accessToken) }
    public static func creditsRequest(accessToken: String) -> URLRequest { connectRequest(url: creditsURL, accessToken: accessToken) }

    public static func refreshRequest(refreshToken: String) throws -> URLRequest {
        var request = URLRequest(url: refreshURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken,
        ])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    public static func requestUsageRequest(accessToken: String) -> URLRequest? {
        guard let session = session(accessToken) else { return nil }
        var components = URLComponents(url: requestUsageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
        guard let url = components?.url else { return nil }
        return cookieRequest(url: url, sessionToken: session.token)
    }

    public static func usageSummaryRequest(accessToken: String) -> URLRequest? {
        guard let session = session(accessToken) else { return nil }
        return cookieRequest(url: usageSummaryURL, sessionToken: session.token)
    }

    public static func stripeRequest(accessToken: String) -> URLRequest? {
        guard let session = session(accessToken) else { return nil }
        return cookieRequest(url: stripeURL, sessionToken: session.token)
    }

    public static func exportCSVRequest(accessToken: String, start: Date, end: Date) -> URLRequest? {
        guard let session = session(accessToken) else { return nil }
        var components = URLComponents(url: exportCSVURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "startDate", value: String(Int(start.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "endDate", value: String(Int(end.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "strategy", value: "tokens"),
        ]
        guard let url = components?.url else { return nil }
        var request = cookieRequest(url: url, sessionToken: session.token, timeout: 30)
        request.setValue("text/csv", forHTTPHeaderField: "Accept")
        return request
    }

    private static func connectRequest(url: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return request
    }

    private static func cookieRequest(url: URL, sessionToken: String, timeout: TimeInterval = 10) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("WorkosCursorSessionToken=\(sessionToken)", forHTTPHeaderField: "Cookie")
        return request
    }

    private static func session(_ token: String) -> (userID: String, token: String)? {
        guard let userID = CursorLinuxCredentialStore.accountLabel(token) else { return nil }
        return (userID, "\(userID)%3A%3A\(token)")
    }
}
