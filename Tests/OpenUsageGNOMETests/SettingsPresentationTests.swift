import Foundation
import OpenUsageLinuxCore
import Testing
@testable import OpenUsageGNOME

@Suite("GNOME settings presentation")
struct SettingsPresentationTests {
    @Test("Providers default to metric customization and keep order available")
    func providersSectionSwitcher() {
        #expect(SettingsProvidersPresentation.defaultSection == .metrics)
        #expect(SettingsProvidersPresentation.sectionTitles == [
            "Metric Customization",
            "Provider Order",
        ])
        #expect(SettingsProvidersPresentation.isVisible(
            .metrics,
            selected: .metrics
        ))
        #expect(!SettingsProvidersPresentation.isVisible(
            .order,
            selected: .metrics
        ))
        #expect(SettingsProvidersPresentation.isVisible(
            .order,
            selected: .order
        ))
    }

    @Test("Unavailable screen-share privacy is hidden instead of shown disabled")
    func screenShareRowIsHidden() {
        #expect(!SettingsScreenSharePresentation.showsUnavailableRow)
    }

    @Test("Metric rows state visibility only in the combo, not the subtitle")
    func metricSubtitleOmitsVisibility() {
        #expect(SettingsMetricPresentation.rowSubtitle(kind: .progress) == "Progress")
        #expect(SettingsMetricPresentation.rowSubtitle(kind: .value) == "Value")
        #expect(!SettingsMetricPresentation.rowSubtitle(kind: .progress)
            .contains(MetricVisibilitySection.alwaysVisible.label))
    }

    @Test("Panel-only settings stay hidden when there is no tray surface")
    func panelControlsAreHidden() {
        #expect(!SettingsPanelPresentation.showsPanelControls)
        #expect(
            SettingsPanelPresentation.metricCustomizationDescription()
                == "Enable, order, and reveal metrics on demand for each provider."
        )
        #expect(!SettingsPanelPresentation.metricCustomizationDescription().localizedCaseInsensitiveContains("pin"))
        #expect(
            SettingsPanelPresentation.usageDisplayDescription()
                == "Control quota values, reset copy, and pacing."
        )
        #expect(!SettingsPanelPresentation.usageDisplayDescription().localizedCaseInsensitiveContains("panel"))
        #expect(
            SettingsPanelPresentation.metricProviderSubtitle(metricCount: 4, pinnedCount: 0)
                == "4 metrics"
        )
    }

    @Test("API key Clear is enabled only when a key is stored")
    func clearRequiresStoredKey() {
        #expect(SettingsAPIKeyPresentation.clearIsEnabled(status: "Stored"))
        #expect(!SettingsAPIKeyPresentation.clearIsEnabled(status: "Not Stored"))
        #expect(!SettingsAPIKeyPresentation.clearIsEnabled(status: "Checking…"))
        #expect(!SettingsAPIKeyPresentation.clearIsEnabled(status: "Saving…"))
        #expect(!SettingsAPIKeyPresentation.clearIsEnabled(status: "Clearing…"))
        #expect(!SettingsAPIKeyPresentation.clearIsEnabled(status: "Secret Service Unavailable"))
    }

    @Test("Anonymous usage is off until the user opts in")
    func analyticsDefaultOff() {
        #expect(!SettingsAnalyticsPresentation.defaultEnabled)
        #expect(!SettingsAnalyticsPresentation.isEnabled(nil))
        #expect(!SettingsAnalyticsPresentation.isEnabled(false))
        #expect(SettingsAnalyticsPresentation.isEnabled(true))
    }

    @Test("Settings dialog close policy ignores scroll, backdrop, and tab switches")
    func dialogClosePolicy() {
        #expect(!SettingsDialogClosePolicy.usesFloatingPresentation)
        #expect(SettingsDialogClosePolicy.allowsClose(from: .headerCloseButton))
        #expect(SettingsDialogClosePolicy.allowsClose(from: .escape))
        #expect(SettingsDialogClosePolicy.allowsClose(from: .explicitClose))
        #expect(!SettingsDialogClosePolicy.allowsClose(from: .scroll))
        #expect(!SettingsDialogClosePolicy.allowsClose(from: .backdropClick))
        #expect(!SettingsDialogClosePolicy.allowsClose(from: .tabSwitch))
        #expect(!SettingsDialogClosePolicy.allowsClose(from: .contentClick))
    }

    @Test("Shortcut rows render the actual key combo")
    func shortcutDisplayText() {
        #expect(SettingsShortcutPresentation.displayText(accelerator: "<Control>r") == "Ctrl+R")
        #expect(SettingsShortcutPresentation.displayText(accelerator: "<Control>1") == "Ctrl+1")
        #expect(SettingsShortcutPresentation.displayText(accelerator: "<Control>comma") == "Ctrl+,")
        #expect(SettingsShortcutPresentation.displayText(accelerator: "<Control>q") == "Ctrl+Q")
    }

    @Test("Overview and Settings share Most Urgent Quotas")
    func mostUrgentCopyIsShared() {
        #expect(UsageUrgencyCopy.mostUrgent == "Most Urgent Quotas")
        #expect(UsageUrgencyCopy.mostUrgent != "Most Urgent Usage")
    }
}
