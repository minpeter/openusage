import XCTest
@testable import OpenUsage

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(state.expandedMetricIDs, ["claude.weekly"])
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertFalse(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertNil(state.seededDefaultsToPersist)
    }

    func testRemapsLegacyCursorSpendingLayoutIDs() {
        let (persistence, _) = makePersistence("CursorSpendingIDs")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "cursor.usage"),
            PlacedWidget(descriptorID: "cursor.auto"),
            PlacedWidget(descriptorID: "cursor.api"),
            PlacedWidget(descriptorID: "cursor.grokBotWeekly"),
        ])
        persistence.savePins(Set(["cursor.auto", "cursor.api"]))

        let state = LayoutBootstrap.load(
            registry: WidgetRegistry.from([CursorProvider()]),
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: DefaultLayout.metricIDs,
                migrationBaselineMetricIDs: DefaultLayout.migrationBaselineMetricIDs,
                pinnedMetricIDs: DefaultLayout.pinnedMetricIDs,
                expandedMetricIDs: DefaultLayout.expandedMetricIDs
            )
        )

        let cursorIDs = state.placed.map(\.descriptorID).filter { $0.hasPrefix("cursor.") }
        XCTAssertTrue(cursorIDs.contains("cursor.cursorModels"))
        XCTAssertTrue(cursorIDs.contains("cursor.otherModels"))
        XCTAssertTrue(cursorIDs.contains("cursor.grokBotWeekly"))
        XCTAssertEqual(cursorIDs.filter { $0 == "cursor.cursorModels" }.count, 1)
        XCTAssertFalse(cursorIDs.contains("cursor.auto"))
        XCTAssertFalse(cursorIDs.contains("cursor.api"))
        XCTAssertEqual(state.pinnedMetricIDs, Set(["cursor.cursorModels", "cursor.otherModels"]))
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
