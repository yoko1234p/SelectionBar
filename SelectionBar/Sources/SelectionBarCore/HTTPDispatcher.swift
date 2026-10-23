import Foundation
import JavaScriptCore

final class HTTPDispatcher: @unchecked Sendable {
  private let lock = NSLock()
  private var sequence = 0
  private var transfers: [Int: HTTPTransfer] = [:]
  private var completions: [(JSValue, String)] = []
  var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !transfers.isEmpty || !completions.isEmpty
  }
  func start(_ raw: String, callback: JSValue) throws -> Int {
    let request = try Self.request(raw)
    sequence += 1
    let id = sequence
    let transfer = HTTPTransfer(request: request) { [weak self] result in
      guard let self else { return }
      self.lock.lock()
      self.completions.append((callback, result))
      self.transfers.removeValue(forKey: id)
      self.lock.unlock()
    }
    lock.lock()
    transfers[id] = transfer
    lock.unlock()
    transfer.start()
    return id
  }
  func reject(_ message: String, callback: JSValue) -> Int {
    sequence += 1
    let id = sequence
    lock.lock()
    completions.append((callback, JavaScriptEngine.protocolError(message)))
    lock.unlock()
    return id
  }
  func cancel(_ id: Int) {
    lock.lock()
    let transfer = transfers[id]
    lock.unlock()
    transfer?.cancel()
  }
  func drain() {
    lock.lock()
    let ready = completions
    completions = []
    lock.unlock()
    for (callback, json) in ready { callback.call(withArguments: [json]) }
  }
  func cancelAll() {
    lock.lock()
    let active = Array(transfers.values)
    transfers = [:]
    completions = []
    lock.unlock()
    for transfer in active { transfer.cancel() }
  }
  static func request(_ raw: String) throws -> URLRequest {
    guard let config = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
      let string = config["url"] as? String, let url = URL(string: string),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { throw LibraryError.invalid(L10n.text("HTTP URL 無效。")) }
    let ms = config["timeout"] as? Double ?? 0
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: ms > 0 ? ms / 1000 : TimeInterval.greatestFiniteMagnitude)
    request.httpMethod = config["method"] as? String ?? "GET"
    for (name, value) in config["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let body = config["bodyBase64"] as? String {
      guard let bytes = Data(base64Encoded: body) else {
        throw LibraryError.invalid(L10n.text("HTTP bodyBase64 無效。"))
      }
      request.httpBody = bytes
    } else if let body = config["body"] as? String {
      request.httpBody = Data(body.utf8)
    }
    return request
  }
}

private final class HTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let request: URLRequest
  private let completion: (String) -> Void
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var bytes = Data()
  private var response: HTTPURLResponse?
  private var forcedError: String?
  init(request: URLRequest, completion: @escaping (String) -> Void) {
    self.request = request
    self.completion = completion
  }
  func start() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = request.timeoutInterval
    configuration.timeoutIntervalForResource = request.timeoutInterval
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    self.session = session
    task = session.dataTask(with: request)
    task?.resume()
  }
  func cancel() { task?.cancel() }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    self.response = response as? HTTPURLResponse
    if response.expectedContentLength > 64 * 1024 * 1024 {
      forcedError = "HTTP response exceeds64 MB"
      completionHandler(.cancel)
    } else {
      completionHandler(.allow)
    }
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    if bytes.count + data.count > 64 * 1024 * 1024 {
      forcedError = "HTTP response exceeds64 MB"
      dataTask.cancel()
    } else {
      bytes.append(data)
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    defer {
      session.finishTasksAndInvalidate()
      self.session = nil
      self.task = nil
    }
    if let error = forcedError ?? error?.localizedDescription {
      completion(JavaScriptEngine.protocolError(error))
      return
    }
    guard let response else {
      completion(JavaScriptEngine.protocolError("Missing HTTP response"))
      return
    }
    let result: [String: Any] = [
      "status": response.statusCode,
      "headers": response.allHeaderFields.reduce(into: [String: String]()) { result, item in
        result[String(describing: item.key)] = String(describing: item.value)
      }, "body": String(decoding: bytes, as: UTF8.self), "bodyBase64": bytes.base64EncodedString(),
      "responseURL": response.url?.absoluteString ?? request.url?.absoluteString ?? "",
    ]
    completion(
      String(
        decoding: (try? JSONSerialization.data(withJSONObject: result)) ?? Data(), as: UTF8.self))
  }
}
