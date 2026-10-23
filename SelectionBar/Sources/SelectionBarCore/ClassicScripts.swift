import Foundation

public enum ClassicScripts {
  public static func request(
    _ action: ExtensionAction, record: ExtensionRecord, context: ActionContext
  ) throws -> ScriptRequest {
    let config = action.config
    let variables = context.variables(
      options: record.options, extensionID: record.id, actionID: action.id)
    var record = record
    record.config["entitlements"] = .array(
      Array(Set((record.config["entitlements"]?.array.map(\.string) ?? []) + ["script"])).map(
        Value.string))
    var options: [String: Value] = [:]
    var function: String
    var argument: String
    if action.kind.hasPrefix("shell") {
      options["env"] = .object(
        variables.reduce(into: [String: Value]()) { result, item in
          result["POPCLIP_" + item.key] = .string(item.value)
        })
      options["shellMode"] = .string(config["shellmode"]?.string ?? "login")
      if let interpreter = config["interpreter"], !interpreter.string.isEmpty {
        options["interpreter"] = interpreter
      }
      if let file = config["shellscriptfile"]?.string {
        function = "runShellScriptFile"
        argument = file
        if options["interpreter"] == nil,
          !FileManager.default.isExecutableFile(atPath: record.packagePath + "/" + file),
          file.hasSuffix(".sh")
        {
          options["interpreter"] = .string("/bin/sh")
        }
        if let input = config["stdin"]?.string {
          options["stdin"] = .string(
            variables[input.uppercased().replacingOccurrences(of: " ", with: "_")] ?? "")
        }
      } else {
        function = "runShellScript"
        argument = config["shellscript"]?.string ?? ""
        if options["interpreter"] == nil { options["interpreter"] = .string("/bin/sh") }
      }
    } else {
      let call = config["applescriptcall"]?.object ?? [:]
      if let handler = call["handler"] { options["handler"] = handler }
      if options["handler"] != nil {
        options["parameters"] = .array(
          (call["parameters"]?.array.map(\.string) ?? []).map {
            .string(variables[$0.uppercased().replacingOccurrences(of: " ", with: "_")] ?? "")
          })
      }
      if let permissions = config["permissions"] ?? call["permissions"] {
        options["permissions"] = permissions
      }
      if let file = config["applescriptfile"]?.string, file.hasSuffix(".scpt") {
        function = "runAppleScriptFile"
        argument = file
      } else {
        function = "runAppleScript"
        let raw =
          try config["applescriptfile"].map {
            try String(
              contentsOf: Manifest.confinedFile(
                $0.string, root: URL(fileURLWithPath: record.packagePath)), encoding: .utf8)
          } ?? config["applescript"]?.string ?? ""
        argument = ActionMatcher.substituteAppleScript(raw, variables: variables)
      }
    }
    let argumentLiteral = String(decoding: try JSONEncoder().encode(argument), as: UTF8.self)
    let optionsLiteral = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
    var source =
      "const result=await popclip.\(function)(\(argumentLiteral),\(optionsLiteral)); return "
      + (action.kind.hasPrefix("shell") ? "result.stdout;" : "result;")
    if !action.kind.hasPrefix("shell") {
      source =
        "try {" + source
        + "} catch(error) { if(error.errorNumber === 502) popclip.showSettings(); throw error; }"
    }
    let generated = ExtensionAction(
      id: action.id, title: action.title, config: ["javascript": .string(source)])
    return ScriptRequest(record: record, action: generated, context: context)
  }
}
