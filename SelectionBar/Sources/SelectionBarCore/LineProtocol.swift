import Darwin
import Foundation

public final class LineReader {
  private let descriptor: Int32
  private var pending = Data()
  public init(_ descriptor: Int32) { self.descriptor = descriptor }
  public func next() throws -> Data? {
    while true {
      if let end = pending.firstIndex(of: 10) {
        let line = Data(pending[..<end])
        pending.removeSubrange(...end)
        return line
      }
      guard pending.count < 16 * 1024 * 1024 else {
        throw LibraryError.invalid("Runtime message exceeds 16 MB")
      }
      var buffer = [UInt8](repeating: 0, count: 8192)
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw LibraryError.invalid("Runtime pipe closed")
      }
      if count == 0 {
        if pending.isEmpty { return nil }
        let final = pending
        pending = Data()
        return final
      }
      pending.append(contentsOf: buffer.prefix(count))
    }
  }
}
public enum LineProtocol {
  public static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
    var data = try JSONEncoder().encode(value)
    data.append(10)
    // A cancelled runtime may close its reader between the session's state
    // check and this write. Return EPIPE instead of signalling the GUI process.
    guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try handle.write(contentsOf: data)
  }
}
