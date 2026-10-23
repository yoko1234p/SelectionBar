import Foundation

public enum LayoutTree {
  /// A disabled or missing ancestor suppresses its descendants. Corrupt cycles
  /// never trigger extension population or make navigation recursive.
  public static func enabledEntries(_ entries: [LayoutEntry]) -> [LayoutEntry] {
    let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return entries.filter { entry in
      guard entry.enabled else { return false }
      var parent = entry.parent
      var seen: Set<String> = [entry.id]
      while let id = parent {
        guard seen.insert(id).inserted,
          let ancestor = byID[id], ancestor.enabled, ancestor.isGroup
        else { return false }
        parent = ancestor.parent
      }
      return true
    }
  }
}
