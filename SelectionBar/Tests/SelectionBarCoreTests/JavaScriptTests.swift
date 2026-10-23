import Foundation
import XCTest

@testable import SelectionBarCore

final class JavaScriptTests: XCTestCase {
  func request(_ source: String, entitlements: [String] = []) -> ScriptRequest {
    let config: [String: Value] = [
      "javascript": .string(source), "entitlements": .array(entitlements.map(Value.string)),
    ]
    let record = ExtensionRecord(
      id: "dev.test", name: "Synthetic", packagePath: FileManager.default.temporaryDirectory.path,
      digest: "synthetic", config: config, actions: [])
    return ScriptRequest(
      record: record, action: ExtensionAction(id: "0", title: "Synthetic", config: config),
      context: ActionContext(text: "hello 日", editable: true))
  }
  func testSelectionTransformAndRecordedPaste() throws {
    let response = try JavaScriptEngine().run(
      request("await popclip.pasteText(popclip.input.text.toUpperCase(), {restore:true});"))
    XCTAssertNil(response.error)
    XCTAssertEqual(response.effects.first?["text"], .string("HELLO 日"))
    XCTAssertEqual(response.effects.first?["restore"], .bool(true))
  }
  func testAwaitedHostReplyIsUsedByNextStatement() throws {
    var operations: [String] = []
    let response = try JavaScriptEngine().run(
      request("const v=await popclip.runShortcut('Synthetic'); await popclip.copyText(v);"),
      host: { raw in
        let object =
          (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        operations.append(object["type"] as? String ?? "")
        return object["type"] as? String == "shortcut"
          ? "{\"result\":\"actual native result\"}" : "{\"result\":null}"
      })
    XCTAssertNil(response.error)
    XCTAssertEqual(operations, ["shortcut", "copy"])
    XCTAssertTrue(response.effects.isEmpty)
  }
  func testPopulationCannotPerformActionsOrScripts() throws {
    var r = request("await popclip.copyText('must not run');")
    r.phase = "population"
    let response = try JavaScriptEngine().run(r)
    XCTAssertTrue(response.effects.isEmpty)
  }
  func testNetworkWithoutEntitlementFailsBeforeRequest() throws {
    let response = try JavaScriptEngine().run(
      request("const axios=require('axios'); await axios.get('https://example.invalid');"))
    XCTAssertNotNil(response.error)
  }
  func testErrorsDoNotReturnPartialEffects() throws {
    let response = try JavaScriptEngine().run(
      request("popclip.copyText('before'); throw Error('failed');"))
    XCTAssertEqual(response.error, "failed")
    XCTAssertTrue(response.effects.isEmpty)
  }
  func testOfficialClarifySpecificationWithoutRealCredentials() throws {
    let json = "{\"sample\":\"not a credential\"}"
    let base = Data(json.utf8).base64EncodedString()
    let rot = String(
      base.unicodeScalars.map { c -> Character in
        let n = c.value
        if (65...90).contains(n) { return Character(UnicodeScalar(65 + (n - 65 + 13) % 26)!) }
        if (97...122).contains(n) { return Character(UnicodeScalar(97 + (n - 97 + 13) % 26)!) }
        return Character(c)
      })
    let literal = String(decoding: try JSONEncoder().encode(rot), as: UTF8.self)
    let response = try JavaScriptEngine().run(request("return util.clarify(\(literal)).sample;"))
    XCTAssertEqual(response.result, .string("not a credential"))
  }
  func testUnawaitedShareDoesNotBlockAnotherHostPromise() throws {
    let state = LockedState()
    let response = try JavaScriptEngine().run(
      request(
        "popclip.share('synthetic', ['fixture']); await popclip.copyText('ready'); return 'done';"),
      host: { _ in
        XCTFail("Promise operation used synchronous host")
        return "{}"
      },
      hostAsync: { raw, completion in
        let value = (try? JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))) ?? [:]
        let kind = value["type"]?.string ?? ""
        state.append(kind)
        DispatchQueue.global().asyncAfter(deadline: .now() + (kind == "share" ? 0.06 : 0.001)) {
          state.append(kind + "-complete")
          completion("{\"result\":null}")
        }
      })
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .string("done"))
    XCTAssertEqual(state.values, ["share", "copy", "copy-complete", "share-complete"])
  }
  func testNativePopulationGateCannotBeBypassedThroughRawBridge() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(
      "module.exports={options:[],actions:async()=>{__phase='action'; const a=JSON.parse(__host('{\"type\":\"copy\",\"text\":\"forbidden\"}')); const b=await new Promise(resolve=>__hostAsync('{\"type\":\"copy\"}',raw=>resolve(JSON.parse(raw)))); return [{title:String(!!a.error&&!!b.error),code:()=>0}];}};"
        .utf8
    ).write(to: root.appendingPathComponent("Config.js"))
    var r = request("")
    r.phase = "population"
    r.record.packagePath = root.path
    r.record.config["entitlements"] = .array([.string("dynamic")])
    r.action.config = [
      "module": .string("Config.js"), "entitlements": .array([.string("dynamic")]),
    ]
    let result = try JavaScriptEngine().run(
      r,
      host: { _ in
        XCTFail("Population reached native host")
        return "{}"
      },
      hostAsync: { _, completion in
        XCTFail("Population reached native async host")
        completion("{}")
      })
    XCTAssertNil(result.error)
    XCTAssertEqual(result.actions.first?["title"], .string("true"))
    XCTAssertTrue(result.effects.isEmpty)
  }
  func testLongScriptPromiseDoesNotBlockTimer() throws {
    let response = try JavaScriptEngine().run(
      request(
        "const events=[]; const work=popclip.runShellScript('sleep 0.06; printf done', {interpreter:'/bin/sh'}).then(()=>events.push('script')); setTimeout(()=>events.push('timer'),5); await work; return events;",
        entitlements: ["script"]))
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .array([.string("timer"), .string("script")]))
  }
  func testScriptSignalErrorsRetainTypedTerminationDetails() throws {
    let response = try JavaScriptEngine().run(
      request(
        "try { await popclip.runShellScript('printf before; kill -TERM $$',{interpreter:'/bin/sh'}); } catch(error) { return [error.status,error.terminationReason,error.stdout]; }",
        entitlements: ["script"]))
    XCTAssertNil(response.error)
    XCTAssertEqual(
      response.result, .array([.number(15), .string("uncaughtSignal"), .string("before")]))
  }
}

private final class LockedState: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String] = []
  func append(_ value: String) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }
  var values: [String] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}
