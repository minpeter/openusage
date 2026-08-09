import Testing
@testable import OpenUsageLinuxCore

@Suite("Linux update delivery")
struct LinuxUpdateDeliveryTests {
    @Test("Flatpak installs delegate updates to the software center")
    func flatpakUpdatesUseSoftwareCenter() {
        let policy = LinuxUpdateDelivery(environment: [
            "FLATPAK_ID": "io.github.minpeter.OpenUsage"
        ])

        #expect(policy.channel == .flatpak)
        #expect(policy.isManaged)
        #expect(policy.userMessage.contains("Software"))
    }

    @Test("Distribution packages never self-update")
    func packageUpdatesRemainUnprivileged() {
        let policy = LinuxUpdateDelivery(environment: [:])

        #expect(policy.channel == .packageManager)
        #expect(policy.isManaged)
        #expect(!policy.supportsInApplicationInstall)
    }
}
