import AppKit
import SelectionBarCore
import SwiftUI
import UniformTypeIdentifiers

struct ActionListView: View {
  @ObservedObject var model: SelectionModel
  @State private var query = ""
  @State private var collapsed: Set<String> = []
  @State private var editing: EntryDraft?
  @State private var showBuiltIns = false
  @State private var filter = "all"
  private var rows: [LayoutRow] {
    let ordered = model.library.layoutRows
    if !query.isEmpty || filter != "all" {
      let parents = Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.entry.parent) })
      var matching: Set<String> = []
      for row in ordered
      where
        (query.isEmpty || model.title(row.entry).localizedCaseInsensitiveContains(query)
        || row.entry.provider.localizedCaseInsensitiveContains(query))
        && (filter == "all" || row.entry.enabled == (filter == "enabled"))
      {
        matching.insert(row.id)
        var parent = row.entry.parent
        var visited: Set<String> = []
        while let id = parent, visited.insert(id).inserted {
          matching.insert(id)
          parent = parents[id] ?? nil
        }
      }
      return ordered.filter { matching.contains($0.id) }
    }
    var hiddenBelow: Int?
    return ordered.filter { row in
      if let depth = hiddenBelow, row.depth <= depth { hiddenBelow = nil }
      guard hiddenBelow == nil else { return false }
      if row.entry.isGroup, collapsed.contains(row.id) { hiddenBelow = row.depth }
      return true
    }
  }
  var body: some View {
    let displayedRows = rows
    return VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField(L10n.text("搜尋動作、資料夾或擴充"), text: $query).textFieldStyle(.plain)
          .accessibilityIdentifier("selectionbar.actions.search")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain)
        }
      }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 9)).padding(12)
      Picker(L10n.text("篩選動作"), selection: $filter) {
        Text(L10n.text("全部")).tag("all")
        Text(L10n.text("已啟用")).tag("enabled")
        Text(L10n.text("已停用")).tag("disabled")
      }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 12).padding(.bottom, 6)
        .accessibilityIdentifier("selectionbar.actions.filter")
      List(displayedRows) { row in
        ActionRow(
          model: model, entry: row.entry, depth: row.depth,
          collapsed: collapsed.contains(row.id),
          toggleFolder: {
            if !collapsed.insert(row.id).inserted { collapsed.remove(row.id) }
          },
          edit: { editing = EntryDraft(entry: row.entry, name: model.title(row.entry)) })
      }.listStyle(.plain).accessibilityIdentifier("selectionbar.layout-list")
        .overlay {
          if displayedRows.isEmpty { Text(L10n.text("沒有符合的動作")).foregroundStyle(.secondary) }
        }
      Divider()
      HStack {
        Menu {
          Button(L10n.text("加入內置動作…")) { showBuiltIns = true }
          Button(L10n.text("加入擴充…")) { model.chooseImport() }
          Button(L10n.text("新增資料夾…")) { editing = EntryDraft(entry: nil, name: L10n.text("新資料夾")) }
          Button(L10n.text("新增分隔線")) { model.editLibrary { try $0.createSeparator() } }
        } label: {
          Image(systemName: "plus")
        }.menuStyle(.borderlessButton).frame(width: 25)
          .accessibilityIdentifier("selectionbar.actions.add")
        Button(L10n.text("內置動作")) { showBuiltIns = true }
          .accessibilityIdentifier("selectionbar.actions.library")
        Button(L10n.text("取得擴充功能")) {
          NSWorkspace.shared.open(URL(string: "https://www.popclip.app/extensions/")!)
        }
        Button {
          model.undoLayout()
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }.help(L10n.text("復原排列修改")).disabled(!model.canUndoLayout)
        Spacer()
        Text(
          L10n.text(
            "%1$@ 啟用",
            String(describing: model.library.layout.filter { $0.enabled && $0.kind == 1 }.count))
        )
        .font(.caption).foregroundStyle(.secondary)
      }.padding(10)
    }.sheet(item: $editing) { draft in EntryEditorView(model: model, draft: draft) }
      .sheet(isPresented: $showBuiltIns) { BuiltInLibraryView(model: model) }
  }
}

private struct ActionRow: View {
  @ObservedObject var model: SelectionModel
  let entry: LayoutEntry
  let depth: Int
  let collapsed: Bool
  let toggleFolder: () -> Void
  let edit: () -> Void
  @State private var dropTarget = false
  var body: some View {
    HStack(spacing: 9) {
      if entry.isGroup {
        Button(action: toggleFolder) {
          Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption)
        }
        .buttonStyle(.plain).frame(width: 12).help(
          collapsed ? L10n.text("展開資料夾") : L10n.text("收起資料夾"))
      } else {
        Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary).frame(
          width: 12)
      }
      if entry.isSeparator {
        Image(systemName: "minus").frame(width: 20, height: 20).foregroundStyle(.secondary)
      } else if entry.isGroup {
        if let image = ExtensionIcon.image(
          config: entry.icon ?? .string("symbol:folder"), packageRoot: model.dataRoot, size: 18)
        {
          Image(nsImage: image).resizable().scaledToFit().foregroundStyle(groupColor(entry.color))
            .frame(width: 18, height: 18)
        }
      } else {
        ActionIcon(
          record: model.library.record(for: entry), builtin: BuiltInAction(entry.provider),
          overrideIcon: entry.icon, assetRoot: model.dataRoot
        ).frame(width: 20, height: 20)
      }
      Toggle(
        L10n.text("啟用 ") + model.title(entry),
        isOn: Binding(
          get: { entry.enabled },
          set: { enabled in
            model.editLibrary { library in
              if let index = library.layout.firstIndex(where: { $0.id == entry.id }) {
                library.layout[index].enabled = enabled
              }
            }
          })
      ).labelsHidden().toggleStyle(.checkbox)
        .accessibilityIdentifier("selectionbar.actions.enabled." + entry.id)
      Text(model.title(entry)).foregroundStyle(entry.enabled ? .primary : .secondary).lineLimit(1)
      Spacer()
      if model.library.record(for: entry) != nil || BuiltInAction(entry.provider).id == "spelling" {
        Button {
          model.selectedExtension = entry.id
        } label: {
          Image(systemName: "gearshape")
        }
        .buttonStyle(.borderless).help(model.title(entry) + L10n.text(" 設定"))
      }
      Menu {
        Button(entry.isGroup ? L10n.text("編輯資料夾…") : L10n.text("名稱與外觀…"), action: edit)
        Picker(
          L10n.text("顯示"),
          selection: Binding(
            get: { entry.presentation },
            set: { value in
              model.editLibrary { library in
                if let i = library.layout.firstIndex(where: { $0.id == entry.id }) {
                  library.layout[i].presentation = value
                }
              }
            })
        ) {
          Text(L10n.text("圖示")).tag(0)
          Text(L10n.text("文字")).tag(2)
        }
        Divider()
        Button(L10n.text("上移")) { model.move(entry, delta: -1) }
        Button(L10n.text("下移")) { model.move(entry, delta: 1) }
        Menu(L10n.text("移至")) {
          Button(L10n.text("最外層")) { move(to: nil) }.disabled(entry.parent == nil)
          ForEach(
            model.library.layoutRows.filter {
              $0.entry.isGroup && $0.id != entry.id
                && !model.library.descendants(of: entry.id).contains($0.id)
            }
          ) { row in
            Button(String(repeating: "  ", count: row.depth) + model.title(row.entry)) {
              move(to: row.id)
            }
            .disabled(entry.parent == row.id)
          }
        }
        Button(L10n.text("製作副本")) {
          model.editLibrary {
            _ = try $0.duplicateEntry(entry.id, name: model.title(entry) + L10n.text(" 副本"))
          }
        }
        Divider()
        if entry.isGroup {
          Button(L10n.text("刪除資料夾，保留內容")) { remove(keepChildren: true) }
          Button(L10n.text("刪除資料夾及內容"), role: .destructive) { remove(keepChildren: false) }
        } else {
          Button(L10n.text("移除這個動作"), role: .destructive) { remove(keepChildren: false) }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }.menuStyle(.borderlessButton).frame(width: 26)
    }.padding(.vertical, 1).padding(.leading, CGFloat(min(depth, 12)) * 15)
      .frame(minHeight: 28).contentShape(Rectangle())
      .background(
        dropTarget ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 6)
      )
      .accessibilityIdentifier("selectionbar.layout." + entry.id)
      .onDrag { NSItemProvider(object: entry.id as NSString) }
      .onDrop(
        of: [UTType.plainText],
        delegate: LayoutDrop(model: model, target: entry, highlighted: $dropTarget))
  }
  private func move(to parent: String?) {
    model.editLibrary { try $0.moveEntry(entry.id, toParent: parent) }
  }
  private func remove(keepChildren: Bool) {
    model.editLibrary { try $0.deleteEntry(entry.id, keepChildren: keepChildren) }
  }
}

private struct LayoutDrop: DropDelegate {
  let model: SelectionModel
  let target: LayoutEntry
  @Binding var highlighted: Bool
  func dropEntered(info: DropInfo) { highlighted = true }
  func dropExited(info: DropInfo) { highlighted = false }
  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
  func performDrop(info: DropInfo) -> Bool {
    highlighted = false
    guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
    let into = target.isGroup && (10...30).contains(info.location.y)
    let after = info.location.y > 20
    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
      guard let source = object as? String, source != target.id else { return }
      Task { @MainActor in
        guard model.library.layout.contains(where: { $0.id == source }) else { return }
        model.editLibrary { library in
          if into {
            try library.moveEntry(source, toParent: target.id)
          } else {
            let siblings = library.layout.filter { $0.parent == target.parent }.sorted {
              $0.order < $1.order
            }
            let next = siblings.firstIndex(where: { $0.id == target.id }).flatMap {
              siblings.indices.contains($0 + 1) ? siblings[$0 + 1].id : nil
            }
            let before = after ? next : target.id
            if before != source {
              try library.moveEntry(source, toParent: target.parent, before: before)
            }
          }
        }
      }
    }
    return true
  }
}

private struct EntryDraft: Identifiable {
  let id = UUID()
  var entry: LayoutEntry?
  var name: String
}

private struct EntryEditorView: View {
  @ObservedObject var model: SelectionModel
  let draft: EntryDraft
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var icon = "symbol:folder"
  @State private var color = "blue"
  @State private var parent = ""
  @State private var presentation = 0
  @State private var failure = ""
  private var possibleParents: [LayoutRow] {
    let excluded = draft.entry.map { model.library.descendants(of: $0.id).union([$0.id]) } ?? []
    return model.library.layoutRows.filter { $0.entry.isGroup && !excluded.contains($0.id) }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(draft.entry == nil ? L10n.text("新增資料夾") : L10n.text("編輯項目")).font(.headline)
      TextField(L10n.text("名稱"), text: $name).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("selectionbar.entry.name")
      Picker(L10n.text("圖示"), selection: $icon) {
        if draft.entry?.kind == 1 { Text(L10n.text("跟隨擴充")).tag("") }
        ForEach(
          ["folder", "tray", "star", "bookmark", "book", "briefcase", "terminal", "globe"],
          id: \.self
        ) {
          Label(
            [
              "folder": L10n.text("資料夾"), "tray": L10n.text("收件匣"), "star": L10n.text("星號"),
              "bookmark": L10n.text("書籤"), "book": L10n.text("書籍"),
              "briefcase": L10n.text("工作"), "terminal": L10n.text("終端機"), "globe": L10n.text("網站"),
            ][$0] ?? $0, systemImage: $0
          ).tag("symbol:" + $0)
        }
        if !["folder", "tray", "star", "bookmark", "book", "briefcase", "terminal", "globe"]
          .contains(icon.replacingOccurrences(of: "symbol:", with: ""))
        {
          Text(L10n.text("原有圖示")).tag(icon)
        }
      }
      Picker(L10n.text("顏色"), selection: $color) {
        Text(L10n.text("跟隨外觀")).tag("")
        Text(L10n.text("藍色")).tag("blue")
        Text(L10n.text("橙色")).tag("orange")
        Text(L10n.text("綠色")).tag("green")
        Text(L10n.text("紫色")).tag("purple")
        Text(L10n.text("紅色")).tag("red")
        Text(L10n.text("灰色")).tag("gray")
        if !["blue", "orange", "green", "purple", "red", "gray"].contains(color) {
          Text(L10n.text("原有顏色")).tag(color)
        }
      }
      Picker(L10n.text("放在"), selection: $parent) {
        Text(L10n.text("最外層")).tag("")
        ForEach(possibleParents) { row in
          Text(String(repeating: "  ", count: row.depth) + model.title(row.entry)).tag(row.id)
        }
      }
      Picker(L10n.text("顯示"), selection: $presentation) {
        Text(L10n.text("圖示")).tag(0)
        Text(L10n.text("文字")).tag(2)
      }
      if !failure.isEmpty { Text(failure).font(.caption).foregroundStyle(.red) }
      HStack {
        Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L10n.text("儲存")) {
          do {
            var library = model.library
            if let entry = draft.entry {
              let chosenIcon: Value? =
                icon == "__original__" ? entry.icon : icon.isEmpty ? nil : .string(icon)
              try library.editEntry(
                entry.id, name: name, icon: chosenIcon, color: color.isEmpty ? nil : color,
                presentation: presentation)
              if entry.parent != (parent.isEmpty ? nil : parent) {
                try library.moveEntry(entry.id, toParent: parent.isEmpty ? nil : parent)
              }
            } else {
              _ = try library.createGroup(
                name: name, parent: parent.isEmpty ? nil : parent, icon: .string(icon), color: color
              )
            }
            model.editLibrary { $0 = library }
            dismiss()
          } catch { failure = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).accessibilityIdentifier("selectionbar.entry.save")
      }
    }.padding(22).frame(width: 390).onAppear {
      name = draft.name
      if let stored = draft.entry?.icon {
        if case .string(let raw) = stored { icon = raw } else { icon = "__original__" }
      } else {
        icon = draft.entry?.kind == 1 ? "" : "symbol:folder"
      }
      color = draft.entry == nil ? "blue" : draft.entry?.color ?? ""
      parent = draft.entry?.parent ?? ""
      presentation = draft.entry?.presentation ?? 0
    }
  }
}

func groupColor(_ name: String?) -> Color {
  Color(nsColor: nativeGroupColor(name))
}
func nativeGroupColor(_ name: String?) -> NSColor {
  if let name, name.hasPrefix("#"), name.count == 7, let value = UInt32(name.dropFirst(), radix: 16)
  {
    return NSColor(
      srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255, alpha: 1)
  }
  switch name {
  case "orange": return .systemOrange
  case "green": return .systemGreen
  case "purple": return .systemPurple
  case "red": return .systemRed
  case "gray": return .systemGray
  case "yellow": return .systemYellow
  case "pink": return .systemPink
  case "teal": return .systemTeal
  default: return .systemBlue
  }
}
