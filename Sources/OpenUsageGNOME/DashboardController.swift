import Adwaita
import Foundation
import OpenUsageLinuxCore

/// Owns the adaptive GNOME shell: a four-view ViewStack driven by a header
/// ViewSwitcher that collapses into a bottom ViewSwitcherBar at narrow
/// widths, window-level refresh in the header, and one persistent widget
/// tree per view that updates in place. Shell construction, settings wiring,
/// and the snapshot pipeline live in DashboardController+*.swift.
@MainActor
final class DashboardController {
    let application: Application
    let window: ApplicationWindow
    let stack = ViewStack()
    let headerSwitcher = ViewSwitcher()
    let switcherBar = ViewSwitcherBar()
    let refreshButton = Button(icon: .viewRefresh)
    let toolbarSummaryButton = Button()
    let toolbarSummaryProviderLabel = Label("Usage")
    let toolbarSummaryValueLabel = Label("—")
    let toastOverlay = ToastOverlay()

    let overview = OverviewView()
    let providersView = ProvidersView()
    let historyView = HistoryView()
    let settingsView: SettingsView

    let repository = LinuxUsageRepository()
    let settingsStore = GNOMESettingsStore()
    let apiKeyManager = LinuxAPIKeyManager()
    let analyticsClient: LinuxAnalyticsClient
    let launchAtLoginService: LinuxLaunchAtLoginService
    var settings: GNOMESettings
    var localAPIServer: LoopbackHTTPServer?
    var desktopIntegration: GNOMEDesktopIntegration?
    var trayUpdateRevision: UInt64 = 0
    var analyticsRecorded = false
    var snapshots: [ProviderUsageSnapshot] = []
    var lastGoodByInstance: [String: ProviderUsageSnapshot] = [:]
    var isRefreshing = false
    var refreshTimer: SourceID?
    var breakpoint: Breakpoint?
    var sharePreviewDialog: Dialog?
    var retainedActions: [SimpleAction] = []
    var connections: [SignalConnection] = []
    var renderGate = DashboardRenderGate()

    static let appVersion = "0.7.0"
    static let pageOrder: [(name: String, title: String, icon: String)] = [
        ("overview", "Overview", "view-grid-symbolic"),
        ("providers", "Providers", "view-list-symbolic"),
        ("history", "History", "document-open-recent-symbolic"),
        ("settings", "Settings", "emblem-system-symbolic"),
    ]

    init(application: Application) {
        self.application = application
        settings = settingsStore.load()
        analyticsClient = LinuxAnalyticsClient(enabled: settings.analyticsEnabled ?? true)
        let paths = LinuxPaths()
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        launchAtLoginService = LinuxLaunchAtLoginService(
            portal: FlatpakPortalLaunchBackend(
                initiallyEnabled: settings.launchAtLogin ?? false
            ),
            systemd: SystemdUserLaunchBackend(
                configHome: paths.configDirectory.deletingLastPathComponent(),
                executableURL: executableURL
            ),
            xdgAutostart: XDGAutostartBackend(
                configHome: paths.configDirectory.deletingLastPathComponent(),
                executableURL: executableURL
            )
        )

        GNOMEStyle.installCSS()

        window = ApplicationWindow(
            application: application,
            title: "OpenUsage",
            width: GNOMEStyle.defaultWidth,
            height: GNOMEStyle.defaultHeight
        )
        window.setSizeRequest(width: GNOMEStyle.minimumWidth, height: GNOMEStyle.minimumHeight)

        settingsView = SettingsView(
            settings: settings,
            cachePath: LinuxPaths().snapshotCache.path,
            defaultSyncPath: Self.defaultUsageDirectory().path,
            version: Self.appVersion
        )

        buildShell()
        buildActions()
        wireViews()
        wireSettings()
        installBreakpoint()
        applyAppearance(settings.appearance)

        if let size = DemoFixtures.requestedSize {
            window.setDefaultSize(width: size.width, height: size.height)
        }
        if let page = DemoFixtures.requestedPage,
           Self.pageOrder.contains(where: { $0.name == page }) {
            stack.visibleChildName = page
        }
        configureLocalAPI(
            enabled: settings.localAPIEnabled ?? false,
            port: settings.localAPIPort ?? LoopbackHTTPServer.defaultPort
        )
    }

    // MARK: - Lifecycle

    func present() {
        window.present()
    }

    func start() {
        if DemoFixtures.isEnabled {
            snapshots = mergedWithLastGood(DemoFixtures.snapshots())
            applySnapshots()
        } else {
            let repository = repository
            let callback = DashboardCallback(self)
            Task.detached {
                let cached = await repository.cachedSnapshots()
                scheduleOnGTK {
                    callback.applyCached(cached)
                }
            }
        }
        scheduleRefreshTimer()
        startDesktopIntegration()
    }

    func stop() {
        if let refreshTimer {
            _ = MainContext.cancel(sourceId: refreshTimer)
            self.refreshTimer = nil
        }
        localAPIServer?.stop()
        localAPIServer = nil
        let integration = desktopIntegration
        desktopIntegration = nil
        connections.forEach { $0.disconnect() }
        connections.removeAll()
        Task.detached {
            await integration?.stop()
        }
    }

    private func startDesktopIntegration() {
        guard !DemoFixtures.isEnabled, desktopIntegration == nil else { return }
        let callback = DashboardCallback(self)
        Task.detached {
            do {
                let integration = try GNOMEDesktopIntegration {
                    await callback.presentWindow()
                }
                await integration.start()
                scheduleOnGTK {
                    callback.retainDesktopIntegration(integration)
                }
            } catch {
                GNOMEAppLog.warning(
                    "Desktop integration unavailable: \(error.localizedDescription)"
                )
            }
        }
    }
}
