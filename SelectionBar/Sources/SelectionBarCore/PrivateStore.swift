import Darwin
import Foundation

public enum PrivateStore {
  public static let maximumFileBytes = 64 * 1024 * 1024
  private static let lock = NSRecursiveLock()
  public static var root: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/SelectionBar", isDirectory: true)
  }
  public static func prepare(_ root: URL) throws {
    guard root.isFileURL else { throw LibraryError.invalid(L10n.text("設定資料夾不是本機位置。")) }
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw LibraryError.invalid(L10n.text("設定資料夾無法安全開啟，原檔已保留。"))
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
  }
  public static func load(at root: URL = root) throws -> Library {
    lock.lock()
    defer { lock.unlock() }
    guard let data = try existingData(root) else { return .initial }
    return try decode(data)
  }
  public static func save(_ library: Library, at root: URL = root) throws {
    lock.lock()
    defer { lock.unlock() }
    try validate(library)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(library)
    guard data.count <= maximumFileBytes else {
      throw LibraryError.invalid(L10n.text("設定超過 64 MB，未取代原有設定。"))
    }
    try prepare(root)
    // A caller using defaults after a load failure must never erase the failing file.
    if let existing = try existingData(root) { _ = try decode(existing) }
    let file = root.appendingPathComponent("library.json")
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  /// An additive installer migration must not materialize defaults into the
  /// user's settings or rewrite opaque extension configuration.
  public static func appendBuiltIns(_ ids: [String], at root: URL = root) throws {
    lock.lock()
    defer { lock.unlock() }
    guard let original = try existingData(root) else {
      var library = Library.initial
      for id in ids { try library.addBuiltIn(id) }
      try save(library, at: root)
      return
    }
    var library = try decode(original)
    let existingIDs = Set(library.layout.map(\.id))
    for id in ids { try library.addBuiltIn(id) }
    let added = library.layout.filter { !existingIDs.contains($0.id) }
    guard !added.isEmpty else { return }
    let encoded = try JSONEncoder().encode(added)
    guard let offset = layoutClosingOffset(original) else {
      throw LibraryError.invalid(L10n.text("未能定位原有動作清單；設定未有修改。"))
    }
    var proposed = original.prefix(offset)
    if !existingIDs.isEmpty { proposed.append(44) }
    proposed.append(contentsOf: encoded.dropFirst().dropLast())
    proposed.append(contentsOf: original.dropFirst(offset))
    guard proposed.count <= maximumFileBytes else {
      throw LibraryError.invalid(L10n.text("設定超過 64 MB。"))
    }
    _ = try decode(Data(proposed))
    try prepare(root)
    guard try existingData(root) == original else {
      throw LibraryError.invalid(L10n.text("設定剛被另一個程式修改，未有覆寫。"))
    }
    let file = root.appendingPathComponent("library.json")
    try proposed.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  private static func layoutClosingOffset(_ data: Data) -> Int? {
    let bytes = Array(data)
    var depth = 0
    var stringStart: Int?
    var escaped = false
    var key: String?
    var waiting = false
    var layoutDepth: Int?
    var closing: Int?
    var occurrences = 0
    for (index, byte) in bytes.enumerated() {
      if let start = stringStart {
        if escaped {
          escaped = false
        } else if byte == 92 {
          escaped = true
        } else if byte == 34 {
          if depth == 1 {
            key = try? JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
          }
          stringStart = nil
        }
        continue
      }
      if byte == 34 {
        stringStart = index
      } else if byte == 58 && depth == 1 {
        waiting = key == "layout"
      } else if byte == 91 || byte == 123 {
        depth += 1
        if waiting && depth == 2 && byte == 91 {
          layoutDepth = depth
          occurrences += 1
          waiting = false
        }
      } else if byte == 93 || byte == 125 {
        if byte == 93, depth == layoutDepth {
          closing = index
          layoutDepth = nil
        }
        depth -= 1
      }
    }
    return occurrences == 1 ? closing : nil
  }

  /// Explicit user recovery only. Preserve the existing directory entry itself,
  /// including an oversized file or a symlink; never read or modify its target.
  @discardableResult public static func recover(at root: URL = root) throws -> URL {
    lock.lock()
    defer { lock.unlock() }
    try prepare(root)
    let source = root.appendingPathComponent("library.json")
    var metadata = stat()
    guard lstat(source.path, &metadata) == 0,
      [S_IFREG, S_IFLNK].contains(metadata.st_mode & S_IFMT)
    else {
      throw LibraryError.invalid(L10n.text("找不到可保留的設定檔；沒有移除任何資料。"))
    }
    let folder = root.appendingPathComponent("Recovery", isDirectory: true)
    try prepare(folder)
    let target = folder.appendingPathComponent("library-" + UUID().uuidString + ".json")
    guard renamex_np(source.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if metadata.st_mode & S_IFMT == S_IFREG {
      let descriptor = open(target.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
      if descriptor >= 0 {
        defer { close(descriptor) }
        var archived = stat()
        if fstat(descriptor, &archived) == 0, archived.st_mode & S_IFMT == S_IFREG {
          guard fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
        }
      }
    }
    return target
  }

  private static func existingData(_ root: URL) throws -> Data? {
    guard root.isFileURL else { throw LibraryError.invalid(L10n.text("設定資料夾不是本機位置。")) }
    var directory = stat()
    if lstat(root.path, &directory) < 0 {
      if errno == ENOENT { return nil }
      throw LibraryError.invalid(L10n.text("設定資料夾無法讀取，原檔已保留。"))
    }
    guard directory.st_mode & S_IFMT == S_IFDIR else {
      throw LibraryError.invalid(L10n.text("設定資料夾不是普通資料夾，原檔已保留。"))
    }
    let file = root.appendingPathComponent("library.json")
    let descriptor = open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    if descriptor < 0 {
      if errno == ENOENT { return nil }
      throw LibraryError.invalid(L10n.text("設定檔無法讀取，已保留原檔；未使用預設值覆寫。"))
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
      metadata.st_size > 0, metadata.st_size <= maximumFileBytes
    else {
      throw LibraryError.invalid(L10n.text("設定檔不是可讀取的普通檔案，或超過 64 MB；已保留原檔。"))
    }
    guard let data = try handle.read(upToCount: maximumFileBytes + 1),
      data.count <= maximumFileBytes
    else {
      throw LibraryError.invalid(L10n.text("設定檔超過讀取限制，已保留原檔。"))
    }
    return data
  }
  private static func decode(_ data: Data) throws -> Library {
    do {
      var library = try JSONDecoder().decode(Library.self, from: data)
      try validate(library)
      library.materializeInstanceOptions()
      return library
    } catch {
      throw LibraryError.invalid(L10n.text("設定檔內容無法讀取，已保留原檔；請先處理設定檔復原。"))
    }
  }
  private static func validate(_ library: Library) throws {
    guard (1...2).contains(library.schema), library.layout.count <= 4096,
      library.extensions.count <= 1024,
      Set(library.layout.map(\.id)).count == library.layout.count,
      Set(library.extensions.map(\.id)).count == library.extensions.count
    else {
      throw LibraryError.invalid(L10n.text("設定版本或項目清單無法安全讀取；未取代原檔。"))
    }
  }
}
