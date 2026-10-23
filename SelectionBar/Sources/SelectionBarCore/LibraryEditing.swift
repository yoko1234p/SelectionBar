import Foundation

public struct LayoutRow: Identifiable, Sendable {
  public var entry: LayoutEntry
  public var depth: Int
  public var id: String { entry.id }
}

extension Library {
  public mutating func materializeInstanceOptions() {
    var first: Set<String> = []
    for index in layout.indices where layout[index].kind == 1 {
      guard let record = extensions.first(where: { $0.id == layout[index].provider }) else {
        continue
      }
      if layout[index].options == nil { layout[index].options = record.options }
      let isFirst = first.insert(record.id).inserted
      if layout[index].legacySecretFallback == nil { layout[index].legacySecretFallback = isFirst }
    }
    schema = max(schema, 2)
  }
  public func record(for entry: LayoutEntry) -> ExtensionRecord? {
    guard entry.kind == 1, var record = extensions.first(where: { $0.id == entry.provider }) else {
      return nil
    }
    record.options = entry.options ?? record.options
    record.instanceID = entry.id
    record.legacySecretFallback =
      entry.legacySecretFallback
      ?? (layout.first(where: { $0.provider == record.id })?.id == entry.id)
    return record
  }
  public func record(forSelection id: String?) -> ExtensionRecord? {
    guard let id else { return nil }
    let entry = layout.first { $0.id == id } ?? layout.first { $0.provider == id }
    return entry.flatMap(record(for:))
  }
  public var layoutRows: [LayoutRow] {
    var rows: [LayoutRow] = []
    var visited: Set<String> = []
    let children = Dictionary(grouping: layout, by: \.parent).mapValues {
      $0.sorted(by: layoutOrder)
    }
    func append(_ parent: String?, depth: Int) {
      guard depth < 32 else { return }
      for entry in children[parent] ?? [] {
        guard visited.insert(entry.id).inserted else { continue }
        rows.append(LayoutRow(entry: entry, depth: depth))
        if entry.isGroup { append(entry.id, depth: depth + 1) }
      }
    }
    append(nil, depth: 0)
    // Keep malformed imported orphans editable instead of silently discarding them.
    rows += layout.filter { !visited.contains($0.id) }.sorted(by: layoutOrder).map {
      LayoutRow(entry: $0, depth: 0)
    }
    return rows
  }
  private func layoutOrder(_ a: LayoutEntry, _ b: LayoutEntry) -> Bool {
    a.order == b.order ? a.id < b.id : a.order < b.order
  }
  public func descendants(of id: String) -> Set<String> {
    var result: Set<String> = []
    var queue = [id]
    while let parent = queue.popLast() {
      for child in layout where child.parent == parent && result.insert(child.id).inserted {
        queue.append(child.id)
      }
    }
    result.remove(id)
    return result
  }
  public mutating func createGroup(
    name: String, parent: String? = nil, icon: Value? = nil, color: String? = nil,
    id: String = UUID().uuidString
  ) throws -> String {
    try validateParent(parent)
    guard !layout.contains(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("項目識別碼已存在。"))
    }
    let title = try Self.validName(name)
    let order = (layout.filter { $0.parent == parent }.map(\.order).max() ?? -1000) + 1000
    layout.append(
      LayoutEntry(
        id: id, provider: "", name: title, order: order, parent: parent,
        kind: 2, icon: icon, color: color))
    return id
  }
  public mutating func createSeparator(parent: String? = nil) throws {
    try validateParent(parent)
    layout.append(
      LayoutEntry(
        id: UUID().uuidString, provider: "", name: L10n.text("分隔線"),
        order: (layout.filter { $0.parent == parent }.map(\.order).max() ?? -1000) + 1000,
        parent: parent, kind: 3))
  }
  public mutating func editEntry(
    _ id: String, name: String?, icon: Value?, color: String?, presentation: Int
  ) throws {
    guard let index = layout.firstIndex(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("找不到項目。"))
    }
    layout[index].name = try name.flatMap {
      $0.isEmpty && layout[index].kind == 1 ? nil : try Self.validName($0)
    }
    layout[index].icon = icon
    layout[index].color = color
    layout[index].presentation = presentation
  }
  public mutating func moveEntry(
    _ id: String, toParent parent: String?, before sibling: String? = nil
  ) throws {
    guard let index = layout.firstIndex(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("找不到要移動的項目。"))
    }
    try validateParent(parent)
    guard parent != id, parent.map({ !descendants(of: id).contains($0) }) ?? true else {
      throw LibraryError.invalid(L10n.text("資料夾不能移入自己或其子資料夾。"))
    }
    if let sibling {
      guard sibling != id, layout.contains(where: { $0.id == sibling && $0.parent == parent })
      else {
        throw LibraryError.invalid(L10n.text("排序目標已改變。"))
      }
    }
    let oldParent = layout[index].parent
    layout[index].parent = parent
    var siblings = layout.filter { $0.parent == parent && $0.id != id }.sorted(by: layoutOrder).map(
      \.id)
    let destination = sibling.flatMap { siblings.firstIndex(of: $0) } ?? siblings.count
    siblings.insert(id, at: destination)
    renumber(siblings)
    if oldParent != parent {
      renumber(layout.filter { $0.parent == oldParent }.sorted(by: layoutOrder).map(\.id))
    }
  }
  public mutating func moveEntry(_ id: String, by delta: Int) throws {
    guard let item = layout.first(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("找不到項目。"))
    }
    var siblings = layout.filter { $0.parent == item.parent }.sorted(by: layoutOrder).map(\.id)
    guard let current = siblings.firstIndex(of: id), siblings.indices.contains(current + delta)
    else { return }
    siblings.swapAt(current, current + delta)
    renumber(siblings)
  }
  public mutating func deleteEntry(_ id: String, keepChildren: Bool) throws {
    guard let entry = layout.first(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("找不到項目。"))
    }
    let children = layout.filter { $0.parent == id }.sorted(by: layoutOrder)
    if keepChildren {
      var siblings = layout.filter { $0.parent == entry.parent }.sorted(by: layoutOrder).map(\.id)
      let position = siblings.firstIndex(of: id) ?? siblings.count
      siblings.removeAll { $0 == id }
      siblings.insert(contentsOf: children.map(\.id), at: min(position, siblings.count))
      for index in layout.indices where layout[index].parent == id {
        layout[index].parent = entry.parent
      }
      layout.removeAll { $0.id == id }
      renumber(siblings)
    } else {
      let removed = descendants(of: id).union([id])
      layout.removeAll { removed.contains($0.id) }
      renumber(layout.filter { $0.parent == entry.parent }.sorted(by: layoutOrder).map(\.id))
    }
  }
  public mutating func duplicateEntry(_ id: String, name: String? = nil) throws -> String {
    guard let source = layout.first(where: { $0.id == id }) else {
      throw LibraryError.invalid(L10n.text("找不到項目。"))
    }
    let subtree = descendants(of: id).union([id])
    let originals = layoutRows.map(\.entry).filter { subtree.contains($0.id) }
    let identifiers = Dictionary(uniqueKeysWithValues: originals.map { ($0.id, UUID().uuidString) })
    for var item in originals {
      guard let newID = identifiers[item.id] else {
        throw LibraryError.invalid(L10n.text("無法複製此排列。"))
      }
      item.id = newID
      if let parent = item.parent, let replacement = identifiers[parent] {
        item.parent = replacement
      }
      item.options = item.options ?? extensions.first(where: { $0.id == item.provider })?.options
      item.legacySecretFallback = false
      if item.id == identifiers[id] {
        item.name =
          name ?? (source.name ?? record(for: source)?.name ?? L10n.text("項目")) + L10n.text(" 副本")
      }
      layout.append(item)
    }
    guard let newID = identifiers[id] else { throw LibraryError.invalid(L10n.text("無法複製此排列。")) }
    let siblings = layout.filter { $0.parent == source.parent && $0.id != newID }.sorted(
      by: layoutOrder
    ).map(\.id)
    let after = siblings.firstIndex(of: id).map { $0 + 1 } ?? siblings.count
    try moveEntry(
      newID, toParent: source.parent, before: after < siblings.count ? siblings[after] : nil)
    return newID
  }
  private func validateParent(_ parent: String?) throws {
    if let parent, !layout.contains(where: { $0.id == parent && $0.isGroup }) {
      throw LibraryError.invalid(L10n.text("目標資料夾不存在。"))
    }
  }
  private static func validName(_ name: String) throws -> String {
    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.count <= 200 else {
      throw LibraryError.invalid(L10n.text("名稱需要 1–200 個字元。"))
    }
    return value
  }
  private mutating func renumber(_ ids: [String]) {
    let order = Dictionary(
      uniqueKeysWithValues: ids.enumerated().map { ($0.element, Double($0.offset) * 1000) })
    for index in layout.indices {
      if let value = order[layout[index].id] { layout[index].order = value }
    }
  }
}
