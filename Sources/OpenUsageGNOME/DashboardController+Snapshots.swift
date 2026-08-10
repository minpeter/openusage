import Adwaita
import Foundation
import OpenUsageLinuxCore

// MARK: - Snapshot pipeline

extension DashboardController {
    func refresh() {
        guard !isRefreshing else { return }

        if DemoFixtures.isEnabled {
            applyRefreshed(DemoFixtures.snapshots())
            return
        }

        isRefreshing = true
        refreshButton.sensitive = false
        let visible = visibleOrdered(snapshots)
        overview.update(
            snapshots: visible,
            isRefreshing: true,
            metricPresentationSettings: settings.metricPresentationSettings,
            density: settings.density,
            metricLayouts: settings.metricLayouts
        )
        updateToolbarSummary(snapshots: visible, isRefreshing: true)

        let repository = repository
        let callback = DashboardCallback(self)
        Task.detached {
            let refreshed = await repository.refresh()
            scheduleOnGTK {
                callback.applyRefreshed(refreshed)
            }
        }
    }

    func scheduleRefreshTimer() {
        if let refreshTimer {
            _ = MainContext.cancel(sourceId: refreshTimer)
            self.refreshTimer = nil
        }
        guard settings.periodicRefreshEnabled else { return }
        let minutes = max(
            GNOMESettings.minimumInterval,
            min(settings.refreshIntervalMinutes, GNOMESettings.maximumInterval)
        )
        refreshTimer = MainContext.timeout(every: .seconds(minutes * 60)) { [weak self] in
            self?.refresh()
            return true
        }
    }

    /// Stale-last-good: a failed provider keeps showing its last successful
    /// metrics with the error attached as an annotation instead of going
    /// blank.
    func mergedWithLastGood(_ incoming: [ProviderUsageSnapshot]) -> [ProviderUsageSnapshot] {
        incoming.map { snapshot in
            if snapshot.errorMessage != nil, snapshot.metrics.isEmpty,
               let good = lastGoodByInstance[snapshot.instanceID] {
                return ProviderUsageSnapshot(
                    providerID: good.providerID,
                    instanceID: good.instanceID,
                    displayName: good.displayName,
                    accountLabel: good.accountLabel,
                    plan: good.plan,
                    metrics: good.metrics,
                    links: good.links,
                    widgets: good.widgets,
                    refreshedAt: good.refreshedAt,
                    errorMessage: snapshot.errorMessage,
                    warning: snapshot.warning
                )
            }
            if snapshot.errorMessage == nil {
                lastGoodByInstance[snapshot.instanceID] = snapshot
            }
            return snapshot
        }
    }

    /// Persisted provider order first, then account label.
    func ordered(_ snapshots: [ProviderUsageSnapshot]) -> [ProviderUsageSnapshot] {
        ProviderSnapshotPresentation.ordered(
            snapshots,
            providerOrder: settings.providerOrder
        )
    }

    func visibleOrdered(_ snapshots: [ProviderUsageSnapshot]) -> [ProviderUsageSnapshot] {
        ProviderSnapshotPresentation.visibleOrdered(
            snapshots,
            providerOrder: settings.providerOrder,
            hiddenProviderIDs: settings.hiddenProviderIDs ?? []
        )
    }

    func applySnapshots() {
        let ordered = ordered(snapshots)
        let visible = visibleOrdered(snapshots)
        overview.update(
            snapshots: visible,
            isRefreshing: isRefreshing,
            metricPresentationSettings: settings.metricPresentationSettings,
            density: settings.density,
            metricLayouts: settings.metricLayouts
        )
        providersView.update(
            snapshots: visible,
            isRefreshing: isRefreshing,
            metricPresentationSettings: settings.metricPresentationSettings,
            density: settings.density,
            metricLayouts: settings.metricLayouts
        )
        historyView.update(snapshots: visible)
        updateToolbarSummary(snapshots: visible, isRefreshing: isRefreshing)
        updateTrayUsage(visible)

        var seen: Set<String> = []
        let providers = ordered.compactMap { snapshot -> (id: String, name: String)? in
            guard seen.insert(snapshot.providerID).inserted else { return nil }
            return (snapshot.providerID, snapshot.displayName)
        }
        settingsView.updateProviders(providers)
        settingsView.updateMetricCustomization(visible)
    }

    func updateTrayUsage(_ snapshots: [ProviderUsageSnapshot]) {
        guard let desktopIntegration else { return }
        trayUpdateRevision += 1
        let revision = trayUpdateRevision
        let configuration = PanelUsagePresentation.configuration(
            snapshots: snapshots,
            pins: settings.panelMetricPins,
            style: settings.menuBarStyle,
            displayMode: settings.trayUsageDisplayMode
        )
        Task.detached {
            await desktopIntegration.updateUsage(
                configuration,
                revision: revision
            )
        }
    }

    func applyCached(_ cached: [ProviderUsageSnapshot]) {
        snapshots = mergedWithLastGood(cached)
        applySnapshots()
        refresh()
    }

    func applyRefreshed(_ refreshed: [ProviderUsageSnapshot]) {
        let merged = mergedWithLastGood(refreshed)
        snapshots = merged
        isRefreshing = false
        refreshButton.sensitive = true
        applySnapshots()
        recordAnalyticsIfNeeded()
        if let desktopIntegration {
            Task.detached {
                await desktopIntegration.postRefresh(refreshed)
            }
        }
    }

    func recordAnalyticsIfNeeded() {
        guard !analyticsRecorded, !DemoFixtures.isEnabled else { return }
        analyticsRecorded = true
        let providers = Array(Set(snapshots.map(\.providerID))).sorted()
        let metricIDs = Array(Set(snapshots.flatMap { $0.widgets.map(\.id) })).sorted()
        let daily = LinuxAnalyticsDailySnapshot(
            enabledProviders: providers,
            enabledMetricIDs: metricIDs,
            pinnedMetricIDs: [],
            expandedMetricIDs: [],
            menuBarStyle: .bars
        )
        let rollups = providers.map { providerID in
            let providerSnapshots = snapshots.filter { $0.providerID == providerID }
            let failures = providerSnapshots.count { $0.errorMessage != nil }
            return LinuxAnalyticsProviderRollup(
                providerID: providerID,
                successCount: providerSnapshots.count - failures,
                failureCount: failures,
                errorCounts: failures == 0 ? [:] : [.other: failures],
                manualRefreshCount: 0
            )
        }
        let client = analyticsClient
        Task.detached {
            _ = await client.captureDailyActive(daily)
            for rollup in rollups {
                _ = await client.captureProviderRefresh(rollup)
            }
        }
    }
}

/// Sendable hop that carries repository results back onto the main actor
/// without capturing the controller in a detached task.
final class DashboardCallback: @unchecked Sendable {
    private weak var controller: DashboardController?

    @MainActor
    init(_ controller: DashboardController) {
        self.controller = controller
    }

    @MainActor
    func applyCached(_ snapshots: [ProviderUsageSnapshot]) {
        controller?.applyCached(snapshots)
    }

    @MainActor
    func applyRefreshed(_ snapshots: [ProviderUsageSnapshot]) {
        controller?.applyRefreshed(snapshots)
    }

    func presentWindow() async {
        await withCheckedContinuation { continuation in
            scheduleOnGTK { [weak self] in
                self?.controller?.present()
                continuation.resume()
            }
        }
    }

    @MainActor
    func retainDesktopIntegration(_ integration: GNOMEDesktopIntegration) {
        guard let controller else { return }
        controller.desktopIntegration = integration
        controller.updateTrayUsage(controller.visibleOrdered(controller.snapshots))
    }
}
