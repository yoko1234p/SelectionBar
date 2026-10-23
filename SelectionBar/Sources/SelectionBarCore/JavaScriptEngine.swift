import Compression
import CryptoKit
import Foundation
import JavaScriptCore

public struct ScriptRequest: Codable, Sendable {
  public var record: ExtensionRecord
  public var action: ExtensionAction
  public var context: ActionContext
  public var phase: String
  public var moduleAction: Int?
  public var modulePath: [Int]?
  public var openSubmenu: Bool?
  public var clipboard: [String: String]
  public var authInfo: [String: Value]?
  public init(
    record: ExtensionRecord, action: ExtensionAction, context: ActionContext,
    phase: String = "action", moduleAction: Int? = nil, clipboard: [String: String] = [:],
    authInfo: [String: Value]? = nil, modulePath: [Int]? = nil, openSubmenu: Bool? = nil
  ) {
    self.record = record
    self.action = action
    self.context = context
    self.phase = phase
    self.moduleAction = moduleAction
    self.modulePath = modulePath
    self.openSubmenu = openSubmenu
    self.clipboard = clipboard
    self.authInfo = authInfo
  }
}
public struct ScriptResponse: Codable, Sendable {
  public var result: Value?
  public var effects: [[String: Value]]
  public var actions: [[String: Value]]
  public var options: [[String: Value]]
  public var error: String?
  public var authAvailable: Bool?
  public var didExecute: Bool?
  public var initialPath: [Int]?
  public var initialActions: [[String: Value]]?
  public init(
    result: Value? = nil, effects: [[String: Value]] = [], actions: [[String: Value]] = [],
    options: [[String: Value]] = [], error: String? = nil, authAvailable: Bool? = nil,
    didExecute: Bool? = nil, initialPath: [Int]? = nil, initialActions: [[String: Value]]? = nil
  ) {
    self.result = result
    self.effects = effects
    self.actions = actions
    self.options = options
    self.error = error
    self.authAvailable = authAvailable
    self.didExecute = didExecute
    self.initialPath = initialPath
    self.initialActions = initialActions
  }
}

public final class JavaScriptEngine {
  public init() {}
  public static func protocolError(_ message: String) -> String { errorJSON(message) }
  public func run(
    _ request: ScriptRequest, host: ((String) -> String)? = nil,
    hostAsync: ((String, @escaping (String) -> Void) -> Void)? = nil
  ) throws
    -> ScriptResponse
  {
    guard let context = JSContext() else {
      throw LibraryError.invalid(L10n.text("JavaScript 引擎無法啟動。"))
    }
    var exception: String?
    context.exceptionHandler = { _, error in exception = error?.toString() }
    let permitsEffects = ["action", "auth"].contains(request.phase)
    context.setObject(host != nil, forKeyedSubscript: "__hasHost" as NSString)
    let hostCallback: @convention(block) (String) -> String = { raw in
      guard permitsEffects else {
        return Self.errorJSON("Host actions unavailable during population")
      }
      return host?(raw) ?? "{}"
    }
    context.setObject(hostCallback, forKeyedSubscript: "__host" as NSString)
    let hostDispatcher = HostDispatcher()
    context.setObject(hostAsync != nil, forKeyedSubscript: "__hasAsyncHost" as NSString)
    let startHost: @convention(block) (String, JSValue) -> Int = { raw, callback in
      guard let hostAsync else { return 0 }
      return hostDispatcher.start(raw, callback: callback) { raw, completion in
        guard permitsEffects else {
          completion(Self.errorJSON("Host actions unavailable during population"))
          return
        }
        hostAsync(raw, completion)
      }
    }
    context.setObject(startHost, forKeyedSubscript: "__hostAsync" as NSString)
    let matchAction: @convention(block) (String, String) -> String = { raw, rawOptions in
      do {
        let data = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] ?? [:]
        let config = Manifest.normalized(data)
        let optionData =
          try JSONSerialization.jsonObject(with: Data(rawOptions.utf8))
          as? [String: Any] ?? [:]
        guard
          let matched = ActionMatcher.match(
            ExtensionAction(id: "runtime", title: "runtime", config: config),
            context: request.context, options: optionData.mapValues(Value.init))
        else { return "null" }
        return String(
          decoding: try JSONSerialization.data(withJSONObject: matched.inputObject), as: UTF8.self)
      } catch { return "null" }
    }
    let localize: @convention(block) (String) -> String = { raw in
      guard let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) else { return "" }
      return Manifest.localized(Value(any: object))
    }
    context.setObject(matchAction, forKeyedSubscript: "__matchAction" as NSString)
    context.setObject(localize, forKeyedSubscript: "__localize" as NSString)
    var timers: [Int: Timer] = [:]
    var timerSequence = 0
    let setTimer: @convention(block) (JSValue, Double) -> Int = { callback, milliseconds in
      timerSequence += 1
      let id = timerSequence
      timers[id] = Timer.scheduledTimer(
        withTimeInterval: max(0.001, milliseconds / 1000), repeats: false
      ) { _ in
        callback.call(withArguments: [])
        timers.removeValue(forKey: id)
      }
      return id
    }
    let clearTimer: @convention(block) (Int) -> Void = { id in
      timers.removeValue(forKey: id)?.invalidate()
    }
    context.setObject(setTimer, forKeyedSubscript: "__setTimer" as NSString)
    context.setObject(clearTimer, forKeyedSubscript: "__clearTimer" as NSString)
    defer { for timer in timers.values { timer.invalidate() } }
    let root = URL(fileURLWithPath: request.record.packagePath, isDirectory: true)
    let readModule: @convention(block) (String, String) -> String = { name, from in
      do {
        guard !name.hasPrefix("/"), !name.contains("\\") else {
          return Self.errorJSON("Module path outside extension package")
        }
        let parent = URL(fileURLWithPath: from).deletingLastPathComponent()
        let base = name.hasPrefix("./") || name.hasPrefix("../") ? parent : root
        let absolute = base.appendingPathComponent(name).standardizedFileURL
        guard absolute.path.hasPrefix(root.path + "/") else {
          return Self.errorJSON("Module path outside extension package")
        }
        let relative = String(absolute.path.dropFirst(root.path.count + 1))
        var path = try Manifest.confinedFile(relative, root: root)
        if !FileManager.default.fileExists(atPath: path.path) {
          for ext in ["js", "ts", "json"] {
            let candidate = path.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
              path = candidate
              break
            }
          }
        }
        guard FileManager.default.fileExists(atPath: path.path) else {
          return "{\"notFound\":true}"
        }
        let source = try Self.readSource(path)
        let result: [String: Any] = [
          "path": path.path, "format": path.pathExtension, "source": source,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
      } catch {
        return Self.errorJSON(
          L10n.text(
            "無法載入模組 %1$@：%2$@", String(describing: name),
            String(describing: error.localizedDescription)))
      }
    }
    context.setObject(readModule, forKeyedSubscript: "__readModule" as NSString)
    let utility: @convention(block) (String, String) -> String = { operation, input in
      do {
        let data = Data(input.utf8)
        switch operation {
        case "base64Encode": return data.base64EncodedString()
        case "base64Decode":
          var text = input.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
          text += String(repeating: "=", count: (4 - text.count % 4) % 4)
          guard let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
            let string = String(data: decoded, encoding: .utf8)
          else { return "" }
          return string
        case "uuid": return UUID().uuidString.lowercased()
        default: return ""
        }
      }
    }
    context.setObject(utility, forKeyedSubscript: "__utility" as NSString)
    let network: @convention(block) (String) -> String = { raw in
      guard ["action", "auth"].contains(request.phase),
        request.record.config["entitlements"]?.array.contains(.string("network")) == true
      else { return Self.errorJSON(L10n.text("此擴充未宣告 network 權限，或不在動作執行階段。")) }
      do { return try Self.http(raw) } catch { return Self.errorJSON(error.localizedDescription) }
    }
    context.setObject(network, forKeyedSubscript: "__http" as NSString)
    let httpDispatcher = HTTPDispatcher()
    let startHTTP: @convention(block) (String, JSValue) -> Int = { raw, callback in
      guard ["action", "auth"].contains(request.phase),
        request.record.config["entitlements"]?.array.contains(.string("network")) == true
      else {
        return httpDispatcher.reject(
          "Network entitlement required during action/auth", callback: callback)
      }
      do { return try httpDispatcher.start(raw, callback: callback) } catch {
        return httpDispatcher.reject(error.localizedDescription, callback: callback)
      }
    }
    let cancelHTTP: @convention(block) (Int) -> Void = { id in httpDispatcher.cancel(id) }
    context.setObject(startHTTP, forKeyedSubscript: "__httpStart" as NSString)
    context.setObject(cancelHTTP, forKeyedSubscript: "__httpCancel" as NSString)
    defer { httpDispatcher.cancelAll() }
    let external: @convention(block) (String) -> String = { raw in
      guard ["action", "auth"].contains(request.phase) else {
        return Self.errorJSON("Scripts unavailable during population")
      }
      do {
        guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
        else { throw LibraryError.invalid(L10n.text("無效腳本參數。")) }
        guard
          object["kind"] as? String == "shortcut"
            || request.record.config["entitlements"]?.array.contains(.string("script")) == true
        else {
          return Self.errorJSON(L10n.text("此擴充未宣告 script 權限。"))
        }
        if object["kind"] as? String == "applescript" {
          let required = try ExternalScripts.appleScriptPermissions(
            object["options"] as? [String: Any] ?? [:])
          if !required.isEmpty {
            guard let host else {
              throw LibraryError.invalid(
                "System permission approval requires SelectionBar's action host")
            }
            let raw = String(
              decoding: try JSONSerialization.data(withJSONObject: [
                "type": "permission", "permissions": required,
              ]), as: UTF8.self)
            guard
              let reply = try JSONSerialization.jsonObject(with: Data(host(raw).utf8))
                as? [String: Any]
            else {
              throw LibraryError.invalid("Invalid permission reply")
            }
            if let error = reply["error"] as? String { throw LibraryError.invalid(error) }
          }
        }
        let result = try ExternalScripts.run(object, root: root)
        return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
      } catch { return Self.errorJSON(error.localizedDescription) }
    }
    context.setObject(external, forKeyedSubscript: "__external" as NSString)
    let externalDispatcher = HostDispatcher()
    let scriptQueue = DispatchQueue(label: "local.pakwingho.selectionbar.external-scripts")
    let startExternal: @convention(block) (String, JSValue) -> Int = { raw, callback in
      externalDispatcher.start(raw, callback: callback) { raw, completion in
        scriptQueue.async { completion(external(raw)) }
      }
    }
    context.setObject(startExternal, forKeyedSubscript: "__externalAsync" as NSString)
    context.setObject(request.context.inputObject, forKeyedSubscript: "__input" as NSString)
    context.setObject(request.context.contextObject, forKeyedSubscript: "__context" as NSString)
    context.setObject(
      request.record.options.mapValues(\.any), forKeyedSubscript: "__storedOptions" as NSString)
    context.setObject(
      ExtensionOptions.effective(
        request.record.config["options"]?.array ?? [], stored: request.record.options
      ).mapValues(\.any), forKeyedSubscript: "__options" as NSString)
    context.setObject(request.clipboard, forKeyedSubscript: "__clipboard" as NSString)
    context.setObject(request.phase, forKeyedSubscript: "__phase" as NSString)
    context.setObject(request.record.id, forKeyedSubscript: "__extensionID" as NSString)
    context.setObject(
      request.authInfo?.mapValues(\.any) ?? [:], forKeyedSubscript: "__authInfo" as NSString)
    context.setObject(
      request.context.modifierFlags, forKeyedSubscript: "__modifierFlags" as NSString)
    JavaScriptNativeExtras.install(in: context)
    if let vendor = Bundle.module.url(forResource: "vendor-api", withExtension: "js") {
      context.evaluateScript(try String(contentsOf: vendor, encoding: .utf8))
    }
    guard let shimURL = Bundle.module.url(forResource: "compatibility", withExtension: "js") else {
      throw LibraryError.invalid("Missing extension compatibility runtime")
    }
    context.evaluateScript(try String(contentsOf: shimURL, encoding: .utf8))
    if let extras = Bundle.module.url(forResource: "api-extras", withExtension: "js") {
      context.evaluateScript(try String(contentsOf: extras, encoding: .utf8))
    }
    if let exception { throw LibraryError.invalid(exception) }
    var config = request.action.config
    config["__name"] = .string(request.action.title)
    context.setObject(config.mapValues(\.any), forKeyedSubscript: "__config" as NSString)
    context.setObject(root.path, forKeyedSubscript: "__packageRoot" as NSString)
    context.setObject(
      request.moduleAction.map { NSNumber(value: $0) } ?? NSNull(),
      forKeyedSubscript: "__moduleAction" as NSString)
    context.setObject(
      request.modulePath ?? request.moduleAction.map { [$0] } ?? [],
      forKeyedSubscript: "__modulePath" as NSString)
    context.setObject(request.openSubmenu == true, forKeyedSubscript: "__openSubmenu" as NSString)
    context.evaluateScript("__start();")
    if let exception { throw LibraryError.invalid(exception) }
    while context.objectForKeyedSubscript("__finished")?.toBool() != true || !timers.isEmpty
      || httpDispatcher.hasPending || hostDispatcher.hasPending || externalDispatcher.hasPending
    {
      hostDispatcher.drain()
      externalDispatcher.drain()
      httpDispatcher.drain()
      context.evaluateScript("void 0;")
      RunLoop.current.run(until: Date().addingTimeInterval(0.005))
      if exception != nil { break }
    }
    if let exception { throw LibraryError.invalid(exception) }
    guard context.objectForKeyedSubscript("__finished")?.toBool() == true else {
      throw LibraryError.invalid(L10n.text("JavaScript 動作逾時。"))
    }
    let responseString = context.objectForKeyedSubscript("__response")?.toString() ?? "{}"
    var response = try JSONDecoder().decode(ScriptResponse.self, from: Data(responseString.utf8))
    if response.error == nil,
      let effects = context.evaluateScript("JSON.stringify(__effects)")?.toString()
    {
      response.effects =
        (try? JSONDecoder().decode([[String: Value]].self, from: Data(effects.utf8)))
        ?? response.effects
    }
    return response
  }
  static func readSource(_ path: URL) throws -> String {
    guard (try path.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 32 * 1024 * 1024
    else {
      throw LibraryError.invalid(L10n.text("模組超出 32 MB。"))
    }
    let data = try Data(contentsOf: path)
    guard data.count <= 32 * 1024 * 1024 else {
      throw LibraryError.invalid(L10n.text("模組超出 32 MB。"))
    }
    if path.pathExtension == "lzfse" {
      for size in [1024 * 1024, 4 * 1024 * 1024, 16 * 1024 * 1024, 32 * 1024 * 1024] {
        var destination = [UInt8](repeating: 0, count: size)
        let count = data.withUnsafeBytes { raw in
          compression_decode_buffer(
            &destination, size, raw.bindMemory(to: UInt8.self).baseAddress!, data.count, nil,
            COMPRESSION_LZFSE)
        }
        if count > 0 && count < size {
          return String(decoding: destination.prefix(count), as: UTF8.self)
        }
      }
      throw LibraryError.invalid(L10n.text("無法解壓 JavaScript 模組。"))
    }
    return String(decoding: data, as: UTF8.self)
  }
  static func errorJSON(_ message: String) -> String {
    String(
      decoding: (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data(),
      as: UTF8.self)
  }
  static func http(_ raw: String) throws -> String {
    guard let config = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
      let string = config["url"] as? String, let url = URL(string: string),
      ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    else { throw LibraryError.invalid(L10n.text("無效 HTTP URL。")) }
    let milliseconds = (config["timeout"] as? Double) ?? 0
    let limit = milliseconds > 0 ? milliseconds / 1000 : TimeInterval.greatestFiniteMagnitude
    var request = URLRequest(url: url, timeoutInterval: limit)
    request.httpMethod = config["method"] as? String ?? "GET"
    for (name, value) in config["headers"] as? [String: String] ?? [:] {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let base64 = config["bodyBase64"] as? String {
      guard let bytes = Data(base64Encoded: base64) else {
        throw LibraryError.invalid("HTTP bodyBase64 invalid")
      }
      request.httpBody = bytes
    } else if let body = config["body"] as? String {
      request.httpBody = Data(body.utf8)
    }
    let semaphore = DispatchSemaphore(value: 0)
    var data: Data?
    var response: URLResponse?
    var error: Error?
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = limit
    configuration.timeoutIntervalForResource = limit
    let session = URLSession(configuration: configuration)
    let task = session.dataTask(with: request) { d, r, e in
      data = d
      response = r
      error = e
      semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: milliseconds > 0 ? .now() + limit + 1 : .distantFuture) == .timedOut
    {
      task.cancel()
      throw LibraryError.invalid(L10n.text("網路動作逾時。"))
    }
    session.finishTasksAndInvalidate()
    if let error { throw error }
    guard let data, data.count <= 8 * 1024 * 1024, let response = response as? HTTPURLResponse
    else { throw LibraryError.invalid(L10n.text("網路回應超出上限或無效。")) }
    let result: [String: Any] = [
      "status": response.statusCode,
      "headers": response.allHeaderFields.reduce(into: [String: String]()) { r, item in
        r[String(describing: item.key)] = String(describing: item.value)
      }, "body": String(decoding: data, as: UTF8.self),
    ]
    return String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
  }
}
