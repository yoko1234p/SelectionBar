import Foundation

/// Unlike an `actions` array, submenu children are complete action definitions.
/// A parent's filter, command and pre/post steps do not become child defaults.
public enum ActionCatalog {
  public static func children(
    of action: ExtensionAction, name: String, context: ActionContext,
    options: [String: Value]
  ) -> [ExtensionAction] {
    let raw = action.config["submenu"]
    let values: [Value]
    if case .array(let array) = raw { values = array } else { values = raw.map { [$0] } ?? [] }
    return values.enumerated().compactMap { index, value in
      guard case .object(let object) = value else { return nil }
      let config = Manifest.normalized(object.mapValues(\.any))
      let child = ExtensionAction(
        id: config["identifier"]?.string ?? String(index),
        title: Manifest.localized(config["title"], fallback: name), config: config)
      return child.kind == "separator"
        || ActionMatcher.match(child, context: context, options: options) != nil ? child : nil
    }
  }
}
