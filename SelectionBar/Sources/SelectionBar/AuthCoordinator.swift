import AppKit
import LocalAuthentication
import Network
import Security
import SelectionBarCore

enum OwnSecrets {
  static let service = "local.pakwingho.selectionbar.extensions"
  static func read(record: ExtensionRecord, option: String = "authsecret") throws -> String? {
    if let value = try read(extensionID: record.secretIdentifier, option: option) { return value }
    guard record.instanceID != nil, record.legacySecretFallback == true,
      let value = try read(extensionID: record.id, option: option)
    else { return nil }
    let definition = record.config["options"]?.array.first {
      $0.object["identifier"]?.string == option
    }?.object
    let sync =
      definition?["keychain"]?.string != "local"
      && record.config["authkeychain"]?.string != "local"
    try write(value, extensionID: record.secretIdentifier, option: option, sync: sync)
    try write("", extensionID: record.id, option: option)
    return value
  }
  static func read(extensionID: String, option: String = "authsecret") throws -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: extensionID + "#" + option, kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
    ]
    let authentication = LAContext()
    authentication.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = authentication
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = item as? Data else {
      throw LibraryError.invalid(L10n.text("無法讀取 SelectionBar 鑰匙圈選項。"))
    }
    return String(data: data, encoding: .utf8)
  }
  static func write(
    _ text: String, extensionID: String, option: String = "authsecret", sync: Bool = false
  ) throws {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: extensionID + "#" + option,
    ]
    if text.isEmpty {
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
      SecItemDelete(query as CFDictionary)
      return
    }
    let attributes: [String: Any] = [
      kSecValueData as String: Data(text.utf8),
      kSecAttrAccessible as String: sync
        ? kSecAttrAccessibleWhenUnlocked : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    query[kSecAttrSynchronizable as String] = sync
    let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if update == errSecItemNotFound {
      var insertion = query
      insertion.merge(attributes) { _, new in new }
      let status = SecItemAdd(insertion as CFDictionary, nil)
      guard status == errSecSuccess else {
        throw LibraryError.invalid(L10n.text("無法儲存 SelectionBar 鑰匙圈選項。"))
      }
    } else if update != errSecSuccess {
      throw LibraryError.invalid(L10n.text("無法更新 SelectionBar 鑰匙圈選項。"))
    }
  }
}

@MainActor
final class AuthCoordinator {
  private var listener: NWListener?
  private var ready: CheckedContinuation<String, Error>?
  private var pending: CheckedContinuation<Value, Error>?
  private var expectedState = ""
  private var callbackPath = ""
  private var expectedKeys: [String] = []
  func prepare(extensionID: String) async throws -> String {
    cancel()
    callbackPath = "/callback/" + extensionID + "/auth"
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters, on: .any)
    self.listener = listener
    listener.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.receive(connection) }
    }
    return try await withCheckedThrowingContinuation { continuation in
      ready = continuation
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready:
            guard let port = self.listener?.port else { return }
            self.ready?.resume(returning: "http://127.0.0.1:\(port.rawValue)" + self.callbackPath)
            self.ready = nil
          case .failed(let error):
            self.ready?.resume(throwing: error)
            self.ready = nil
            self.cancel()
          default: break
          }
        }
      }
      listener.start(queue: DispatchQueue(label: "SelectionBar.OAuth.Loopback"))
    }
  }
  func flow(_ effect: [String: Value]) async throws -> Value {
    guard let raw = effect["url"]?.string, var components = URLComponents(string: raw),
      ["https", "http"].contains(components.scheme?.lowercased() ?? ""), listener != nil
    else { throw LibraryError.invalid(L10n.text("OAuth 登入 URL 無效。")) }
    var items = components.queryItems ?? []
    for (key, value) in effect["params"]?.object ?? [:] {
      items.removeAll { $0.name == key }
      items.append(URLQueryItem(name: key, value: value.string))
    }
    if let state = items.first(where: { $0.name == "state" })?.value, !state.isEmpty {
      expectedState = state
    } else {
      expectedState = UUID().uuidString
      items.append(URLQueryItem(name: "state", value: expectedState))
    }
    components.queryItems = items
    expectedKeys = effect["expect"]?.array.map(\.string) ?? []
    guard let url = components.url else { throw LibraryError.invalid(L10n.text("OAuth URL 無法建立。")) }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        pending = continuation
        if !NSWorkspace.shared.open(url) {
          pending = nil
          continuation.resume(throwing: LibraryError.invalid(L10n.text("無法開啟登入頁面。")))
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  private func receive(_ connection: NWConnection) {
    connection.start(queue: DispatchQueue(label: "SelectionBar.OAuth.Callback"))
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
      [weak self] data, _, _, error in
      Task { @MainActor in
        guard let self else { return }
        guard error == nil, let data, let request = String(data: data, encoding: .utf8),
          let line = request.components(separatedBy: "\r\n").first
        else {
          connection.cancel()
          return
        }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET",
          let url = URLComponents(string: "http://127.0.0.1" + fields[1]),
          url.path == self.callbackPath
        else {
          connection.cancel()
          return
        }
        let parameters = Dictionary(
          (url.queryItems ?? []).map { ($0.name, Value.string($0.value ?? "")) },
          uniquingKeysWith: { _, new in new })
        guard parameters["state"]?.string == self.expectedState else {
          self.pending?.resume(throwing: LibraryError.invalid(L10n.text("OAuth state 驗證失敗。")))
          self.pending = nil
          self.cancel()
          connection.cancel()
          return
        }
        let body = "SelectionBar sign-in received. You can close this page."
        let response =
          "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
          + body
        connection.send(
          content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        if let error = parameters["error"]?.string {
          self.pending?.resume(throwing: LibraryError.invalid("OAuth：" + error))
        } else if self.expectedKeys.contains(where: { parameters[$0] == nil }) {
          self.pending?.resume(throwing: LibraryError.invalid(L10n.text("OAuth 回應缺少必要欄位。")))
        } else {
          self.pending?.resume(returning: .object(parameters))
        }
        self.pending = nil
        self.listener?.cancel()
        self.listener = nil
      }
    }
  }
  func cancel() {
    listener?.cancel()
    listener = nil
    ready?.resume(throwing: CancellationError())
    ready = nil
    pending?.resume(throwing: CancellationError())
    pending = nil
  }
}
