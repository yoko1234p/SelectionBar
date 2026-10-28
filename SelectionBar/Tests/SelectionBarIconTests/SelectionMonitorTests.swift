import AppKit
import SelectionBarCore
import XCTest

@testable import SelectionBar

final class SelectionMonitorTests: XCTestCase {
  @MainActor func testTypingDismissesToolbarAndCancelsDelayedClick() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = SelectionModel(root: root)
    var dismissals = 0
    model.dismissBar = { dismissals += 1 }
    model.overlayFrame = { CGRect(x: 1, y: 1, width: 100, height: 40) }
    let monitor = SelectionMonitor(model: model, onSelection: { _ in
      XCTFail("Typing must cancel the delayed click capture")
    })
    defer { monitor.stop() }
    let point = CGPoint(x: 200, y: 200)
    let down = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    let key = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false,
      keyCode: 0))
    monitor.handle(down, pointer: point)
    monitor.handle(up, pointer: point)
    XCTAssertNotNil(monitor.pending)
    monitor.handle(key, pointer: point)
    XCTAssertNil(monitor.pending)
    XCTAssertEqual(dismissals, 2)
    let selectionKey = try XCTUnwrap(NSEvent.keyEvent(
      with: .keyUp, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
      context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
      keyCode: 124))
    monitor.handle(selectionKey, pointer: point)
    XCTAssertNotNil(monitor.pending, "Shift-arrow selection must still schedule a toolbar")
  }
  @MainActor func testInsertionRespectsBrowserExclusionsWhenURLIsUnavailable() {
    let rules = [WebsiteRule(pattern: "private.example")]
    let chrome = "com.google.Chrome"
    XCTAssertFalse(SelectionMonitor.allowsInsertion(appID: chrome, url: "", rules: rules))
    XCTAssertFalse(SelectionMonitor.allowsInsertion(
      appID: chrome, url: "https://private.example/path", rules: rules))
    XCTAssertTrue(SelectionMonitor.allowsInsertion(
      appID: chrome, url: "https://public.example", rules: rules))
    XCTAssertTrue(SelectionMonitor.allowsInsertion(appID: chrome, url: "", rules: []))
    XCTAssertTrue(SelectionMonitor.allowsInsertion(appID: "fixture.editor", url: "", rules: rules))
  }
  func testOwnOverlayAndActiveWindowsDoNotConsumeClicksForAnotherApplication() {
    let toolbar = CGRect(x: 100, y: 100, width: 200, height: 44)
    let settings = CGRect(x: -600, y: 30, width: 500, height: 600)
    var filter = SelectionInputFilter()
    XCTAssertTrue(
      filter.ignoresMouse(
        type: .leftMouseDown, pointer: CGPoint(x: 120, y: 110), overlay: toolbar, activeWindows: [])
    )
    XCTAssertTrue(
      filter.ignoresMouse(
        type: .leftMouseUp, pointer: CGPoint(x: 350, y: 110), overlay: toolbar, activeWindows: []),
      "Releasing outside after pressing the toolbar must not start a selection")
    XCTAssertTrue(
      filter.ignoresMouse(
        type: .leftMouseDown, pointer: CGPoint(x: -200, y: 100), overlay: toolbar,
        activeWindows: [settings]))
    XCTAssertTrue(
      filter.ignoresMouse(
        type: .leftMouseUp, pointer: CGPoint(x: -200, y: 100), overlay: toolbar,
        activeWindows: [settings]))
    XCTAssertFalse(
      filter.ignoresMouse(
        type: .leftMouseDown, pointer: CGPoint(x: -200, y: 100), overlay: toolbar, activeWindows: []
      ))
    XCTAssertFalse(
      filter.ignoresMouse(
        type: .leftMouseUp, pointer: CGPoint(x: 350, y: 110), overlay: toolbar,
        activeWindows: [settings]))
  }

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
