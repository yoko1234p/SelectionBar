import AppKit
import CryptoKit
import Darwin

struct IconifyIdentifier: Hashable, Sendable {
  let prefix: String
  let name: String
  init?(_ source: String) {
    let parts = source.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "iconify",
      parts[1].range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
      parts[2].range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
      parts[1].count <= 80, parts[2].count <= 160
    else { return nil }
    prefix = String(parts[1])
    name = String(parts[2])
  }
  var url: URL { URL(string: "https://api.iconify.design/\(prefix)/\(name).svg")! }
  var key: String { prefix + ":" + name }
  var filename: String {
    SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".svg"
  }
}

/// Shared, bounded asynchronous icon fetching. Only a public icon identifier leaves the Mac.
/// Selected text, page URLs, package names and extension options are never request parameters.
@MainActor final class IconifyAssets {
  static let didChange = Notification.Name("SelectionBar.ExtensionIconAssetsDidChange")
  static let shared = IconifyAssets(
    directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("local.pakwingho.selectionbar/Iconify", isDirectory: true))
  typealias Loader = @Sendable (URL) async throws -> Data
  private final class Asset: NSObject {
    let document: SafeIconSVG.Document
    init(_ document: SafeIconSVG.Document) { self.document = document }
  }
  private let directory: URL?
  private let loader: Loader
  private let cache = NSCache<NSString, Asset>()
  private var tasks: [String: Task<Void, Never>] = [:]
  private var pending: [IconifyIdentifier] = []
  private var retryAfter: [String: Date] = [:]
  private var diskWasPruned = false

  init(directory: URL?, loader: @escaping Loader = { try await IconifyDownload.fetch($0) }) {
    self.directory = directory
    self.loader = loader
    cache.countLimit = 128
    cache.totalCostLimit = 4 * 1024 * 1024
  }

  func document(for identifier: IconifyIdentifier) -> SafeIconSVG.Document? {
    if let asset = cache.object(forKey: identifier.key as NSString) { return asset.document }
    guard tasks[identifier.key] == nil, !pending.contains(identifier),
      retryAfter[identifier.key].map({ $0 <= Date() }) ?? true,
      pending.count < 64
    else { return nil }
    pending.append(identifier)
    startPending()
    return nil
  }

  func cancel() {
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    pending.removeAll()
  }

  private func startPending() {
    while tasks.count < 3, !pending.isEmpty {
      let identifier = pending.removeFirst()
      let loader = loader
      let directory = directory
      let prune = !diskWasPruned
      diskWasPruned = true
      tasks[identifier.key] = Task { [weak self] in
        let worker = Task<SafeIconSVG.Document?, Never>.detached(priority: .utility) {
          if let directory {
            if prune { Self.prune(directory) }
            if let data = Self.read(identifier, directory: directory),
              let cached = SafeIconSVG.document(data)
            {
              return cached
            }
          }
          guard !Task.isCancelled else { return nil }
          do {
            let data = try await loader(identifier.url)
            guard !Task.isCancelled, let document = SafeIconSVG.document(data) else { return nil }
            if let directory {
              Self.write(document.data, identifier: identifier, directory: directory)
            }
            return document
          } catch { return nil }
        }
        let document = await withTaskCancellationHandler {
          await worker.value
        } onCancel: {
          worker.cancel()
        }
        guard let self, !Task.isCancelled else { return }
        tasks.removeValue(forKey: identifier.key)
        if let document {
          cache.setObject(
            Asset(document), forKey: identifier.key as NSString, cost: document.data.count)
          retryAfter.removeValue(forKey: identifier.key)
          NotificationCenter.default.post(name: Self.didChange, object: nil)
        } else {
          if retryAfter.count >= 256 { retryAfter = retryAfter.filter { $0.value > Date() } }
          if retryAfter.count >= 256 { retryAfter.removeAll(keepingCapacity: true) }
          retryAfter[identifier.key] = Date().addingTimeInterval(60)
        }
        startPending()
      }
    }
  }

  nonisolated private static func read(_ identifier: IconifyIdentifier, directory: URL) -> Data? {
    let descriptor = open(
      directory.appendingPathComponent(identifier.filename).path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { return nil }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_size > 0, info.st_size <= 512 * 1024,
      let data = try? handle.read(upToCount: 512 * 1024 + 1), data.count <= 512 * 1024
    else { return nil }
    return data
  }

  nonisolated private static func write(_ data: Data, identifier: IconifyIdentifier, directory: URL)
  {
    let manager = FileManager.default
    do {
      try manager.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      guard values.isDirectory == true, values.isSymbolicLink != true else { return }
      let file = directory.appendingPathComponent(identifier.filename)
      // This cache contains validated public SVG assets only. Complete file
      // protection makes newly closed files unreadable while macOS is locked,
      // defeating offline reads. Atomic replacement plus private permissions
      // keeps these nonsecret assets available without caching selection data.
      try data.write(to: file, options: .atomic)
      try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
      prune(directory)
    } catch {
      // A read-only or unavailable cache must not stop icon rendering.
    }
  }

  nonisolated private static func prune(_ directory: URL) {
    let manager = FileManager.default
    guard
      let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
      values.isDirectory == true, values.isSymbolicLink != true,
      let files = try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ], options: [.skipsHiddenFiles])
    else { return }
    var entries: [(URL, Int, Date)] = []
    for file in files
    where file.lastPathComponent.range(of: #"^[0-9a-f]{64}\.svg$"#, options: .regularExpression)
      != nil
    {
      guard
        let value = try? file.resourceValues(forKeys: [
          .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]), value.isRegularFile == true, value.isSymbolicLink != true
      else { continue }
      entries.append((file, value.fileSize ?? 0, value.contentModificationDate ?? .distantPast))
    }
    entries.sort { $0.2 > $1.2 }
    var total = 0
    for (index, entry) in entries.enumerated() {
      total += entry.1
      if index >= 256 || total > 16 * 1024 * 1024 { try? manager.removeItem(at: entry.0) }
    }
  }
}

/// A streaming delegate enforces the limit before receiving an unbounded HTTP body.
private final class IconifyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Failure: Error { case invalidResponse, oversized, cancelled }
  private var continuation: CheckedContinuation<Data, Error>?
  private var session: URLSession?
  private var bytes = Data()
  private let lock = NSLock()
  private var task: URLSessionDataTask?
  private var cancelled = false

  static func fetch(_ url: URL) async throws -> Data {
    let download = IconifyDownload()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { download.start(url, continuation: $0) }
    } onCancel: {
      download.cancel()
    }
  }

  private func start(_ url: URL, continuation: CheckedContinuation<Data, Error>) {
    lock.lock()
    if cancelled {
      lock.unlock()
      continuation.resume(throwing: Failure.cancelled)
      return
    }
    self.continuation = continuation
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 12
    configuration.timeoutIntervalForResource = 20
    configuration.httpMaximumConnectionsPerHost = 3
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    let task = session.dataTask(
      with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
    self.task = task
    lock.unlock()
    task.resume()
  }

  private func cancel() {
    lock.lock()
    cancelled = true
    let task = task
    lock.unlock()
    task?.cancel()
  }

  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }

  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      http.url?.scheme == "https", http.url?.host == "api.iconify.design",
      response.expectedContentLength <= 512 * 1024,
      ["image/svg+xml", "text/plain", "application/xml", "text/xml"].contains(
        http.mimeType?.lowercased() ?? "")
    else {
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard bytes.count <= 512 * 1024 - data.count else {
      dataTask.cancel()
      return
    }
    bytes.append(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let continuation = continuation
    self.continuation = nil
    self.task = nil
    self.session = nil
    lock.unlock()
    session.finishTasksAndInvalidate()
    if let error {
      continuation?.resume(throwing: error)
    } else if bytes.isEmpty {
      continuation?.resume(throwing: Failure.invalidResponse)
    } else {
      continuation?.resume(returning: bytes)
    }
  }
}
