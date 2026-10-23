import Foundation
import Network
import XCTest

@testable import SelectionBarCore

final class HTTPTests: XCTestCase {
  func request(_ code: String, root: URL, network: Bool = true) -> ScriptRequest {
    let config: [String: Value] = [
      "javascript": .string(code), "entitlements": .array(network ? [.string("network")] : []),
    ]
    return ScriptRequest(
      record: ExtensionRecord(
        id: "dev.test.localhttp", name: "Local HTTP fixture", packagePath: root.path,
        digest: "synthetic", config: config, actions: []),
      action: ExtensionAction(id: "0", title: "Local HTTP", config: config),
      context: ActionContext(text: "fixture"))
  }
  func testRealAxiosReceivesLocalJSONThroughAsyncNativeTransport() throws {
    let server = try LocalHTTPFixture(delay: 0)
    defer { server.stop() }
    let code =
      "const axios=require('axios'); const r=await axios.post('http://127.0.0.1:\(server.port)/fixture',{text:'日'}, {headers:{'X-Synthetic':'yes'}}); return [r.status,r.data.ok,r.data.text];"
    let response = try JavaScriptEngine().run(
      request(code, root: FileManager.default.temporaryDirectory))
    XCTAssertNil(response.error)
    XCTAssertEqual(response.result, .array([.number(200), .bool(true), .string("日")]))
  }
  func testXHRAbortRunsWhileRequestIsPending() throws {
    let server = try LocalHTTPFixture(delay: 0.4)
    defer { server.stop() }
    let code =
      "return await new Promise((resolve,reject)=>{const x=new XMLHttpRequest();x.open('GET','http://127.0.0.1:\(server.port)/slow');x.onabort=()=>resolve('aborted');x.onerror=()=>reject(Error('unexpected error'));x.send();setTimeout(()=>x.abort(),10);});"
    let start = Date()
    let response = try JavaScriptEngine().run(
      request(code, root: FileManager.default.temporaryDirectory))
    XCTAssertEqual(response.result, .string("aborted"))
    XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
  }
  func testNetworkEntitlementRejectsLocalRequest() throws {
    let response = try JavaScriptEngine().run(
      request(
        "await require('axios').get('http://127.0.0.1:1/never');",
        root: FileManager.default.temporaryDirectory, network: false))
    XCTAssertNotNil(response.error)
  }
}
private final class LocalHTTPFixture: @unchecked Sendable {
  private let listener: NWListener
  private let queue = DispatchQueue(label: "SelectionBar.TestHTTP")
  private let delay: TimeInterval
  var port: UInt16 = 0
  init(delay: TimeInterval) throws {
    self.delay = delay
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { [weak self] state in
      if case .ready = state {
        self?.port = self?.listener.port?.rawValue ?? 0
        ready.signal()
      }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 2) == .success, port > 0 else {
      throw LibraryError.invalid("Test listener could not start")
    }
  }
  private func accept(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self] data, _, _, _ in
      guard let self, data != nil else {
        connection.cancel()
        return
      }
      self.queue.asyncAfter(deadline: .now() + self.delay) {
        let body = "{\"ok\":true,\"text\":\"日\"}"
        let header =
          "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(
          content: Data((header + body).utf8),
          completion: .contentProcessed { _ in connection.cancel() })
      }
    }
  }
  func stop() { listener.cancel() }
}
