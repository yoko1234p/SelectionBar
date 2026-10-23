import Darwin
import Foundation
import SelectionBarCore

// Descendant scripts inherit an owned group, so Cancel stops the whole action.
guard setpgid(0, 0) == 0 || getpgrp() == getpid() else { exit(1) }
let reader = LineReader(STDIN_FILENO)
do {
  guard let data = try reader.next(), data.count <= 4 * 1024 * 1024 else {
    throw LibraryError.invalid("Invalid runtime request")
  }
  let request = try JSONDecoder().decode(ScriptRequest.self, from: data)
  let channel = RuntimeChannel(reader: reader)
  channel.start()
  let response = try JavaScriptEngine().run(
    request, host: { channel.exchange($0) }, hostAsync: { channel.send($0, completion: $1) })
  try LineProtocol.write(
    RuntimeCompletion(type: "complete", response: response), to: .standardOutput)
} catch {
  try? LineProtocol.write(
    RuntimeCompletion(
      type: "complete", response: ScriptResponse(error: error.localizedDescription)),
    to: .standardOutput)
  exit(1)
}

struct RuntimeCompletion: Encodable {
  var type: String
  var response: ScriptResponse
}

/// One reader multiplexes replies, allowing an unawaited share/auth operation
/// to coexist with other promises without blocking the JavaScript thread.
final class RuntimeChannel: @unchecked Sendable {
  private let reader: LineReader
  private let lock = NSLock()
  private let writer = NSLock()
  private var sequence = 0
  private var pending: [Int: (String) -> Void] = [:]
  private var closed = false
  init(reader: LineReader) { self.reader = reader }

  func start() {
    DispatchQueue.global().async { [self] in
      do {
        while let reply = try reader.next() {
          guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
            let id = object["id"] as? Int
          else { throw LibraryError.invalid("Invalid host reply") }
          let payload: [String: Any] =
            object["error"].map { ["error": $0] }
            ?? ["result": object["result"] ?? NSNull()]
          let json = String(
            decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
          lock.lock()
          let callback = pending.removeValue(forKey: id)
          lock.unlock()
          guard let callback else { throw LibraryError.invalid("Unknown host reply") }
          callback(json)
        }
        finish("Host disconnected")
      } catch { finish(error.localizedDescription) }
    }
  }

  func send(_ raw: String, completion: @escaping (String) -> Void) {
    do {
      let effect = try JSONDecoder().decode([String: Value].self, from: Data(raw.utf8))
      lock.lock()
      if closed {
        lock.unlock()
        completion(JavaScriptEngine.protocolError("Host disconnected"))
        return
      }
      sequence += 1
      let id = sequence
      pending[id] = completion
      lock.unlock()
      writer.lock()
      defer { writer.unlock() }
      try LineProtocol.write(
        ["type": Value.string("request"), "id": .number(Double(id)), "effect": .object(effect)],
        to: .standardOutput)
    } catch { finish(error.localizedDescription) }
  }

  func exchange(_ raw: String) -> String {
    let semaphore = DispatchSemaphore(value: 0)
    var result = "{}"
    send(raw) {
      result = $0
      semaphore.signal()
    }
    semaphore.wait()
    return result
  }

  private func finish(_ reason: String) {
    lock.lock()
    closed = true
    let callbacks = Array(pending.values)
    pending.removeAll()
    lock.unlock()
    for callback in callbacks { callback(JavaScriptEngine.protocolError(reason)) }
  }
}
