import Foundation
@testable import OpenUsage

/// Builders and a captured payload for Grok's `/v1/billing?format=credits` JSON response, shared by
/// the decoder/mapper tests and the provider-level tests.
enum GrokCreditsFixtures {
    /// A real response captured live from cli-chat-proxy.grok.com on 2026-07-06 (percent edited to a
    /// nonzero value; proto-JSON omits it at 0). Includes fields we don't map, which exercises
    /// unknown-field tolerance on a genuine payload.
    static let capturedResponseBody = Data("""
    {"config":{"creditUsagePercent":99.0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY",\
    "start":"2026-06-30T21:36:52.140114+00:00","end":"2026-07-07T21:36:52.140114+00:00"},\
    "onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true,\
    "prepaidBalance":{"val":0},"topUpMethod":"TOP_UP_METHOD_SAVED_PAYMENT_METHOD",\
    "billingPeriodStart":"2026-06-30T21:36:52.140114+00:00",\
    "billingPeriodEnd":"2026-07-07T21:36:52.140114+00:00"}}
    """.utf8)

    static let capturedPeriodStart = Date(timeIntervalSince1970: 1_782_855_412 + 0.140114)
    static let capturedPeriodEnd = Date(timeIntervalSince1970: 1_783_460_212 + 0.140114)

    /// A synthetic response body with the fields the decoder reads, for shaping edge cases.
    /// Pass `percent: nil` to omit the field the way proto-JSON does for 0.
    /// Pass `percent: nil` / `onDemandCap: nil` to omit the fields the way proto-JSON does for 0.
    static func responseBody(
        periodType: String = "USAGE_PERIOD_TYPE_WEEKLY",
        percent: Any? = 99.0,
        onDemandCap: Any? = nil,
        start: String = "2026-06-30T21:36:52.140114+00:00",
        end: String = "2026-07-07T21:36:52.140114+00:00"
    ) -> Data {
        var config: [String: Any] = [
            "currentPeriod": ["type": periodType, "start": start, "end": end],
            "isUnifiedBillingUser": true
        ]
        if let percent {
            config["creditUsagePercent"] = percent
        }
        if let onDemandCap {
            config["onDemandCap"] = ["val": onDemandCap]
        }
        return try! JSONSerialization.data(withJSONObject: ["config": config])
    }
}

/// Live grpc-web `GetRemainingResets` body captured 2026-08-13 from SuperGrok Heavy.
enum GrokRemainingResetsFixtures {
    static let oneAvailableToken = Data([
        0x00, 0x00, 0x00, 0x00, 0x23,
        0x52, 0x21, 0x52, 0x0D, 0x72, 0x65, 0x73, 0x74, 0x6F, 0x6B, 0x5F,
        0x76, 0x70, 0x59, 0x44, 0x71, 0x6F,
        0xA2, 0x01, 0x06, 0x08, 0x9C, 0x80, 0xF3, 0xD3, 0x06,
        0xF2, 0x01, 0x06, 0x08, 0x9C, 0xBD, 0x96, 0xD5, 0x06,
        0x80, 0x00, 0x00, 0x00, 0x0F,
        0x67, 0x72, 0x70, 0x63, 0x2D, 0x73, 0x74, 0x61, 0x74, 0x75, 0x73, 0x3A, 0x30, 0x0D, 0x0A
    ])
}
