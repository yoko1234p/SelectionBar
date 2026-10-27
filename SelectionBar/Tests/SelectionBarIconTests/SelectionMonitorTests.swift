import AppKit
import XCTest

@testable import SelectionBar

final class SelectionMonitorTests: XCTestCase {
  @MainActor func testRefreshDismissesToolbarWhenAutomaticMonitoringStops() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    model.library.settings.enabled = false
    var dismissals = 0
    model.dismissBar = { dismissals += 1 }
    let monitor = SelectionMonitor(model: model, onSelection: { _ in })
    monitor.refresh()
    XCTAssertEqual(dismissals, 1)
    monitor.stop()
  }

  @MainActor func testUnrelatedBackgroundAppDoesNotDismissSelection() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    model.library.settings.enabled = false
    var dismissals = 0
    model.dismissBar = { dismissals += 1 }
    let monitor = SelectionMonitor(
      model: model, workspace: NotificationCenter(), onSelection: { _ in })
    for name in [
      NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
    ] {
      monitor.workspaceChanged(name, applicationID: "local.fixture.background-worker")
      monitor.workspaceChanged(name)
    }
    XCTAssertEqual(dismissals, 0)
    for id in SelectionModel.conflictingApplications {
      monitor.workspaceChanged(NSWorkspace.didLaunchApplicationNotification, applicationID: id)
      monitor.workspaceChanged(NSWorkspace.didTerminateApplicationNotification, applicationID: id)
    }
    XCTAssertEqual(dismissals, 4)
    monitor.stop()
  }

  @MainActor func testSleepAndWakeInvalidateSelectionAndStopObservingAfterShutdown() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    model.library.settings.enabled = false
    var dismissals = 0
    model.dismissBar = { dismissals += 1 }
    let center = NotificationCenter()
    let monitor = SelectionMonitor(model: model, workspace: center, onSelection: { _ in })
    let notifications = [
      NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
      NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
      NSWorkspace.sessionDidResignActiveNotification,
      NSWorkspace.sessionDidBecomeActiveNotification,
    ]
    for name in notifications { center.post(name: name, object: nil) }
    XCTAssertEqual(dismissals, notifications.count)
    monitor.stop()
    for name in notifications { center.post(name: name, object: nil) }
    XCTAssertEqual(dismissals, notifications.count)
  }
}
