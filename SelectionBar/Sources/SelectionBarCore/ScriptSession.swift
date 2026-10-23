import Darwin
import Foundation

public final class ScriptSession: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe(), output = Pipe(), errors = Pipe()
  private let lock = NSLock()
  private let writer = NSLock()
  private var cancelled = false
  private var tasks: [Int: Task<Void, Never>] = [:]
  private func isCancelled() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  public init(executable: String) {
    process.executableURL = URL(fileURLWithPath: executable)
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
  }
  public func cancel() {
    lock.lock()
    cancelled = true
    let running = process.isRunning
    let pid = running ? process.processIdentifier : 0
    let pending = Array(tasks.values)
    lock.unlock()
    for task in pending { task.cancel() }
    guard running else { return }
    kill(-pid, SIGTERM)
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
      // Descendants may ignore TERM after the runtime itself has exited.
      kill(-pid, SIGKILL)
      if self.process.isRunning {
        kill(pid, SIGKILL)
      }
    }
  }
  public func run(
    _ request: ScriptRequest, handler: @escaping @Sendable ([String: Value]) async throws -> Value
  ) async throws -> ScriptResponse {
    try await withTaskCancellationHandler {
      try await Task.detached { [self] in
        try launch()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        DispatchQueue.global().async {
          while let data = try? self.errors.fileHandleForReading.read(upToCount: 8192),
            !data.isEmpty
          {}
        }
        defer {
          finishTasks()
          try? input.fileHandleForWriting.close()
          if process.isRunning { cancel() }
          // This already runs on the detached reader thread. Reap the direct
          // runtime before releasing a FIFO admission barrier to its successor.
          process.waitUntilExit()
        }
        if isCancelled() { throw CancellationError() }
        try LineProtocol.write(request, to: input.fileHandleForWriting)
        let reader = LineReader(output.fileHandleForReading.fileDescriptor)
        var ordered: Task<Void, Never>?
        while let line = try reader.next() {
          if isCancelled() { throw CancellationError() }
          guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw LibraryError.invalid("Runtime protocol invalid")
          }
          if object["type"] as? String == "complete", let response = object["response"] {
            let data = try JSONSerialization.data(withJSONObject: response)
            return try JSONDecoder().decode(ScriptResponse.self, from: data)
          }
          guard object["type"] as? String == "request", let id = object["id"] as? Int,
            let raw = object["effect"] as? [String: Any]
          else { throw LibraryError.invalid("Runtime protocol invalid") }
          let effect = raw.mapValues(Value.init)
          // Text/clipboard/key operations retain their invocation order. Long
          // independent dialogs and shortcuts must not block the pipe reader.
          let isOrdered = [
            "copy", "paste", "copyContent", "pasteContent", "command", "key", "keys", "step",
          ]
          .contains(effect["type"]?.string ?? "")
          let predecessor = isOrdered ? ordered : nil
          let task = try enqueue(id: id) { [self] in
            await predecessor?.value
            do {
              try Task.checkCancellation()
              if isCancelled() { throw CancellationError() }
              let result = try await handler(effect)
              try reply(["id": .number(Double(id)), "result": result])
            } catch {
              try? reply(["id": .number(Double(id)), "error": .string(error.localizedDescription)])
            }
          }
          if isOrdered { ordered = task }
        }
        if isCancelled() { throw CancellationError() }
        throw LibraryError.invalid("Runtime ended before action completed")
      }.value
    } onCancel: {
      self.cancel()
    }
  }
  private func launch() throws {
    lock.lock()
    defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    try process.run()
  }
  private func reply(_ payload: [String: Value]) throws {
    writer.lock()
    defer { writer.unlock() }
    if isCancelled() { throw CancellationError() }
    try LineProtocol.write(payload, to: input.fileHandleForWriting)
  }
  private func enqueue(id: Int, operation: @escaping @Sendable () async -> Void) throws -> Task<
    Void, Never
  > {
    lock.lock()
    guard !cancelled else {
      lock.unlock()
      throw CancellationError()
    }
    let task = Task { [self] in
      await operation()
      removeTask(id)
    }
    tasks[id] = task
    lock.unlock()
    return task
  }
  private func removeTask(_ id: Int) {
    lock.lock()
    tasks.removeValue(forKey: id)
    lock.unlock()
  }
  private func finishTasks() {
    lock.lock()
    let pending = Array(tasks.values)
    tasks.removeAll()
    lock.unlock()
    for task in pending { task.cancel() }
  }
}
