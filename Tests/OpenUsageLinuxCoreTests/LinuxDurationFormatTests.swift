import Foundation
import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux duration format")
struct LinuxDurationFormatTests {
    @Test("Canonical quota windows stay human-readable")
    func canonicalWindows() {
        #expect(LinuxDurationFormat.period(milliseconds: 5 * 60 * 60 * 1_000) == "5 hours")
        #expect(LinuxDurationFormat.period(milliseconds: 86_400_000) == "1 day")
        #expect(LinuxDurationFormat.period(milliseconds: 604_800_000) == "1 week")
        #expect(LinuxDurationFormat.period(milliseconds: 604_799_600) == "1 week")
        #expect(LinuxDurationFormat.period(milliseconds: 30 * 86_400_000) == "30 days")
    }

    @Test("Raw millisecond period copy is never forwarded")
    func sanitizesRawMillisecondPeriods() {
        #expect(LinuxDurationFormat.displayDetail("604800000 ms period") == "1 week")
        #expect(LinuxDurationFormat.displayDetail("86400000 ms period") == "1 day")
        #expect(LinuxDurationFormat.containsRawMillisecondPeriod("604800000 ms period"))
        #expect(LinuxDurationFormat.displayDetail("From local logs") == "From local logs")
        #expect(!LinuxDurationFormat.containsRawMillisecondPeriod("1 week"))
        #expect(LinuxDurationFormat.displayDetail("percent") == nil)
        #expect(LinuxDurationFormat.displayDetail("dollars") == nil)
        #expect(LinuxDurationFormat.displayDetail("requests") == nil)
        #expect(LinuxDurationFormat.displayDetail("#22c55e") == nil)
        #expect(LinuxDurationFormat.displayDetail("Includes Cursor Grok and Composer") == "Includes Cursor Grok and Composer")
        #expect(LinuxDurationFormat.displayDetail("12 credits") == "12 credits")
    }
}
