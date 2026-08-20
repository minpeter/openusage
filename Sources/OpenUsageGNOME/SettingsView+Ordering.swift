import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Provider ordering

enum SettingsProvidersPresentation {
    static func showsEmptyOrderBanner(order: [String]) -> Bool {
        order.isEmpty
    }
}

extension SettingsView {
    func rebuildOrderRows() {
        orderConnections.forEach { $0.disconnect() }
        orderConnections.removeAll(keepingCapacity: true)
        providerRows.removeAll(keepingCapacity: true)
        removeTrackedRows(orderRowWidgets, from: orderGroup)
        orderRowWidgets.removeAll(keepingCapacity: true)

        guard !SettingsProvidersPresentation.showsEmptyOrderBanner(order: order) else {
            let empty = ActionRow(
                title: "No Providers Yet",
                subtitle: "Provider ordering appears after the first refresh."
            )
            orderGroup.add(empty)
            orderRowWidgets.append(empty)
            return
        }
        for (index, id) in order.enumerated() {
            let row = SwitchRow(title: providerNames[id] ?? id)
            row.subtitle = "Position \(index + 1) of \(order.count)"
            row.active = !hiddenProviderIDs.contains(id)
            row.addPrefix(ProviderIcon.make(
                providerID: id,
                displayName: providerNames[id] ?? id,
                size: 24
            ))
            providerRows[id] = row
            orderConnections.append(row.onNotify(.active) { [weak self] in
                guard let self, let row = self.providerRows[id], !self.applyingSettings else { return }
                if row.active {
                    self.hiddenProviderIDs.remove(id)
                } else {
                    self.hiddenProviderIDs.insert(id)
                }
                self.onProviderVisibilityChanged(id, row.active)
            })

            row.addSuffix(reorderMenu(
                label: providerNames[id] ?? id,
                canMoveUp: index > 0,
                canMoveDown: index < order.count - 1,
                onMove: { [weak self] delta in self?.move(id, by: delta) }
            ))
            orderGroup.add(row)
            orderRowWidgets.append(row)
        }
    }

    func move(_ id: String, by offset: Int) {
        guard let from = order.firstIndex(of: id) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        onProviderOrderChanged(order)
        rebuildOrderRows()
    }

    func shortcutRow(title: String, accelerator: String) -> Widget {
        let row = ActionRow(title: title)
        if let label = ShortcutLabel(accelerator: accelerator) {
            label.valign = GTK_ALIGN_CENTER
            row.addSuffix(label)
        }
        return row
    }

    func rebuildMetricCustomizationRows() {
        metricConnections.forEach { $0.disconnect() }
        metricConnections.removeAll(keepingCapacity: true)
        removeTrackedRows(metricHeaderRows, from: metricCustomizationGroup)
        metricHeaderRows.removeAll(keepingCapacity: true)

        let providers = customizationProviders()
        let visibleIDs = Set(providers.map(\.id))
        for (id, group) in metricProviderGroups where !visibleIDs.contains(id) {
            removeTrackedRows(metricGroupRows[id] ?? [], from: group)
            metricGroupRows[id] = []
            group.visible = false
        }

        guard !providers.isEmpty else {
            for group in metricProviderGroups.values {
                group.visible = false
            }
            let empty = ActionRow(
                title: "No Metrics Yet",
                subtitle: "Metric controls appear after the first refresh."
            )
            metricCustomizationGroup.add(empty)
            metricHeaderRows.append(empty)
            return
        }

        for provider in providers {
            var layout = customizationSettings.metricLayouts[provider.id] ?? .init()
            layout.reconcile(with: provider.metrics)
            let subtitle = "\(provider.metrics.count) metrics · "
                + "\(customizationSettings.panelMetricPins.pins(for: provider.id).count) pinned"
            let group: PreferencesGroup
            if let existing = metricProviderGroups[provider.id] {
                group = existing
            } else {
                group = PreferencesGroup(title: provider.name, description: subtitle)
                metricProviderGroups[provider.id] = group
                providersPage.add(group)
            }
            group.title = provider.name
            group.description = subtitle
            group.visible = true
            removeTrackedRows(metricGroupRows[provider.id] ?? [], from: group)
            var rows: [Widget] = []

            for (index, metric) in provider.metrics.enumerated() {
                let key = MetricPreferenceKey(metric: metric)
                guard let entry = layout.entry(for: key) else { continue }
                let enabled = SwitchRow(
                    title: metric.label,
                    subtitle: "\(metric.kind.rawValue.capitalized) · \(entry.section.label)"
                )
                enabled.active = entry.isEnabled
                enabled.addPrefix(ProviderIcon.make(
                    providerID: provider.id,
                    displayName: provider.name,
                    size: 20
                ))

                enabled.addSuffix(reorderMenu(
                    label: metric.label,
                    canMoveUp: index > 0,
                    canMoveDown: index < provider.metrics.count - 1,
                    onMove: { [weak self] delta in
                        self?.onMetricMoved(provider.id, key, delta)
                    }
                ))
                metricConnections.append(enabled.onNotify(.active) { [weak self, weak enabled] in
                    guard let self, let enabled, !self.applyingSettings else { return }
                    self.onMetricEnabledChanged(provider.id, key, enabled.active)
                })
                group.add(enabled)
                rows.append(enabled)

                let visibility = ComboRow(title: "\(metric.label) Visibility")
                visibility.setModel(StringList([
                    MetricVisibilitySection.alwaysVisible.label,
                    MetricVisibilitySection.onDemand.label,
                ]))
                visibility.selected = entry.section == .alwaysVisible ? 0 : 1
                metricConnections.append(visibility.onNotify(.selected) {
                    [weak self, weak visibility] in
                    guard let self, let visibility, !self.applyingSettings else { return }
                    let section: MetricVisibilitySection =
                        visibility.selected == 0 ? .alwaysVisible : .onDemand
                    self.onMetricSectionChanged(provider.id, key, section)
                })
                group.add(visibility)
                rows.append(visibility)

                let pin = SwitchRow(
                    title: "Pin \(metric.label) to Panel",
                    subtitle: "Up to two metrics per provider."
                )
                pin.sensitive = entry.isEnabled
                pin.active = customizationSettings.panelMetricPins
                    .pins(for: provider.id)
                    .contains(key)
                metricConnections.append(pin.onNotify(.active) { [weak self, weak pin] in
                    guard let self, let pin, !self.applyingSettings else { return }
                    let accepted = self.onPanelPinChanged(provider.id, key, pin.active)
                    guard accepted else {
                        self.applyingSettings = true
                        pin.active = false
                        self.applyingSettings = false
                        return
                    }
                })
                group.add(pin)
                rows.append(pin)
            }
            metricGroupRows[provider.id] = rows
        }
    }

    func customizationProviders() -> [MetricCustomizationProvider] {
        var providers: [MetricCustomizationProvider] = []
        var indexByID: [String: Int] = [:]
        for snapshot in ProviderSnapshotPresentation.uniqueCards(customizationSnapshots) {
            let index: Int
            if let existing = indexByID[snapshot.providerID] {
                index = existing
            } else {
                index = providers.count
                indexByID[snapshot.providerID] = index
                providers.append(.init(
                    id: snapshot.providerID,
                    name: snapshot.displayName,
                    metrics: []
                ))
            }
            var known = Set(providers[index].metrics.map(MetricPreferenceKey.init(metric:)))
            for metric in snapshot.metrics where known.insert(MetricPreferenceKey(metric: metric)).inserted {
                providers[index].metrics.append(metric)
            }
        }
        return providers.filter { !$0.metrics.isEmpty }
    }

    func removeTrackedRows(_ rows: [Widget], from group: PreferencesGroup) {
        for row in rows {
            group.remove(row)
        }
        var leftover = group.getRow(0)
        while let existing = leftover {
            group.remove(existing)
            leftover = group.getRow(0)
        }
    }

    func reorderMenu(
        label: String,
        canMoveUp: Bool,
        canMoveDown: Bool,
        onMove: @escaping @MainActor (Int) -> Void
    ) -> MenuButton {
        let actions = Box(
            orientation: GTK_ORIENTATION_VERTICAL,
            spacing: GNOMEStyle.rowSpacing
        )
        actions.setMargins(GNOMEStyle.rowSpacing)
        let up = Button(label: "Move Up", onClicked: { onMove(-1) })
        up.sensitive = canMoveUp
        actions.append(up)
        let down = Button(label: "Move Down", onClicked: { onMove(1) })
        down.sensitive = canMoveDown
        actions.append(down)

        let popover = Popover()
        popover.child = actions
        let menu = MenuButton(icon: .openMenu)
        menu.addCSSClass(.flat)
        menu.setSizeRequest(
            width: GNOMEStyle.minimumTargetHeight,
            height: GNOMEStyle.minimumTargetHeight
        )
        menu.setAccessibleLabel("Reorder \(label)")
        menu.setPopover(popover)
        return menu
    }
}

struct MetricCustomizationProvider {
    let id: String
    let name: String
    var metrics: [UsageMetric]
}
