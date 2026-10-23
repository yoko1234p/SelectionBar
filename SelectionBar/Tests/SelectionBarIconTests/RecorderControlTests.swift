import AppKit
import XCTest

@testable import SelectionBar

final class RecorderControlTests: XCTestCase {
  @MainActor func testFocusedNativeRecorderConsumesEventAndEndsRecording() throws {
    let app = NSApplication.shared
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 220, height: 80), styleMask: [.titled],
      backing: .buffered, defer: false)
    defer { window.orderOut(nil) }
    let recorder = RecorderButton()
    recorder.frame = NSRect(x: 10, y: 10, width: 170, height: 28)
    window.contentView?.addSubview(recorder)
    var saved = ""
    recorder.onChange = { saved = $0 }
    window.makeFirstResponder(recorder)
    recorder.performClick(nil)
    XCTAssertTrue(window.firstResponder === recorder)
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.control, .option],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil,
        characters: "t", charactersIgnoringModifiers: "t", isARepeat: false, keyCode: 17))
    app.sendEvent(event)
    XCTAssertEqual(saved, "control option 0x11")
    XCTAssertEqual(recorder.value, "control option 0x11")
    XCTAssertFalse(recorder.title.contains("…"))
    let oldMenu = app.mainMenu
    defer { app.mainMenu = oldMenu }
    let target = RecorderMenuTarget()
    let menu = NSMenu()
    let application = NSMenuItem()
    let submenu = NSMenu()
    let quit = NSMenuItem(
      title: "Synthetic Quit", action: #selector(RecorderMenuTarget.invoked), keyEquivalent: "q")
    quit.target = target
    submenu.addItem(quit)
    application.submenu = submenu
    menu.addItem(application)
    app.mainMenu = menu
    recorder.performClick(nil)
    let command = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil,
        characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
    app.sendEvent(command)
    XCTAssertEqual(saved, "command 0xc")
    XCTAssertFalse(
      target.wasInvoked, "Recording must intercept menu shortcuts before menu dispatch")
    recorder.performClick(nil)
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil,
        characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    app.sendEvent(escape)
    XCTAssertEqual(saved, "command 0xc")
    XCTAssertFalse(recorder.title.contains("…"))
  }
}

@MainActor private final class RecorderMenuTarget: NSObject {
  var wasInvoked = false
  @objc func invoked() { wasInvoked = true }
}
