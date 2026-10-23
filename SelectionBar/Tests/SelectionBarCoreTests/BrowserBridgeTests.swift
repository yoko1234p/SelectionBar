import Carbon
import JavaScriptCore
import XCTest

@testable import SelectionBarCore

final class BrowserBridgeTests: XCTestCase {
  func testTypedBrowserEventsKeepSourceSeparateFromTabAndCannotInterpolate() throws {
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.google.Chrome")
    let tab = try BrowserBridge.specifier(
      want: "cwin", form: AEKeyword(formAbsolutePosition), data: NSAppleEventDescriptor(int32: 1))
    let source = "'quoted' \"source\"; \\ 日本語"
    let chromium = BrowserBridge.javaScriptEvent(
      family: .chromium, target: target, tab: tab, source: source)
    XCTAssertEqual(chromium.paramDescriptor(forKeyword: 0x4a76_5363)?.stringValue, source)
    XCTAssertEqual(
      chromium.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.descriptorType,
      typeObjectSpecifier)
    let safari = BrowserBridge.javaScriptEvent(
      family: .safari, target: target, tab: tab, source: source)
    XCTAssertEqual(
      safari.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, source)
    XCTAssertEqual(
      safari.paramDescriptor(forKeyword: 0x6463_6e6d)?.descriptorType, typeObjectSpecifier)
    XCTAssertEqual(BrowserBridge.family("com.vivaldi.Vivaldi"), .chromium)
    XCTAssertEqual(BrowserBridge.family("org.mozilla.firefox"), .basic)
    XCTAssertNil(BrowserBridge.family("dev.test.not-browser"))
  }
  func testBrowserSelectionLeaseFingerprintIncludesTabRangeAndDocument() throws {
    let payload: [String: Value] = [
      "url": .string("https://example.invalid"), "text": .string("word"),
      "identity": .string("[0,4,word word]"), "editable": .bool(true),
    ]
    let one = try BrowserSelection(payload: payload, window: "1", tab: "2")
    XCTAssertEqual(
      one.signature, try BrowserSelection(payload: payload, window: "1", tab: "2").signature)
    XCTAssertNotEqual(
      one.signature, try BrowserSelection(payload: payload, window: "1", tab: "3").signature)
    var changed = payload
    changed["identity"] = .string("[5,9,word word]")
    XCTAssertNotEqual(
      one.signature, try BrowserSelection(payload: changed, window: "1", tab: "2").signature)
    changed["identity"] = .string("[0,4,word changed]")
    XCTAssertNotEqual(
      one.signature, try BrowserSelection(payload: changed, window: "1", tab: "2").signature)
    XCTAssertThrowsError(
      try BrowserSelection(payload: ["secure": .bool(true)], window: "1", tab: "2"))
    XCTAssertThrowsError(
      try BrowserSelection(
        payload: ["text": .string(String(repeating: "a", count: 2_097_153))], window: "1", tab: "2")
    )
  }
  func testOwnBrowserProbeReadsSyntheticInputAndRefusesPasswordWithoutDOMMutation() throws {
    let context = try XCTUnwrap(JSContext())
    context.evaluateScript(
      """
      globalThis.location={href:'https://example.invalid'};
      globalThis.document={title:'Synthetic',activeElement:{tagName:'TEXTAREA',type:'text',
        value:'before 日本語 after',selectionStart:7,selectionEnd:10,readOnly:false,disabled:false}};
      """)
    let raw = try XCTUnwrap(context.evaluateScript(BrowserBridge.selectionJavaScript)?.toString())
    let value = try JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))
    XCTAssertEqual(value["text"], .string("日本語"))
    XCTAssertEqual(value["editable"], .bool(true))
    XCTAssertEqual(
      context.evaluateScript("document.activeElement.value")?.toString(), "before 日本語 after")
    context.evaluateScript("document.activeElement.type='password';")
    let secureRaw = try XCTUnwrap(
      context.evaluateScript(BrowserBridge.selectionJavaScript)?.toString())
    let secure = try JSONDecoder().decode([String: Value].self, from: Data(secureRaw.utf8))
    XCTAssertEqual(secure, ["secure": .bool(true)])
  }
}
