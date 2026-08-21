import Foundation
import OpenUsageLinuxCore

enum SettingsProvidersSection: String, CaseIterable, Sendable {
    case metrics
    case order

    var title: String {
        switch self {
        case .metrics: "Metric Customization"
        case .order: "Provider Order"
        }
    }
}

enum SettingsProvidersPresentation {
    static let defaultSection = SettingsProvidersSection.metrics
    static let sectionTitles = SettingsProvidersSection.allCases.map(\.title)

    static func showsEmptyOrderBanner(order: [String]) -> Bool {
        order.isEmpty
    }

    static func isVisible(
        _ section: SettingsProvidersSection,
        selected: SettingsProvidersSection
    ) -> Bool {
        section == selected
    }
}

enum SettingsPanelPresentation {
    /// StatusNotifierItem still applies persisted pins when a watcher exists,
    /// but GNOME Settings does not advertise panel/tray chrome.
    static let showsPanelControls = false

    static func metricCustomizationDescription(
        showsPanelControls: Bool = Self.showsPanelControls
    ) -> String {
        if showsPanelControls {
            return "Enable, order, reveal on demand, and pin up to two metrics per provider."
        }
        return "Enable, order, and reveal metrics on demand for each provider."
    }

    static func usageDisplayDescription(
        showsPanelControls: Bool = Self.showsPanelControls
    ) -> String {
        if showsPanelControls {
            return "Control quota values, reset copy, pacing, and top-panel presentation."
        }
        return "Control quota values, reset copy, and pacing."
    }

    static func metricProviderSubtitle(
        metricCount: Int,
        pinnedCount: Int,
        showsPanelControls: Bool = Self.showsPanelControls
    ) -> String {
        if showsPanelControls {
            return "\(metricCount) metrics · \(pinnedCount) pinned"
        }
        return "\(metricCount) metrics"
    }
}

enum SettingsMetricPresentation {
    static func rowSubtitle(kind: UsageMetric.Kind) -> String {
        kind.rawValue.capitalized
    }
}

enum SettingsScreenSharePresentation {
    /// No GNOME/Wayland API exposes global capture state or capture exclusion.
    static let showsUnavailableRow = false
}

enum SettingsAPIKeyPresentation {
    static func clearIsEnabled(status: String) -> Bool {
        status == "Stored"
    }
}

enum SettingsAnalyticsPresentation {
    static let defaultEnabled = false

    static func isEnabled(_ stored: Bool?) -> Bool {
        stored ?? defaultEnabled
    }
}

enum SettingsShortcutPresentation {
    static func displayText(accelerator: String) -> String {
        var remainder = accelerator
        var parts: [String] = []
        let modifiers = [
            ("<Primary>", "Ctrl"),
            ("<Control>", "Ctrl"),
            ("<Ctrl>", "Ctrl"),
            ("<Shift>", "Shift"),
            ("<Alt>", "Alt"),
            ("<Super>", "Super"),
        ]
        for (token, label) in modifiers where remainder.contains(token) {
            parts.append(label)
            remainder = remainder.replacingOccurrences(of: token, with: "")
        }
        remainder = remainder.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        parts.append(keyDisplayName(remainder))
        return parts.joined(separator: "+")
    }

    private static func keyDisplayName(_ key: String) -> String {
        switch key.lowercased() {
        case "comma": ","
        case "period": "."
        case "slash": "/"
        case "minus": "-"
        case "equal": "="
        case let value where value.count == 1: value.uppercased()
        default: key.capitalized
        }
    }
}

enum SettingsDialogClosePolicy {
    /// Floating presentation avoids bottom-sheet swipe-to-dismiss from scrolling.
    static let usesFloatingPresentation = true

    enum CloseSource: String, Sendable {
        case headerCloseButton
        case escape
        case explicitClose
        case scroll
        case backdropClick
        case tabSwitch
        case contentClick
    }

    static func allowsClose(from source: CloseSource) -> Bool {
        switch source {
        case .headerCloseButton, .escape, .explicitClose:
            true
        case .scroll, .backdropClick, .tabSwitch, .contentClick:
            false
        }
    }
}

enum UsageUrgencyCopy {
    static let mostUrgent = "Most Urgent Quotas"
}
