import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Section rows

extension OverviewView {
    func spendRow(_ entry: (String, Double)) -> Widget {
        let row = ActionRow(title: entry.0)
        let value = Label(GNOMEFormat.currency(entry.1))
        value.addCSSClass(.numeric)
        value.addCSSClass(.heading)
        value.valign = GTK_ALIGN_CENTER
        row.addSuffix(value)
        return row
    }

    func urgentRow(_ entry: (provider: String, metric: UsageMetric)) -> Widget {
        let presentation = metricPresentationSettings.presentation(for: entry.metric)
        let wrapper = Box(orientation: GTK_ORIENTATION_VERTICAL, spacing: 0)
        let row = ActionRow(title: entry.metric.label)
        row.subtitle = [entry.provider, presentation.pacingText]
            .compactMap { $0 }
            .joined(separator: " · ")

        let trailing = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)
        trailing.valign = GTK_ALIGN_CENTER
        if let resetText = presentation.resetText {
            let resetLabel = Label(resetText)
            resetLabel.addCSSClass(.caption)
            resetLabel.addCSSClass(.dimLabel)
            trailing.append(resetLabel)
        }
        let value = Label(presentation.valueText)
        value.addCSSClass(.numeric)
        trailing.append(value)
        row.addSuffix(trailing)

        if let fraction = entry.metric.fraction {
            let bar = ProgressBar()
            bar.fraction = fraction
            bar.setMargins(GNOMEStyle.sectionSpacing)
            bar.marginTop = 0
            bar.setAccessibleLabel("\(entry.provider) \(entry.metric.label)")
            bar.setAccessibleDescription(presentation.valueText)
            if fraction >= 0.9 {
                bar.addCSSClass(.error)
            } else if fraction >= 0.8 {
                bar.addCSSClass(.warning)
            }
            wrapper.append(row)
            wrapper.append(bar)
            return wrapper
        }
        return row
    }

    func healthRow(_ snapshot: ProviderUsageSnapshot) -> Widget {
        let row = ActionRow(title: snapshot.displayName)
        row.addPrefix(ProviderIcon.make(
            providerID: snapshot.providerID,
            displayName: snapshot.displayName
        ))

        let stale = snapshot.errorMessage != nil && !snapshot.metrics.isEmpty
        let failing = snapshot.errorMessage != nil && snapshot.metrics.isEmpty

        if failing {
            row.subtitle = actionableError(providerID: snapshot.providerID,
                                           message: snapshot.errorMessage ?? "")
        } else if stale {
            row.subtitle = "Stale - \(GNOMEFormat.relativeRefresh(snapshot.refreshedAt).lowercased())"
        } else if let warning = snapshot.warning {
            row.subtitle = warning
        } else {
            row.subtitle = snapshot.accountLabel
                ?? GNOMEFormat.relativeRefresh(snapshot.refreshedAt)
        }

        let trailing = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: GNOMEStyle.controlSpacing)
        trailing.valign = GTK_ALIGN_CENTER

        let status = Image()
        if failing {
            status.iconName = "dialog-error-symbolic"
            status.addCSSClass(.error)
            status.setAccessibleLabel("Error")
        } else if stale || snapshot.warning != nil {
            status.iconName = "dialog-warning-symbolic"
            status.addCSSClass(.warning)
            status.setAccessibleLabel("Warning")
        } else {
            status.visible = false
            status.setAccessibleLabel("Up to date")
        }
        trailing.append(status)

        if failing {
            let retry = Button(label: "Retry", onClicked: { [weak self] in self?.onRefresh() })
            retry.addCSSClass(.flat)
            retry.valign = GTK_ALIGN_CENTER
            retry.setAccessibleLabel("Retry refreshing \(snapshot.displayName)")
            trailing.append(retry)
        }
        row.addSuffix(trailing)
        return row
    }

    func actionableError(providerID: String, message: String) -> String {
        if providerID == "claude", message.contains("credentials were not found") {
            return "Sign in with Claude Code, then refresh."
        }
        if providerID == "codex", message.contains("HTTP 401") {
            return "Codex session expired - sign in again, then refresh."
        }
        return message
    }

    func replaceRows(in group: PreferencesGroup, rows: [Widget]) {
        while let existing = group.getRow(0) {
            group.remove(existing)
        }
        for row in rows {
            group.add(row)
        }
    }
}
