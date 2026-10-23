import Darwin
import Foundation

/// A script child joins its runtime's existing process group so cancelling that
/// runtime also reaches shell descendants. This helper never signals the group.
public enum OwnedProcess {
  public static func run(
    _ executable: String, _ arguments: [String], input: Data? = nil,
    environment: [String: String]? = nil, directory: URL? = nil,
    timeout: TimeInterval = 15, processGroup: pid_t
  ) throws -> ProcessResult {
    guard processGroup > 0, processGroup == getpgrp(), executable.hasPrefix("/"),
      !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }),
      timeout.isFinite, timeout >= 0, directory == nil || directory?.isFileURL == true
    else { throw LibraryError.invalid("Invalid owned process launch.") }
    let environment = environment ?? ProcessInfo.processInfo.environment
    guard
      environment.allSatisfy({ key, value in
        !key.isEmpty && !key.contains("=") && !key.contains("\0") && !value.contains("\0")
      })
    else { throw LibraryError.invalid("Invalid script environment.") }
    let argv = try CStringVector([executable] + arguments)
    let envp = try CStringVector(environment.map { "\($0.key)=\($0.value)" }.sorted())
    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    let handles = [
      stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading,
      stdout.fileHandleForWriting, stderr.fileHandleForReading, stderr.fileHandleForWriting,
    ]
    defer { for handle in handles { try? handle.close() } }
    guard handles.allSatisfy({ $0.fileDescriptor >= 3 }) else {
      throw LibraryError.invalid("Script launcher requires open standard descriptors.")
    }
    let reader = stdin.fileHandleForReading.fileDescriptor
    let writer = stdin.fileHandleForWriting.fileDescriptor
    let outReader = stdout.fileHandleForReading.fileDescriptor
    let errorReader = stderr.fileHandleForReading.fileDescriptor
    for descriptor in [writer, outReader, errorReader] {
      let flags = fcntl(descriptor, F_GETFL)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }
    guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var actions: posix_spawn_file_actions_t?
    try check(posix_spawn_file_actions_init(&actions))
    defer { posix_spawn_file_actions_destroy(&actions) }
    try check(posix_spawn_file_actions_adddup2(&actions, reader, STDIN_FILENO))
    try check(
      posix_spawn_file_actions_adddup2(
        &actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
    try check(
      posix_spawn_file_actions_adddup2(
        &actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
    for handle in handles {
      try check(posix_spawn_file_actions_addclose(&actions, handle.fileDescriptor))
    }
    if let directory {
      try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
    }
    var attributes: posix_spawnattr_t?
    try check(posix_spawnattr_init(&attributes))
    defer { posix_spawnattr_destroy(&attributes) }
    var defaults = sigset_t()
    var mask = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    sigemptyset(&mask)
    try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
    try check(posix_spawnattr_setsigmask(&attributes, &mask))
    try check(posix_spawnattr_setpgroup(&attributes, processGroup))
    try check(
      posix_spawnattr_setflags(
        &attributes,
        Int16(
          POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
    var pid: pid_t = 0
    let launched = argv.withPointers { args in
      envp.withPointers { env in
        posix_spawn(&pid, executable, &actions, &attributes, args, env)
      }
    }
    try check(launched)
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()

    let state = IOState()
    let output = BoundedOutput(8 * 1024 * 1024)
    let errors = BoundedOutput(1024 * 1024)
    let io = DispatchGroup()
    var reaped = false
    defer {
      if !reaped {
        kill(pid, SIGKILL)
        while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
      }
      state.finish()
      io.wait()
    }
    for (descriptor, sink, isError) in [(outReader, output, false), (errorReader, errors, true)] {
      io.enter()
      DispatchQueue.global().async {
        drain(descriptor, to: sink, state: state, isError: isError)
        io.leave()
      }
    }
    io.enter()
    DispatchQueue.global().async {
      write(input ?? Data(), to: writer, state: state)
      try? stdin.fileHandleForWriting.close()
      io.leave()
    }
    let deadline = timeout > 0 ? ProcessInfo.processInfo.systemUptime + timeout : .infinity
    var grace: TimeInterval?
    var failure: String?
    var sentKill = false
    var status: Int32 = 0
    while true {
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid {
        reaped = true
        break
      }
      if waited < 0 {
        if errno == EINTR { continue }
        if errno == ECHILD { reaped = true }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
      }
      let now = ProcessInfo.processInfo.systemUptime
      if failure == nil,
        let message = state.failure ?? (now >= deadline ? "Script timed out." : nil)
      {
        failure = message
        grace = now + 0.15
        kill(pid, SIGTERM)
      }
      if let grace, now >= grace, !sentKill {
        sentKill = true
        kill(pid, SIGKILL)
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    state.finish()
    io.wait()
    if let failure = failure ?? state.failure { throw LibraryError.invalid(failure) }
    let signal = status & 0x7f
    return ProcessResult(
      status: signal == 0 ? (status >> 8) & 0xff : signal,
      stdout: try output.result(), stderr: try errors.result(),
      terminationReason: signal == 0 ? "exit" : "uncaughtSignal")
  }

  private static func check(_ result: Int32) throws {
    if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
  }

  private final class CStringVector {
    private var values: [UnsafeMutablePointer<CChar>?] = []
    init(_ strings: [String]) throws {
      for string in strings {
        guard let pointer = strdup(string) else {
          for value in values { free(value) }
          values = []
          throw POSIXError(.ENOMEM)
        }
        values.append(pointer)
      }
      values.append(nil)
    }
    deinit { for value in values { free(value) } }
    func withPointers<T>(_ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
      values.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
  }

  private final class IOState: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var error: String?
    private var outputCount = 0, errorCount = 0
    var isFinished: Bool {
      lock.lock()
      defer { lock.unlock() }
      return ended
    }
    var failure: String? {
      lock.lock()
      defer { lock.unlock() }
      return error
    }
    func finish() {
      lock.lock()
      ended = true
      lock.unlock()
    }
    func failed(_ message: String) {
      lock.lock()
      if error == nil { error = message }
      lock.unlock()
    }
    func received(_ count: Int, isError: Bool) {
      lock.lock()
      defer { lock.unlock() }
      let limit = isError ? 1024 * 1024 : 8 * 1024 * 1024
      if isError {
        errorCount = min(limit + 1, errorCount + count)
      } else {
        outputCount = min(limit + 1, outputCount + count)
      }
      if (isError ? errorCount : outputCount) > limit, error == nil {
        error = "Script output exceeds capacity."
      }
    }
  }

  private static func drain(
    _ descriptor: Int32, to output: BoundedOutput, state: IOState, isError: Bool
  ) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      let count = Darwin.read(descriptor, &buffer, buffer.count)
      if count > 0 {
        state.received(count, isError: isError)
        output.append(Data(buffer.prefix(count)))
      } else if count == 0 {
        return
      } else if errno == EINTR {
        continue
      } else if errno == EAGAIN || errno == EWOULDBLOCK {
        if state.isFinished { return }
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        if poll(&event, 1, 50) < 0, errno != EINTR {
          state.failed("Script output pipe could not be read.")
          return
        }
      } else {
        state.failed("Script output pipe could not be read.")
        return
      }
    }
  }

  private static func write(_ data: Data, to descriptor: Int32, state: IOState) {
    data.withUnsafeBytes { bytes in
      guard let start = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count, !state.isFinished {
        let count = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
        if count > 0 {
          offset += count
        } else if count < 0, errno == EINTR {
          continue
        } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
          var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
          if poll(&event, 1, 50) < 0, errno != EINTR {
            state.failed("Script input pipe could not be written.")
            return
          }
        } else if count < 0, errno == EPIPE {
          return
        } else {
          state.failed("Script input pipe could not be written.")
          return
        }
      }
    }
  }
}
