import Foundation

public struct ProcessResult: Sendable {
  public var status: Int32
  public var stdout: String
  public var stderr: String
  public var terminationReason: String
}

final class BoundedOutput: @unchecked Sendable {
  let limit: Int
  private let lock = NSLock()
  private var data = Data()
  private var exceeded = false
  init(_ limit: Int) { self.limit = limit }
  func append(_ chunk: Data) {
    lock.lock()
    let remaining = max(0, limit - data.count)
    data.append(chunk.prefix(remaining))
    exceeded = exceeded || chunk.count > remaining
    lock.unlock()
  }
  func drain(_ handle: FileHandle) {
    while let chunk = try? handle.read(upToCount: 65536), !chunk.isEmpty {
      append(chunk)
    }
  }
  func result() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    guard !exceeded else { throw LibraryError.invalid(L10n.text("腳本輸出超出容量上限。")) }
    return String(decoding: data, as: UTF8.self)
  }
}

public enum ProcessRunner {
  public static func run(
    _ executable: String, _ arguments: [String], input: Data? = nil,
    environment: [String: String]? = nil, directory: URL? = nil, timeout: TimeInterval = 15,
    processGroup: pid_t? = nil
  ) throws -> ProcessResult {
    if let processGroup {
      return try OwnedProcess.run(
        executable, arguments, input: input, environment: environment,
        directory: directory, timeout: timeout, processGroup: processGroup)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    if let environment { process.environment = environment }
    let output = Pipe()
    let errors = Pipe()
    let stdin = Pipe()
    process.standardOutput = output
    process.standardError = errors
    process.standardInput = stdin
    let group = DispatchGroup()
    let stdout = BoundedOutput(8 * 1024 * 1024)
    let stderr = BoundedOutput(1024 * 1024)
    group.enter()
    DispatchQueue.global().async {
      stdout.drain(output.fileHandleForReading)
      group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
      stderr.drain(errors.fileHandleForReading)
      group.leave()
    }
    do { try process.run() } catch {
      try? output.fileHandleForWriting.close()
      try? errors.fileHandleForWriting.close()
      throw error
    }
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
    if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
    try stdin.fileHandleForWriting.close()
    let deadline = timeout > 0 ? Date().addingTimeInterval(timeout) : Date.distantFuture
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
      process.terminate()
      Thread.sleep(forTimeInterval: 0.1)
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
      throw LibraryError.invalid(L10n.text("動作執行逾時，已停止。"))
    }
    process.waitUntilExit()
    group.wait()
    return ProcessResult(
      status: process.terminationStatus, stdout: try stdout.result(), stderr: try stderr.result(),
      terminationReason: process.terminationReason == .uncaughtSignal ? "uncaughtSignal" : "exit")
  }
}
