import Foundation
import XCTest

@testable import SelectionBarCore

final class ModuleTests: XCTestCase {
  private func run(
    _ source: String, text: String = "hello", editable: Bool = true,
    path: [Int]? = nil, open: Bool = false, entitlements: [String] = [], phase: String = "action",
    properties: [String: Value] = [:], stored: [String: Value] = [:]
  ) throws
    -> ScriptResponse
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SelectionBarModule-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(source.utf8).write(to: root.appendingPathComponent("module.js"))
    var config: [String: Value] = [
      "module": .string("module.js"), "entitlements": .array(entitlements.map(Value.string)),
    ]
    config.merge(properties) { _, new in new }
    let record = ExtensionRecord(
      id: "dev.test.module", name: "Fixture", packagePath: root.path, digest: "fixture",
      config: config, actions: [], options: stored)
    return try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "0", title: "Fixture", config: config),
        context: ActionContext(text: text, editable: editable), phase: phase, modulePath: path,
        openSubmenu: open)
    )
  }
  func testModuleOptionDefaultsAndMigrationAliasesDriveNativeRequirements() throws {
    let source = """
      defineExtension({options:[
        {identifier:'enabled',type:'boolean'},
        {identifier:'language',type:'multiple',values:['ja','en'],migrateFrom:'oldLanguage'}
      ],actions:[{title:'Visible',requirements:['option-enabled=1','option-language=ja'],code:()=>42}]});
      """
    let defaults = try run(source)
    XCTAssertNil(defaults.error)
    XCTAssertEqual(defaults.result, .number(42))
    let migrated = try run(
      source, stored: ["oldLanguage": .string("ja"), "language": .string("en")])
    XCTAssertEqual(migrated.result, .number(42))
    let disabled = try run(source, stored: ["enabled": .bool(false)])
    XCTAssertTrue(disabled.actions.isEmpty)
    XCTAssertNotEqual(disabled.didExecute, true)
  }
  func testModuleOptionDefinitionsOverrideStaticDefaultsButNotSavedValues() throws {
    let source =
      "defineExtension({options:[{identifier:'language',type:'string',defaultValue:'ja'}],action:{requirements:['option-language=ja'],code:(_,options)=>options.language}});"
    let properties: [String: Value] = [
      "options": .array([
        .object([
          "identifier": .string("language"), "type": .string("string"),
          "defaultvalue": .string("en"),
        ])
      ])
    ]
    XCTAssertEqual(try run(source, properties: properties).result, .string("ja"))
    XCTAssertTrue(
      try run(source, properties: properties, stored: ["language": .string("ko")]).actions.isEmpty)
  }
  func testModuleSubmenuFlagsDoNotLeakIntoChildrenAndSupplementalCodeRemainsSeparate() throws {
    let source = """
      defineExtension({before:'copy',after:'paste-result',requirements:['url'],captureHtml:true,
        action:{title:'Parent',code:()=>99,submenu:[
          {title:'Child',requirements:[],code:()=>7},
          {separator:true},{title:'Normal',code:()=>8}
        ]}});
      """
    let response = try run(source, text: "https://example.invalid", path: [0, 0])
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .number(7))
    XCTAssertTrue(response.effects.isEmpty)
    let listed = try run(source, text: "https://example.invalid", path: [0], open: true)
    XCTAssertEqual(listed.actions.count, 3)
    XCTAssertEqual(listed.actions.first?["captureHtml"], .bool(false))
    XCTAssertEqual(listed.actions[1]["separator"], .bool(true))
    let parent = try run(source, text: "https://example.invalid", path: [0])
    XCTAssertEqual(parent.result, .number(99))
    XCTAssertEqual(parent.effects.map { $0["type"]?.string }, ["step", "step"])
  }
  func testModuleExportedFlagsOverrideStaticAliasesAndAppGatePrecedesBeforeStep() throws {
    let source = """
      defineExtension({requiredApps:['fixture.allowed'],app:{name:'Needed',checkInstalled:true,bundleIdentifiers:['fixture.needed']},
        before:'cut',action:{code:()=>42}});
      """
    let response = try run(source, properties: ["requiredapps": .array([.string("")])])
    XCTAssertTrue(response.actions.isEmpty)
    let gate = try run(
      "defineExtension({app:{name:'Needed',checkInstalled:true,bundleIdentifiers:['fixture.needed']},before:'copy',action:()=>42});"
    )
    XCTAssertEqual(gate.effects.map { $0["type"]?.string }, ["checkApps", "step"])
  }
  func testModernCodeFunctionAndSingleActionObject() throws {
    let response = try run(
      "defineExtension({action:{title:'Uppercase',code:async(input)=>{await popclip.pasteText(input.text.toUpperCase())}}});"
    )
    XCTAssertNil(response.error)
    XCTAssertEqual(response.effects.first?["text"], .string("HELLO"))
  }
  func testInitialSubmenuPopulationReturnsStablePathWithoutExecutingAnyAction() throws {
    let source = """
      defineExtension({actions:[
        {title:'Root',code:()=>{throw Error('must not execute')}},
        {title:'Nested',submenu:[{title:'Initial',wantsInitialDisplay:true,submenu:async()=>[
          {title:'First',wantsPrimaryDisplay:true,icon:'symbol:star',preserveColor:true,flipX:true,scale:0.8,
           code:()=>{throw Error('must not execute')}},
          {separator:true},{title:'Second',code:()=>0}]}]}]});
      """
    let response = try run(source, entitlements: ["dynamic"], phase: "population")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.initialPath, [1, 0])
    XCTAssertEqual(response.initialActions?.count, 3)
    let first = try XCTUnwrap(response.initialActions?.first)
    XCTAssertEqual(first["path"], .array([.number(1), .number(0), .number(0)]))
    XCTAssertEqual(first["wantsPrimaryDisplay"], .bool(true))
    XCTAssertEqual(first["iconProperties"]?.object["preserveColor"], .bool(true))
    XCTAssertEqual(first["iconProperties"]?.object["flipX"], .bool(true))
    XCTAssertEqual(first["iconProperties"]?.object["scale"], .number(0.8))
    XCTAssertTrue(response.effects.isEmpty)
    XCTAssertNotEqual(response.didExecute, true)
  }
  func testInitialSubmenuUsesFirstEligibleOrderAndSkipsFilteredEmptyFolder() throws {
    let source = """
      defineExtension({actions:[
        {title:'Empty',wantsInitialDisplay:true,submenu:[{title:'Not applicable',requirements:['paste'],code:()=>0}]},
        {title:'Chosen',wantsInitialDisplay:true,submenu:[{title:'One',code:()=>0}]},
        {title:'Later',wantsInitialDisplay:true,submenu:[{title:'Two',code:()=>0}]}]});
      """
    let response = try run(source, editable: false, phase: "population")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.initialPath, [1])
    XCTAssertEqual(response.initialActions?.first?["title"], .string("One"))
  }
  func testInitialDynamicSubmenuCannotPerformNativeEffects() throws {
    let response = try run(
      """
      defineExtension({action:{title:'Folder',wantsInitialDisplay:true,submenu:async()=>{
        let guarded=false;try {await popclip.copyText('must not copy')}catch(error){guarded=true}
        return [{title:String(guarded),code:()=>0}];}}});
      """, entitlements: ["dynamic"], phase: "population")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.initialActions?.first?["title"], .string("true"))
    XCTAssertTrue(response.effects.isEmpty)
  }
  func testUnopenedDynamicSubmenuRemainsLazyDuringRootPopulation() throws {
    let response = try run(
      """
      defineExtension({actions:[{title:'Lazy',submenu:()=>{throw Error('unopened submenu invoked')}},
        {title:'Visible',code:()=>0}]});
      """, entitlements: ["dynamic"], phase: "population")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.actions.map { $0["title"]?.string }, ["Lazy", "Visible"])
    XCTAssertNil(response.initialPath)
  }
  func testModuleFlagsUseLiveStepProtocol() throws {
    let response = try run(
      "module.exports={action:{before:'copy',after:'paste-result',code:input=>input.text+'!'}}")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.effects.map { $0["type"]?.string }, ["step", "step"])
    XCTAssertEqual(response.effects.last?["result"], .string("hello!"))
  }
  func testStaticModuleRequirementsFilterActions() throws {
    let response = try run(
      "defineExtension({actions:[{title:'Editable',requirements:['paste'],code:()=>1},{title:'Read only',requirements:['!paste'],code:()=>2}]});",
      editable: false)
    XCTAssertNil(response.error)
    XCTAssertEqual(response.actions.count, 1)
    XCTAssertEqual(response.result, .number(2))
  }
  func testUnawaitedTimerRunsBeforeWorkerFinishes() throws {
    let response = try run("module.exports={action:()=>{setTimeout(()=>popclip.appear(),5)}}")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.effects.last?["type"], .string("appear"))
  }
  func testRichSelectionNormalizesAfterAPIHelpersLoad() throws {
    let config: [String: Value] = [
      "javascript": .string(
        "return [popclip.input.html,popclip.input.markdown,popclip.input.xhtml,typeof document,popclip.context.appIdentifier,popclip.input.data.urls.ranges[0].location];"
      )
    ]
    let record = ExtensionRecord(
      id: "dev.test.rich", name: "Rich", packagePath: FileManager.default.temporaryDirectory.path,
      digest: "synthetic", config: config, actions: [])
    let response = try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "0", title: "Rich", config: config),
        context: ActionContext(
          text: "Go https://example.com now", bundleIdentifier: "dev.test.editor",
          html: "<p>Hello <b>world</b></p><script>bad()</script>")))
    XCTAssertNil(response.error)
    let values = response.result?.array ?? []
    XCTAssertEqual(values.count, 6)
    if values.count == 6 {
      XCTAssertFalse(values[0].string.contains("script"))
      XCTAssertEqual(values[1], .string("Hello **world**"))
      XCTAssertEqual(values[3], .string("undefined"))
      XCTAssertEqual(values[4], .string("dev.test.editor"))
      XCTAssertEqual(values[5], .number(3))
    }
  }
  func testJavaScriptRegexPreservesCaptureAndResetsGlobalSticky() throws {
    let response = try run(
      "defineExtension({actions:[{title:'Regex',regex:/H(EL)LO/igy,code:input=>[input.matchedText,input.regexResult[1],input.regexResult.index]}]});",
      text: "x hello world")
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .array([.string("hello"), .string("el"), .number(2)]))
  }
  func testNestedDynamicSubmenuUsesStablePathsAndSeparators() throws {
    let source =
      "defineExtension({actions:[{title:'Folder',submenu:()=>[{title:'Child',code:()=>42},{separator:true},{title:'Disabled'}]},{title:'Other',code:()=>0}]});"
    let listing = try run(source, path: [0], open: true, entitlements: ["dynamic"])
    XCTAssertNil(listing.error)
    XCTAssertEqual(listing.actions.count, 3)
    XCTAssertEqual(listing.actions[0]["path"], .array([.number(0), .number(0)]))
    XCTAssertEqual(listing.actions[1]["separator"], .bool(true))
    XCTAssertEqual(listing.actions[2]["disabled"], .bool(true))
    let selected = try run(source, path: [0, 0], entitlements: ["dynamic"])
    XCTAssertNil(selected.error)
    XCTAssertEqual(selected.result, .number(42))
    XCTAssertEqual(selected.didExecute, true)
  }
  func testActionBodySupportsESImportsAndPackageModulePrecedesBundled() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("export default {marker:'package'};".utf8).write(
      to: root.appendingPathComponent("axios.js"))
    try Data("export const value=7;".utf8).write(to: root.appendingPathComponent("choice.ts"))
    try Data("{\"value\":8}".utf8).write(to: root.appendingPathComponent("choice.json"))
    let config: [String: Value] = [
      "javascript": .string(
        "import chosen from 'axios'; import {value} from 'choice'; return [chosen.marker,value,typeof require('missing')];"
      )
    ]
    let record = ExtensionRecord(
      id: "fixture.imports", name: "Imports", packagePath: root.path, digest: "fixture",
      config: config, actions: [])
    let response = try JavaScriptEngine().run(
      ScriptRequest(
        record: record, action: ExtensionAction(id: "0", title: "Imports", config: config),
        context: ActionContext(text: "test")))
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .array([.string("package"), .number(7), .string("undefined")]))
  }
}
