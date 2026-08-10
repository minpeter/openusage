import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Provider ordering

extension SettingsView {
    func rebuildOrderRows() {
        orderConnections.forEach { $0.disconnect() }
        orderConnections.removeAll(keepingCapacity: true)
        providerRows.removeAll(keepingCapacity: true)
        while let existing = orderGroup.getRow(0) {
            orderGroup.remove(existing)
        }
        guard !order.isEmpty else {
            orderGroup.add(ActionRow(
                title: "No Providers Yet",
                subtitle: "Provider ordering appears after the first refresh."
            ))
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

            let controls = Box(orientation: GTK_ORIENTATION_HORIZONTAL, spacing: 0)
            controls.addCSSClass(.linked)
            controls.valign = GTK_ALIGN_CENTER

            let up = Button(icon: .goUp, onClicked: { [weak self] in self?.move(id, by: -1) })
            up.setSizeRequest(height: GNOMEStyle.minimumTargetHeight)
            up.sensitive = index > 0
            up.setAccessibleLabel("Move \(providerNames[id] ?? id) up")
            let down = Button(icon: .goDown, onClicked: { [weak self] in self?.move(id, by: 1) })
            down.setSizeRequest(height: GNOMEStyle.minimumTargetHeight)
            down.sensitive = index < order.count - 1
            down.setAccessibleLabel("Move \(providerNames[id] ?? id) down")
            controls.append(up)
            controls.append(down)
            row.addSuffix(controls)
            orderGroup.add(row)
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
}
