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
        #expect(LinuxDurationFormat.period(milliseconds: 30 * 86_400_000) == "30 days")
    }

    @Test("Raw millisecond period copy is never forwarded")
    func sanitizesRawMillisecondPeriods() {
        #expect(LinuxDurationFormat.displayDetail("604800000 ms period") == "1 week")
        #expect(LinuxDurationFormat.displayDetail("86400000 ms period") == "1 day")
        #expect(LinuxDurationFormat.containsRawMillisecondPeriod("604800000 ms period"))
        #expect(LinuxDurationFormat.displayDetail("From local logs") == "From local logs")
        #expect(!LinuxDurationFormat.containsRawMillisecondPeriod("1 week"))
    }
}
