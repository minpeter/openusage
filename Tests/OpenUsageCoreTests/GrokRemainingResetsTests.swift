import Foundation
import OpenUsageCore
import Testing

@Suite("Grok remaining usage-limit resets")
struct GrokRemainingResetsTests {
    /// Captured 2026-08-13 from a SuperGrok Heavy account: one reset token
    /// `restok_vpYDqo` valid 2026-08-13T18:49:00Z → 2026-09-12T18:49:00Z.
    private static let liveGrpcWebResponse = Data([
        0x00, 0x00, 0x00, 0x00, 0x23,
        0x52, 0x21, 0x52, 0x0D, 0x72, 0x65, 0x73, 0x74, 0x6F, 0x6B, 0x5F,
        0x76, 0x70, 0x59, 0x44, 0x71, 0x6F,
        0xA2, 0x01, 0x06, 0x08, 0x9C, 0x80, 0xF3, 0xD3, 0x06,
        0xF2, 0x01, 0x06, 0x08, 0x9C, 0xBD, 0x96, 0xD5, 0x06,
        0x80, 0x00, 0x00, 0x00, 0x0F,
        0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A
    ])

    @Test("live grpc-web fixture decodes one unexpired reset")
    func liveFixture() throws {
        let now = Date(timeIntervalSince1970: 1_786_536_000) // 2026-08-13T12:00:00Z
        let snapshot = try #require(GrokRemainingResets.decode(grpcWeb: Self.liveGrpcWebResponse, now: now))

        #expect(snapshot.tokens.map(\.tokenID) == ["restok_vpYDqo"])
        #expect(snapshot.tokens.first?.validFrom == Date(timeIntervalSince1970: 1_786_560_540))
        #expect(snapshot.tokens.first?.expiresAt == Date(timeIntervalSince1970: 1_789_238_940))
        #expect(snapshot.availableCount == 1)
        #expect(snapshot.availableExpiries == [Date(timeIntervalSince1970: 1_789_238_940)])
    }

    @Test("expired tokens are not counted as available")
    func expiredTokens() throws {
        let afterExpiry = Date(timeIntervalSince1970: 1_789_257_600) // 2026-09-13T00:00:00Z
        let snapshot = try #require(GrokRemainingResets.decode(grpcWeb: Self.liveGrpcWebResponse, now: afterExpiry))

        #expect(snapshot.tokens.count == 1)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.availableExpiries.isEmpty)
    }

    @Test("empty protobuf message means zero resets")
    func emptyMessage() throws {
        let snapshot = try #require(GrokRemainingResets.decode(grpcWeb: GrokRemainingResets.emptyRequest, now: Date()))

        #expect(snapshot.tokens.isEmpty)
        #expect(snapshot.availableCount == 0)
        #expect(snapshot.availableExpiries.isEmpty)
    }

    @Test("non-2xx HTTP omits the snapshot (Codex-consistent missing-field)")
    func nonSuccessOmitsRow() {
        #expect(GrokRemainingResets.snapshot(httpStatus: 404, body: Self.liveGrpcWebResponse) == nil)
        #expect(GrokRemainingResets.snapshot(httpStatus: 500, body: Data()) == nil)
    }

    @Test("malformed body omits the snapshot")
    func malformedOmitsRow() {
        #expect(GrokRemainingResets.decode(grpcWeb: Data("not protobuf".utf8)) == nil)
        #expect(GrokRemainingResets.snapshot(httpStatus: 200, body: Data([0x00, 0x00, 0x00, 0xFF])) == nil)
    }

    @Test("non-zero grpc-status trailer omits the snapshot")
    func grpcErrorOmitsRow() {
        // Empty data frame + trailer `grpc-status:16` (unauthenticated).
        let body = Data([
            0x00, 0x00, 0x00, 0x00, 0x00,
            0x80, 0x00, 0x00, 0x00, 0x10,
        ]) + Data("grpc-status:16\r\n".utf8)
        #expect(GrokRemainingResets.decode(grpcWeb: body) == nil)
        #expect(GrokRemainingResets.snapshot(httpStatus: 200, body: body) == nil)
    }

    @Test("2xx empty body is zero available, not a miss")
    func successZero() throws {
        let snapshot = try #require(GrokRemainingResets.snapshot(
            httpStatus: 200,
            body: GrokRemainingResets.emptyRequest
        ))
        #expect(snapshot.availableCount == 0)
    }
}
