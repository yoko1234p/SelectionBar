import Foundation

public enum ExtensionOptions {
  public static func effective(_ definitions: [Value], stored: [String: Value]) -> [String: Value] {
    var result = stored
    for definition in definitions {
      let option = Manifest.normalized(definition.object.mapValues(\.any))
      guard let id = option["identifier"]?.string, !id.isEmpty else { continue }
      let type = option["type"]?.string ?? "string"
      if ["heading", "password"].contains(type) {
        result.removeValue(forKey: id)
        continue
      }
      if let previous = option["migratefrom"]?.string,
        case .string(let migrated) = stored[previous],
        !migrated.isEmpty
      {
        result[id] = .string(migrated)
        continue
      }
      if result[id] != nil { continue }
      if type == "secret" {
        result[id] = .string("")
      } else if let value = option["defaultvalue"] {
        result[id] = value
      } else if type == "boolean" {
        result[id] = .bool(true)
      } else if type == "multiple", option["allownone"]?.bool != true {
        result[id] = option["values"]?.array.first ?? .string("")
      } else {
        result[id] = .string("")
      }
    }
    return result
  }
}
