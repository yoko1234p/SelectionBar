import Foundation
import XCTest

@testable import SelectionBarCore

final class WorkerSessionTests: XCTestCase {
  func testClosedRuntimeReaderThrowsWithoutSignallingHost() throws {
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()
    defer { try? pipe.fileHandleForWriting.close() }
    XCTAssertThrowsError(
      try LineProtocol.write(["fixture": "reply"], to: pipe.fileHandleForWriting))
  }
  private func executable() throws -> String {
    var directory = Bundle(for: Self.self).bundleURL
    for _ in 0..<7 {
      let candidate = directory.appendingPathComponent("SelectionBarRuntime")
      if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
      directory.deleteLastPathComponent()
    }
    throw XCTSkip("Build SelectionBarRuntime before worker integration tests")
  }
  func testRuntimeMultiplexesIndependentPromisesAndActualReplies() async throws {
    let session = ScriptSession(executable: try executable())
    let events = SessionEvents()
    let request = JavaScriptTests().request(
      "popclip.share('synthetic',['fixture']); const result=await popclip.runShortcut('synthetic'); await popclip.copyText(result); return result;"
    )
    let result = try await session.run(request) { effect in
      let type = effect["type"]?.string ?? ""
      await events.append(type)
      if type == "share" { try await Task.sleep(for: .milliseconds(90)) }
      await events.append(type + "-complete")
      return type == "shortcut" ? .string("native fixture reply") : .null
    }
    XCTAssertNil(result.error)
    XCTAssertEqual(result.result, .string("native fixture reply"))
    let order = await events.values
    let copy = try XCTUnwrap(order.firstIndex(of: "copy-complete"))
    let share = try XCTUnwrap(order.firstIndex(of: "share-complete"))
    XCTAssertLessThan(copy, share)
  }
  func testCancelBeforeLaunchDoesNotStartWorker() async throws {
    let session = ScriptSession(executable: try executable())
    session.cancel()
    do {
      _ = try await session.run(JavaScriptTests().request("await popclip.copyText('forbidden');")) {
        _ in
        XCTFail("Cancelled worker performed action")
        return .null
      }
      XCTFail("Cancelled session launched")
    } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
  }
  func testCancelTerminatesWorkerAndOwnedScriptGroup() async throws {
    let session = ScriptSession(executable: try executable())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SelectionBar-cancel-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("forbidden")
    let started = directory.appendingPathComponent("started")
    // TERM is deliberately ignored, so the grace-period group kill must stop
    // both the shell and its sleep even after the JavaScript worker exits.
    let source =
      "trap '' TERM; printf started > '" + started.path
      + "'; sleep 1; printf forbidden > '" + marker.path + "'"
    let literal = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
    let work = Task {
      try await session.run(
        JavaScriptTests().request(
          "await popclip.runShellScript(\(literal),{interpreter:'/bin/sh'});",
          entitlements: ["script"])
      ) { _ in .null }
    }
    let deadline = Date().addingTimeInterval(5)
    while !FileManager.default.fileExists(atPath: started.path), Date() < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: started.path), "Owned script never started")
    session.cancel()
    do { _ = try await work.value } catch {}
    try await Task.sleep(for: .milliseconds(1100))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }
  func testLateRequestCannotEnqueueNativeEffectAfterCancellation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = directory.appendingPathComponent("late-runtime.py")
    let code = """
      #!/usr/bin/python3
      import json, os, signal, sys, time
      os.setpgid(0, 0)
      signal.signal(signal.SIGTERM, signal.SIG_IGN)
      sys.stdin.readline()
      print(json.dumps({'type':'request','id':1,'effect':{'type':'barrier'}}), flush=True)
      time.sleep(0.08)
      print(json.dumps({'type':'request','id':2,'effect':{'type':'late-copy'}}), flush=True)
      time.sleep(2)
      """
    try Data(code.utf8).write(to: fixture)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
    let events = SessionEvents()
    let session = ScriptSession(executable: fixture.path)
    do {
      _ = try await session.run(JavaScriptTests().request("return 0;")) { effect in
        await events.append(effect["type"]?.string ?? "")
        session.cancel()
        return .null
      }
    } catch {}
    try await Task.sleep(for: .milliseconds(650))
    let values = await events.values
    XCTAssertEqual(values, ["barrier"])
  }
}

private actor SessionEvents {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
}
