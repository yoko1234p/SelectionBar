import AppKit
import XCTest

@testable import SelectionBar

final class SelectionMonitorTests: XCTestCase {
  @MainActor func testRefreshDismissesToolbarWhenAutomaticMonitoringStops() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let model = SelectionModel(root: root)
    model.library.settings.enabled = false
    var dismissals = 0
    model.dismissBar = { dismissals += 1 }
    let monitor = SelectionMonitor(model: model, onSelection: { _ in })
    monitor.refresh()
    XCTAssertEqual(dismissals, 1)
    monitor.stop()
  }
}
