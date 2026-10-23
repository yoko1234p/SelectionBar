import Foundation
import JavaScriptCore

/// Native replies may arrive on arbitrary threads. JavaScript values are
/// retained and invoked only by the engine's originating thread.
final class HostDispatcher {
  private let lock = NSLock()
  private var sequence = 0
  private var callbacks: [Int: JSValue] = [:]
  private var completions: [(Int, String)] = []

  var hasPending: Bool { !callbacks.isEmpty }

  func start(
    _ raw: String, callback: JSValue,
    transport: (String, @escaping (String) -> Void) -> Void
  ) -> Int {
    sequence += 1
    let id = sequence
    callbacks[id] = callback
    transport(raw) { [weak self] reply in
      guard let self else { return }
      self.lock.lock()
      self.completions.append((id, reply))
      self.lock.unlock()
    }
    return id
  }

  func drain() {
    lock.lock()
    let ready = completions
    completions.removeAll(keepingCapacity: true)
    lock.unlock()
    for (id, reply) in ready {
      callbacks.removeValue(forKey: id)?.call(withArguments: [reply])
    }
  }
}
