import Foundation
import XCTest

@testable import SelectionBarCore

final class ToolbarPopulationTests: XCTestCase {
  private func executable() throws -> String {
    var directory = Bundle(for: Self.self).bundleURL
    for _ in 0..<7 {
      let path = directory.appendingPathComponent("SelectionBarRuntime").path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
      directory.deleteLastPathComponent()
    }
    throw XCTSkip("Build SelectionBarRuntime for population integration tests")
  }
  private func job(
    _ key: String, root: URL, delay: Int = 0,
    source: String? = nil
  ) throws -> PopulationJob {
    let package = root.appendingPathComponent(key)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    let code =
      source
      ?? "defineExtension({actions:async input=>{await sleep(\(delay));return [{title:'\(key)-'+input.text,code:()=>{throw Error('action must not run')}},{title:'second',code:()=>0}]}});"
    try Data(code.utf8).write(to: package.appendingPathComponent("Config.js"))
    let config: [String: Value] = [
      "module": .string("Config.js"), "entitlements": .array([.string("dynamic")]),
    ]
    let action = ExtensionAction(id: "0", title: key, config: config)
    let record = ExtensionRecord(
      id: "synthetic." + key, name: key, packagePath: package.path,
      digest: "synthetic", config: config, actions: [action])
    return PopulationJob(key: key, record: record, action: action)
  }
  @MainActor
  func testInlineCatalogKeepsLayoutOrderAndBoundsWorkers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = ToolbarPopulation(executable: try executable())
    defer { pipeline.cancel() }
    let jobs = try [
      job("first", root: root, delay: 180), job("second", root: root), job("third", root: root),
    ]
    var final = PopulationState()
    var completed: [String] = []
    pipeline.populate(jobs, context: ActionContext(text: "selected")) { state in
      final = state
      for key in state.order where state.actions[key] != nil && !completed.contains(key) {
        completed.append(key)
      }
      XCTAssertEqual(state.order, ["first", "second", "third"])
      XCTAssertLessThanOrEqual(pipeline.activeWorkerCount, 2)
    }
    XCTAssertEqual(pipeline.activeWorkerCount, 2)
    XCTAssertEqual(pipeline.queuedWorkerCount, 1)
    for _ in 0..<200 {
      if final.pending.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(final.pending.isEmpty)
    XCTAssertTrue(final.errors.isEmpty)
    XCTAssertEqual(
      final.order.flatMap { final.actions[$0]?.compactMap { $0["title"]?.string } ?? [] },
      ["first-selected", "second", "second-selected", "second", "third-selected", "second"])
    XCTAssertEqual(completed.first, "second")
    XCTAssertEqual(pipeline.activeWorkerCount, 0)
  }
  @MainActor
  func testNewSelectionCancelsRunningAndQueuedOldGeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = ToolbarPopulation(executable: try executable(), maximumConcurrent: 1)
    defer { pipeline.cancel() }
    var staleCompleted = false
    var latest = PopulationState()
    pipeline.populate(
      try [job("old", root: root, delay: 250), job("queued", root: root)],
      context: ActionContext(text: "old")
    ) { state in
      if !state.actions.isEmpty { staleCompleted = true }
    }
    XCTAssertEqual(pipeline.queuedWorkerCount, 1)
    try await Task.sleep(for: .milliseconds(25))
    pipeline.populate(try [job("new", root: root)], context: ActionContext(text: "new")) {
      latest = $0
    }
    for _ in 0..<200 {
      if latest.pending.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(staleCompleted)
    XCTAssertEqual(latest.order, ["new"])
    XCTAssertEqual(latest.actions["new"]?.first?["title"], .string("new-new"))
    XCTAssertEqual(pipeline.activeWorkerCount, 0)
    XCTAssertEqual(pipeline.queuedWorkerCount, 0)
  }
  @MainActor
  func testPopulationCannotDispatchAnActionEvenThroughRawHost() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = ToolbarPopulation(executable: try executable())
    defer { pipeline.cancel() }
    let source =
      "defineExtension({actions:async()=>{const a=JSON.parse(__host('{\"type\":\"copy\",\"text\":\"forbidden\"}')); let b;try{await popclip.runShellScript('printf forbidden',{interpreter:'/bin/sh'});}catch(error){b=true;}return [{title:String(!!a.error&&b),code:()=>{throw Error('must not run')}}]}});"
    var state = PopulationState()
    pipeline.populate(
      try [job("gated", root: root, source: source)], context: ActionContext(text: "fixture")
    ) { state = $0 }
    for _ in 0..<200 {
      if state.pending.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(state.errors.isEmpty)
    XCTAssertEqual(state.actions["gated"]?.first?["title"], .string("true"))
  }
  @MainActor
  func testInitialCatalogRetainsLayoutOrderAcrossOutOfOrderWorkers() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let pipeline = ToolbarPopulation(executable: try executable())
    defer { pipeline.cancel() }
    func initial(_ title: String, _ delay: Int) -> String {
      "defineExtension({actions:async()=>{await sleep(\(delay));return [{title:'Folder',wantsInitialDisplay:true,submenu:[{title:'\(title)',code:()=>{throw Error('must not execute')}}]}]}});"
    }
    var latest = PopulationState()
    pipeline.populate(
      try [
        job("first", root: root, source: initial("First", 120)),
        job("second", root: root, source: initial("Second", 0)),
      ], context: ActionContext(text: "fixture")
    ) { latest = $0 }
    for _ in 0..<200 {
      if latest.pending.isEmpty { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(latest.errors.isEmpty)
    XCTAssertEqual(
      latest.order.compactMap { latest.initial[$0]?.actions.first?["title"]?.string },
      ["First", "Second"])
    XCTAssertEqual(latest.initial["first"]?.path, [0])
  }
}
