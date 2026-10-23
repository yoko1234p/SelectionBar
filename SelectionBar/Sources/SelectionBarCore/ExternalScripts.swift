import AppKit
import Carbon
import Foundation

enum ExternalScripts {
  static func appleScriptPermissions(_ options: [String: Any]) throws -> [String] {
    guard Set(options.keys).isSubset(of: ["handler", "parameters", "permissions"]) else {
      throw LibraryError.invalid("Unknown AppleScript option")
    }
    if let handler = options["handler"], !(handler is String) {
      throw LibraryError.invalid("AppleScript handler must be a string")
    }
    if let parameters = options["parameters"] {
      guard let values = parameters as? [Any],
        values.allSatisfy({ value in
          value is String
            || (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } == true
        }),
        (options["handler"] as? String)?.isEmpty == false
      else {
        throw LibraryError.invalid(
          "AppleScript parameters require a handler and string/boolean values")
      }
    }
    guard options["permissions"] == nil || options["permissions"] is [String] else {
      throw LibraryError.invalid("AppleScript permissions must be a list")
    }
    let permissions = options["permissions"] as? [String] ?? []
    guard permissions.allSatisfy({ $0 == "reminders" }) else {
      throw LibraryError.invalid("Unknown AppleScript system permission")
    }
    return Array(Set(permissions)).sorted()
  }
  static func run(_ object: [String: Any], root: URL) throws -> [String: Any] {
    let kind = object["kind"] as? String ?? "shell"
    let source = object["source"] as? String ?? ""
    let options = object["options"] as? [String: Any] ?? [:]
    if kind == "browser" { return try BrowserBridge.run(object) }
    if kind == "shortcut" {
      guard let name = object["name"] as? String,
        object["input"] == nil || object["input"] is String
      else {
        throw LibraryError.invalid("Shortcut requires a name and optional string input")
      }
      return try ShortcutBridge.run(name: name, input: object["input"] as? String)
    }
    if kind == "shell" {
      let allowed: Set<String> = ["interpreter", "shellMode", "env", "stdin", "arguments"]
      guard Set(options.keys).isSubset(of: allowed) else {
        throw LibraryError.invalid("Unknown ShellScript option")
      }
      let file = try (object["path"] as? String).map { try Manifest.confinedFile($0, root: root) }
      let interpreter = options["interpreter"] as? String ?? ""
      guard file != nil || !interpreter.isEmpty else {
        throw LibraryError.invalid("runShellScript requires interpreter")
      }
      var executable =
        interpreter.isEmpty ? "" : try InterpreterResolver.resolve(interpreter, directory: root)
      var args: [String] = []
      if let file {
        if interpreter.isEmpty {
          guard FileManager.default.isExecutableFile(atPath: file.path),
            try String(contentsOf: file, encoding: .utf8).hasPrefix("#!")
          else { throw LibraryError.invalid("Executable script needs a shebang or interpreter") }
          executable = file.path
          args = []
        } else {
          args.append(file.path)
        }
        args += options["arguments"] as? [String] ?? []
      }
      let input = file != nil ? Data((options["stdin"] as? String ?? "").utf8) : Data(source.utf8)
      var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
      environment.merge(options["env"] as? [String: String] ?? [:]) { _, new in new }
      let mode = options["shellMode"] as? String ?? "none"
      if mode != "none" {
        guard ["login", "nonlogin"].contains(mode) else {
          throw LibraryError.invalid("Invalid shellMode")
        }
        let target = executable
        let parameters = args
        executable = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        args =
          (mode == "login" ? ["-l"] : []) + ["-c", "exec \"$@\"", "selectionbar-script", target]
          + parameters
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
      }
      let result = try ProcessRunner.run(
        executable, args, input: input, environment: environment, directory: root, timeout: 0,
        processGroup: getpgrp())
      var reply: [String: Any] = [
        "stdout": result.stdout, "stderr": result.stderr, "status": result.status,
        "terminationReason": result.terminationReason,
      ]
      if result.status != 0 {
        reply["error"] =
          result.terminationReason == "uncaughtSignal"
          ? "Script terminated by signal \(result.status)"
          : "Script exited with status \(result.status)"
      }
      return reply
    }
    guard kind == "applescript" else { throw LibraryError.invalid("Unsupported script kind") }
    _ = try appleScriptPermissions(options)
    var error: NSDictionary?
    let script: NSAppleScript?
    if let path = object["path"] as? String {
      let file = try Manifest.confinedFile(path, root: root)
      guard ["applescript", "scpt"].contains(file.pathExtension) else {
        throw LibraryError.invalid("AppleScript file must be .applescript or .scpt")
      }
      script = NSAppleScript(contentsOf: file, error: &error)
    } else {
      script = NSAppleScript(source: source)
    }
    guard let script else { throw LibraryError.invalid("Cannot load AppleScript") }
    let result: NSAppleEventDescriptor
    if let handler = options["handler"] as? String, !handler.isEmpty {
      let event = NSAppleEventDescriptor(
        eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
      event.setDescriptor(
        NSAppleEventDescriptor(string: handler), forKeyword: AEKeyword(keyASSubroutineName))
      let parameters = NSAppleEventDescriptor.list()
      for (index, value) in (options["parameters"] as? [Any] ?? []).enumerated() {
        parameters.insert(descriptor(value), at: index + 1)
      }
      event.setParam(parameters, forKeyword: AEKeyword(keyDirectObject))
      result = script.executeAppleEvent(event, error: &error)
    } else {
      result = script.executeAndReturnError(&error)
    }
    if let error {
      return [
        "error": error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed",
        "errorNumber": error[NSAppleScript.errorNumber] as? Int ?? -1,
      ]
    }
    return ["value": value(result)]
  }
  private static func descriptor(_ value: Any) -> NSAppleEventDescriptor {
    if let string = value as? String { return NSAppleEventDescriptor(string: string) }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        return NSAppleEventDescriptor(boolean: number.boolValue)
      }
      return NSAppleEventDescriptor(double: number.doubleValue)
    }
    if let values = value as? [Any] {
      let list = NSAppleEventDescriptor.list()
      for (index, item) in values.enumerated() { list.insert(descriptor(item), at: index + 1) }
      return list
    }
    return NSAppleEventDescriptor.null()
  }
  static func value(_ result: NSAppleEventDescriptor) -> Any {
    switch result.descriptorType {
    case typeAEList:
      return (1...max(1, result.numberOfItems)).compactMap { result.atIndex($0).map(value) }
    case typeBoolean: return result.booleanValue
    case typeTrue: return true
    case typeFalse: return false
    case typeSInt16, typeSInt32, typeUInt32: return result.int32Value
    case typeIEEE64BitFloatingPoint, typeIEEE32BitFloatingPoint: return result.doubleValue
    case typeNull: return NSNull()
    default: return result.stringValue ?? ""
    }
  }
}
