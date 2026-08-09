import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DevinLinuxClient: Sendable {
    public static let cloudService = "exa.seat_management_pb.SeatManagementService"
    public static let cloudCompatVersion = "1.108.2"
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func userStatus(credential: DevinCredential) async throws -> HTTPResult {
        guard let url = URL(string: "\(credential.effectiveAPIServerURL)/\(Self.cloudService)/GetUserStatus") else {
            throw DevinLinuxError.invalidResponse
        }
        let body: [String: Any] = ["metadata": [
            "apiKey": credential.apiKey,
            "ideName": "devin",
            "ideVersion": Self.cloudCompatVersion,
            "extensionName": "devin",
            "extensionVersion": Self.cloudCompatVersion,
            "locale": "en",
        ]]
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        return try await transport.execute(request)
    }
}
