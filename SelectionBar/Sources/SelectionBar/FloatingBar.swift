import AppKit
import LocalWorkflowKit
import SelectionBarCore

@MainActor
final class FloatingBar: NSObject {
  private let model: SelectionModel
  private var panel: NSPanel?
  private var outside: Any?
  private var localOutside: Any?
  private var snapshot: SelectionSnapshot?
  private var isBusy = false
  private var population = PopulationState()
  private var populationSelection: Date?
  private var groupID: String?
  private var initialHandled = false
  private var activeSubmenu: ([[String: Value]], ExtensionRecord, SelectionSnapshot)?
  private var submenuHistory: [([[String: Value]], ExtensionRecord, SelectionSnapshot)] = []
  private var redrawIcons: (() -> Void)?
  private var actions: [String: () -> Void] = [:]
  private var primaryScreenX: CGFloat?
  private let spelling: SpellingSuggestions
  private var builtinVisibility: [String: Bool] = [:]
  private var pasteboardGeneration = -1
  init(model: SelectionModel, spelling: SpellingSuggestions? = nil) {
    self.model = model
    self.spelling = spelling ?? SpellingSuggestions()
  }
  func present(_ snapshot: SelectionSnapshot, population state: PopulationState? = nil) {
    self.snapshot = snapshot
    if populationSelection != snapshot.capturedAt {
      builtinVisibility.removeAll(keepingCapacity: true)
      groupID = nil
      initialHandled = false
      activeSubmenu = nil
      submenuHistory.removeAll()
    }
    if let state {
      population = state
      populationSelection = snapshot.capturedAt
    } else if populationSelection != snapshot.capturedAt {
      population = PopulationState()
      populationSelection = snapshot.capturedAt
    }
    let visibleEntries = LayoutTree.enabledEntries(model.library.layout)
    if snapshot.context.editable,
      visibleEntries.contains(where: { BuiltInAction($0.provider).id == "spelling" })
    {
      spelling.onUpdate = { [weak self] in
        guard let self, let current = self.snapshot, !self.isBusy else { return }
        self.present(current)
      }
      spelling.prepare(
        word: snapshot.context.text, selection: snapshot.capturedAt,
        configured: model.library.settings.spellingLanguages)
    } else {
      spelling.cancel()
    }
    if let submenu = activeSubmenu {
      presentModuleActions(submenu.0, record: submenu.1, snapshot: submenu.2)
      return
    }
    if !initialHandled {
      let enabled = Set(visibleEntries.map(\.id))
      for row in model.library.layoutRows where enabled.contains(row.id) {
        let entry = row.entry
        if BuiltInAction(entry.provider).id == "spelling", model.library.settings.spellingShowFirst
        {
          if spelling.isPending { break }
          if spelling.result.shouldShowFirst {
            initialHandled = true
            groupID = entry.parent
            presentSpelling(snapshot)
            return
          }
        }
        guard let record = model.library.record(for: entry) else { continue }
        if population.pending.contains(entry.id) { break }
        if let initial = population.initial[entry.id] {
          initialHandled = true
          groupID = entry.parent
          presentModuleActions(initial.actions, record: record, snapshot: snapshot)
          return
        }
        if let initial = record.actions.first(where: {
          $0.kind == "submenu" && $0.config["wantsinitialdisplay"]?.bool == true
            && ActionMatcher.match($0, context: snapshot.context, options: record.effectiveOptions)
              != nil
        }) {
          initialHandled = true
          groupID = entry.parent
          model.execute(initial, record: record, snapshot: snapshot)
          return
        }
      }
      if population.pending.isEmpty && !spelling.isPending { initialHandled = true }
    }
    redrawIcons = { [weak self] in self?.present(snapshot) }
    actions = [:]
    let entries = visibleEntries.filter { $0.parent == groupID }.sorted {
      $0.order < $1.order
    }
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 1
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
    var primary: NSView?
    if let currentGroup = groupID {
      let back = NSButton(
        image: NSImage(
          systemSymbolName: "chevron.left", accessibilityDescription: L10n.text("返回"))!,
        target: self, action: #selector(clicked(_:)))
      let key = UUID().uuidString
      back.identifier = NSUserInterfaceItemIdentifier(key)
      back.isBordered = false
      back.toolTip = L10n.text("返回")
      back.setAccessibilityIdentifier("selectionbar.group.back")
      back.widthAnchor.constraint(equalToConstant: 34).isActive = true
      back.heightAnchor.constraint(equalToConstant: 34).isActive = true
      actions[key] = { [weak self] in
        guard let self else { return }
        self.groupID = self.model.library.layout.first { $0.id == currentGroup }?.parent
        self.present(snapshot)
      }
      stack.addArrangedSubview(back)
    }
    for entry in entries {
      if entry.isSeparator {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(divider)
      } else if entry.isGroup {
        let children = visibleEntries.filter { $0.parent == entry.id }.sorted {
          $0.order < $1.order
        }
        if !children.isEmpty {
          stack.addArrangedSubview(button(entry: entry, snapshot: snapshot, group: children))
        }
      } else if let record = model.library.record(for: entry) {
        if record.actions.contains(where: { $0.kind == "module" }) {
          if let list = population.actions[entry.id] {
            for raw in list where raw["separator"]?.bool != true {
              let item = moduleButton(
                raw, record: record, snapshot: snapshot, presentation: entry.presentation,
                overrideIcon: entry.icon, tint: entry.color)
              stack.addArrangedSubview(item)
              if primary == nil && raw["wantsPrimaryDisplay"]?.bool == true { primary = item }
            }
          } else if let error = population.errors[entry.id] {
            let raw: [String: Value] = [
              "title": .string(record.name), "icon": .string("symbol:exclamationmark.triangle"),
            ]
            let failed = moduleButton(
              raw, record: record, snapshot: snapshot, presentation: entry.presentation)
            if let id = failed.identifier?.rawValue {
              actions[id] = { [weak self] in
                self?.showFailure(
                  ActionFailure(title: record.name, message: error, instanceID: record.instanceID),
                  snapshot: snapshot)
              }
            }
            failed.toolTip = record.name + "：" + error
            stack.addArrangedSubview(failed)
          }
        } else {
          for action in record.actions
          where ActionMatcher.match(
            action, context: snapshot.context, options: record.effectiveOptions)
            != nil
          {
            let item = staticButton(action, record: record, entry: entry, snapshot: snapshot)
            stack.addArrangedSubview(item)
            if primary == nil && action.config["wantsprimarydisplay"]?.bool == true {
              primary = item
            }
          }
        }
      } else if visibleBuiltin(entry, snapshot: snapshot) {
        let item = button(entry: entry, snapshot: snapshot)
        stack.addArrangedSubview(item)
        if primary == nil && ["copy", "paste"].contains(BuiltInAction(entry.provider).id) {
          primary = item
        }
      }
    }
    if !population.pending.isEmpty || spelling.isPending {
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.widthAnchor.constraint(equalToConstant: 20).isActive = true
      spinner.startAnimation(nil)
      spinner.toolTip = L10n.text("載入動作")
      spinner.setAccessibilityIdentifier("selectionbar.population")
      stack.addArrangedSubview(spinner)
    }
    let settings = NSButton(
      image: NSImage(systemSymbolName: "ellipsis", accessibilityDescription: L10n.text("設定"))!,
      target: self,
      action: #selector(openSettings))
    settings.isBordered = false
    settings.toolTip = L10n.text("SelectionBar 設定")
    settings.setAccessibilityIdentifier("selectionbar.popup.settings")
    settings.widthAnchor.constraint(equalToConstant: 30).isActive = true
    settings.heightAnchor.constraint(equalToConstant: 34).isActive = true
    stack.addArrangedSubview(settings)
    guard stack.arrangedSubviews.count > 1 else {
      SelectionDiagnostics.record("bar empty")
      dismiss()
      return
    }
    show(stack, anchor: snapshot.anchor, primary: primary)
  }
  private func visibleBuiltin(_ entry: LayoutEntry, snapshot: SelectionSnapshot) -> Bool {
    let action = BuiltInAction(entry.provider)
    if action.id == "spelling" { return !spelling.result.words.isEmpty }
    if action.id == "paste" || action.id == "plainpaste" {
      let current = NSPasteboard.general.changeCount
      if current != pasteboardGeneration {
        builtinVisibility.removeValue(forKey: "paste")
        builtinVisibility.removeValue(forKey: "plainpaste")
        pasteboardGeneration = current
      }
    }
    if let cached = builtinVisibility[action.id] { return cached }
    let visible = action.visible(snapshot.context)
    builtinVisibility[action.id] = visible
    return visible
  }
  private func staticButton(
    _ action: ExtensionAction, record: ExtensionRecord, entry: LayoutEntry,
    snapshot: SelectionSnapshot
  ) -> NSButton {
    let button = moduleButton(
      [
        "title": .string(record.actions.count == 1 ? model.title(entry) : action.title),
        "icon": action.config["icon"] ?? record.config["icon"] ?? .null,
        "iconProperties": .object(record.config.merging(action.config) { _, action in action }),
      ],
      record: record, snapshot: snapshot, presentation: entry.presentation,
      overrideIcon: entry.icon, tint: entry.color)
    button.setAccessibilityIdentifier("selectionbar.static." + record.id + "." + action.id)
    if let key = button.identifier?.rawValue {
      actions[key] = { [weak self] in
        self?.model.execute(action, record: record, snapshot: snapshot)
      }
    }
    configureStaticSubmenu(button, action: action, record: record, snapshot: snapshot)
    return button
  }
  private func button(entry: LayoutEntry, snapshot: SelectionSnapshot, group: [LayoutEntry] = [])
    -> NSButton
  {
    let title = model.title(entry)
    let key = UUID().uuidString
    let button = HoverActionButton(
      title: entry.presentation == 2 ? title : "", target: self, action: #selector(clicked(_:)))
    button.identifier = NSUserInterfaceItemIdentifier(key)
    button.isBordered = false
    button.toolTip = title
    button.setAccessibilityLabel(title)
    button.setAccessibilityIdentifier("selectionbar.action." + entry.provider)
    if entry.presentation != 2 {
      if let custom = entry.icon,
        let image = ExtensionIcon.image(config: custom, packageRoot: model.dataRoot, size: 18)
      {
        button.image = image
      } else if let record = model.library.record(for: entry) {
        button.image =
          icon(record)
          ?? NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: title)
      } else {
        button.image = NSImage(
          systemSymbolName: group.isEmpty ? BuiltInAction(entry.provider).symbol : "folder",
          accessibilityDescription: title)
      }
      button.imageScaling = .scaleProportionallyDown
      button.image?.size = NSSize(width: 18, height: 18)
    }
    if let color = entry.color { button.contentTintColor = nativeGroupColor(color) }
    button.heightAnchor.constraint(equalToConstant: model.library.settings.size).isActive = true
    button.widthAnchor.constraint(greaterThanOrEqualToConstant: model.library.settings.size)
      .isActive = true
    actions[key] = { [weak self] in
      guard let self else { return }
      if !group.isEmpty {
        self.activeSubmenu = nil
        self.initialHandled = true
        self.groupID = entry.id
        self.present(snapshot)
      } else {
        if BuiltInAction(entry.provider).id == "spelling" {
          self.presentSpelling(snapshot)
        } else if BuiltInAction(entry.provider).id == "favorites" {
          self.presentFavorites(snapshot)
        } else if BuiltInAction(entry.provider).id == "vocabulary" {
          self.model.collectVocabulary(snapshot)
        } else if BuiltInAction(entry.provider).id == "recipes" {
          self.presentRecipes(snapshot)
        } else {
          self.model.execute(entry, snapshot: snapshot)
        }
      }
    }
    if !group.isEmpty { button.opensOnHover = true }
    return button
  }
  private func icon(_ record: ExtensionRecord) -> NSImage? {
    ExtensionIcon.image(
      config: record.config["icon"], packageRoot: URL(fileURLWithPath: record.packagePath),
      size: 18, properties: record.config
    )
  }
  func presentModuleActions(
    _ list: [[String: Value]], record: ExtensionRecord, snapshot: SelectionSnapshot,
    rememberCurrent: Bool = false
  ) {
    if rememberCurrent, let activeSubmenu, activeSubmenu.2.capturedAt == snapshot.capturedAt,
      activeSubmenu.0 != list || activeSubmenu.1 != record
    {
      submenuHistory.append(activeSubmenu)
    }
    self.snapshot = snapshot
    activeSubmenu = (list, record, snapshot)
    redrawIcons = { [weak self] in
      self?.presentModuleActions(list, record: record, snapshot: snapshot)
    }
    actions = [:]
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
    var primary: NSView?
    let isSpelling = record.id == "selectionbar.builtin.spelling"
    for raw in list {
      if raw["separator"]?.bool == true {
        let divider = NSBox()
        divider.boxType = .separator
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(divider)
      } else {
        let item = moduleButton(raw, record: record, snapshot: snapshot)
        stack.addArrangedSubview(item)
        if primary == nil && raw["wantsPrimaryDisplay"]?.bool == true { primary = item }
      }
    }
    let back = NSButton(
      image: NSImage(
        systemSymbolName: isSpelling ? "chevron.up" : "chevron.left",
        accessibilityDescription: L10n.text("返回")
      )!,
      target: self, action: #selector(clicked(_:)))
    back.isBordered = false
    back.toolTip = L10n.text("返回")
    back.setAccessibilityIdentifier(
      isSpelling ? "selectionbar.spelling.back" : "selectionbar.submenu.back")
    let key = UUID().uuidString
    back.identifier = NSUserInterfaceItemIdentifier(key)
    back.widthAnchor.constraint(equalToConstant: 34).isActive = true
    actions[key] = { [weak self] in
      guard let self else { return }
      self.activeSubmenu = nil
      self.initialHandled = true
      if list.first?["static"]?.bool == true {
        if let previous = self.submenuHistory.popLast() {
          self.presentModuleActions(previous.0, record: previous.1, snapshot: previous.2)
        } else {
          self.present(snapshot)
        }
        return
      }
      let path = list.first?["path"]?.array.compactMap { Int($0.string) } ?? []
      if path.count > 1, let action = record.actions.first {
        let parent = Array(path.dropLast(2))
        if parent.isEmpty {
          self.present(snapshot)
        } else {
          self.model.execute(
            action, record: record, snapshot: snapshot, modulePath: parent, openSubmenu: true)
        }
      } else {
        self.present(snapshot)
      }
    }
    stack.insertArrangedSubview(back, at: 0)
    show(stack, anchor: snapshot.anchor, primary: primary)
  }
  private func moduleButton(
    _ raw: [String: Value], record: ExtensionRecord, snapshot: SelectionSnapshot,
    presentation: Int = 0, overrideIcon: Value? = nil, tint: String? = nil
  ) -> NSButton {
    let index = Int(raw["index"]?.string ?? "0") ?? 0
    let title = raw["title"]?.string ?? record.name
    let button = HoverActionButton(title: title, target: self, action: #selector(clicked(_:)))
    button.isBordered = false
    button.toolTip = title
    button.setAccessibilityLabel(title)
    if raw["replacement"] != nil {
      button.font = .systemFont(ofSize: 15, weight: .medium)
      button.bezelStyle = .roundRect
      button.isBordered = true
      button.toolTip = title + L10n.text(" · 按一下替換；Shift 按一下複製")
      if raw["wantsPrimaryDisplay"]?.bool == true {
        button.bezelColor = .controlAccentColor
        button.contentTintColor = .white
      }
    }
    if presentation != 2,
      let image = ExtensionIcon.image(
        config: overrideIcon ?? raw["icon"],
        packageRoot: overrideIcon == nil
          ? URL(fileURLWithPath: record.packagePath) : model.dataRoot,
        size: 18, properties: raw["iconProperties"]?.object ?? record.config)
    {
      button.image = image
      button.title = ""
      button.imageScaling = .scaleProportionallyDown
    }
    button.isEnabled = raw["disabled"]?.bool != true
    if let tint { button.contentTintColor = nativeGroupColor(tint) }
    button.heightAnchor.constraint(equalToConstant: max(32, model.library.settings.size)).isActive =
      true
    button.widthAnchor.constraint(
      greaterThanOrEqualToConstant: max(32, model.library.settings.size)
    ).isActive = true
    let path = raw["path"]?.array.compactMap { Int($0.string) } ?? [index]
    button.setAccessibilityIdentifier(
      "selectionbar.module." + record.id + "." + path.map(String.init).joined(separator: "."))
    let key = UUID().uuidString
    button.identifier = NSUserInterfaceItemIdentifier(key)
    actions[key] = { [weak self] in
      guard let self else { return }
      if let replacement = raw["replacement"]?.string {
        self.model.replaceSpelling(
          replacement, snapshot: snapshot,
          copyOnly: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift))
        return
      }
      if raw["workflowCollect"]?.bool == true {
        self.model.collect(snapshot, note: raw["noteID"].flatMap { UUID(uuidString: $0.string) })
        return
      }
      if let id = raw["workflowRecipe"].flatMap({ UUID(uuidString: $0.string) }) {
        self.model.runRecipe(id, snapshot: snapshot)
        return
      }
      if raw["workflowSettings"]?.bool == true {
        self.dismiss()
        self.model.settingsTab = "workflows"
        self.model.showSettings?()
        return
      }
      if raw["static"]?.bool == true, record.actions.indices.contains(index) {
        self.model.execute(record.actions[index], record: record, snapshot: snapshot)
      } else if var action = record.actions.first(where: { $0.kind == "module" }) {
        action.title = title
        action.config["capturehtml"] = raw["captureHtml"] ?? .bool(false)
        action.config["capturertf"] = raw["captureRtf"] ?? .bool(false)
        self.model.execute(
          action, record: record, snapshot: snapshot, modulePath: path,
          openSubmenu: raw["submenu"]?.bool == true && raw["hasCode"]?.bool != true)
      }
    }
    button.opensOnHover = raw["submenu"]?.bool == true && raw["hasCode"]?.bool != true
    if raw["static"]?.bool == true, record.actions.indices.contains(index) {
      configureStaticSubmenu(
        button, action: record.actions[index], record: record, snapshot: snapshot)
    }
    if raw["submenu"]?.bool == true && raw["hasCode"]?.bool == true {
      let menu = NSMenu()
      let item = NSMenuItem(
        title: L10n.text("開啟子選單"), action: #selector(menuSelected(_:)), keyEquivalent: "")
      let menuKey = UUID().uuidString
      item.target = self
      item.representedObject = menuKey
      actions[menuKey] = { [weak self] in
        guard let self, let action = record.actions.first(where: { $0.kind == "module" }) else {
          return
        }
        self.model.execute(
          action, record: record, snapshot: snapshot, modulePath: path, openSubmenu: true)
      }
      menu.addItem(item)
      button.menu = menu
      button.toolTip = title + L10n.text(" · 右鍵開啟子選單")
    }
    return button
  }
  private func configureStaticSubmenu(
    _ button: NSButton, action: ExtensionAction, record: ExtensionRecord,
    snapshot: SelectionSnapshot
  ) {
    guard action.hasSubmenu else { return }
    if action.kind == "submenu" {
      (button as? HoverActionButton)?.opensOnHover = true
    } else {
      let menu = NSMenu()
      let item = NSMenuItem(
        title: L10n.text("開啟子選單"), action: #selector(menuSelected(_:)), keyEquivalent: "")
      let key = UUID().uuidString
      item.target = self
      item.representedObject = key
      actions[key] = { [weak self] in
        self?.model.openStaticSubmenu(action, record: record, snapshot: snapshot)
      }
      menu.addItem(item)
      button.menu = menu
      button.toolTip = action.title + L10n.text(" · 右鍵開啟子選單")
    }
  }
  private func presentSpelling(_ snapshot: SelectionSnapshot) {
    let record = ExtensionRecord(
      id: "selectionbar.builtin.spelling", name: L10n.text("拼字"),
      packagePath: model.dataRoot.path, digest: "builtin", config: [:], actions: [])
    let actions = spelling.result.words.enumerated().map { index, word in
      [
        "title": Value.string(word), "replacement": .string(word), "index": .number(Double(index)),
        "wantsPrimaryDisplay": .bool(index == 0),
      ]
    }
    presentModuleActions(actions, record: record, snapshot: snapshot)
  }
  private func presentFavorites(_ snapshot: SelectionSnapshot) {
    let notes = (try? WorkflowFiles.destinations(in: model.workflowDirectory).notes) ?? []
    var entries: [(String, String, () -> Void)] = notes.map { note in
      (
        note.folderName + " › " + note.title, note.id.uuidString,
        { [weak self] in self?.model.collect(snapshot, note: note.id) }
      )
    }
    entries.append(
      (
        L10n.text("選擇其他資料夾／筆記…"), "picker",
        { [weak self] in self?.model.collect(snapshot, note: nil) }
      ))
    presentWorkflowMenu(
      entries, snapshot: snapshot,
      emptyHint: notes.isEmpty ? L10n.text("先在 EdgeNotes 將常用目的筆記加上星號") : nil)
  }
  private func presentRecipes(_ snapshot: SelectionSnapshot) {
    var entries: [(String, String, () -> Void)] = model.workflows.recipes.map { recipe in
      (
        recipe.name, recipe.id.uuidString,
        { [weak self] in self?.model.runRecipe(recipe.id, snapshot: snapshot) }
      )
    }
    entries.append(
      (
        L10n.text("管理配方…"), "settings",
        { [weak self] in
          self?.model.settingsTab = "workflows"
          self?.model.showSettings?()
        }
      ))
    presentWorkflowMenu(entries, snapshot: snapshot)
  }
  private func presentWorkflowMenu(
    _ entries: [(String, String, () -> Void)], snapshot: SelectionSnapshot, emptyHint: String? = nil
  ) {
    // Native menus support keyboard navigation and vertical scrolling even with many favourites.
    dismiss()
    let menu = NSMenu()
    menu.autoenablesItems = false
    var menuKeys: [String] = []
    if let emptyHint {
      let hint = NSMenuItem(title: emptyHint, action: nil, keyEquivalent: "")
      hint.isEnabled = false
      menu.addItem(hint)
      menu.addItem(.separator())
    }
    for (index, entry) in entries.enumerated() {
      if index == entries.count - 1 && index > 0 { menu.addItem(.separator()) }
      let title = entry.0.count > 100 ? String(entry.0.prefix(100)) + "…" : entry.0
      let item = NSMenuItem(title: title, action: #selector(menuSelected(_:)), keyEquivalent: "")
      let key = UUID().uuidString
      item.target = self
      item.representedObject = key
      item.identifier = NSUserInterfaceItemIdentifier("selectionbar.workflow." + entry.1)
      item.toolTip = entry.0
      actions[key] = entry.2
      menuKeys.append(key)
      menu.addItem(item)
    }
    menu.popUp(
      positioning: nil, at: NSPoint(x: snapshot.anchor.midX, y: snapshot.anchor.maxY), in: nil)
    for key in menuKeys { actions.removeValue(forKey: key) }
  }
  func showResult(_ text: String, preview: Bool) {
    redrawIcons = nil
    activeSubmenu = nil
    submenuHistory.removeAll()
    guard let snapshot else {
      model.notice = text
      return
    }
    actions = [:]
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    let label = NSTextField(wrappingLabelWithString: String(text.prefix(160)))
    label.font = .systemFont(ofSize: 13)
    label.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    label.setAccessibilityIdentifier("selectionbar.result")
    stack.addArrangedSubview(label)
    if preview && snapshot.context.editable {
      let button = NSButton(title: L10n.text("貼上"), target: self, action: #selector(clicked(_:)))
      let key = UUID().uuidString
      button.identifier = NSUserInterfaceItemIdentifier(key)
      actions[key] = { [weak self] in
        guard let self else { return }
        self.dismiss()
        Task {
          do { try await self.model.executor.paste(text, snapshot: snapshot, restore: false) } catch
          {
            self.showFailure(
              ActionFailure(title: L10n.text("貼上"), message: error.localizedDescription),
              snapshot: snapshot)
          }
        }
      }
      stack.addArrangedSubview(button)
    }
    let close = NSButton(
      image: NSImage(systemSymbolName: "xmark", accessibilityDescription: L10n.text("關閉"))!,
      target: self,
      action: #selector(close))
    close.isBordered = false
    stack.addArrangedSubview(close)
    show(stack, anchor: snapshot.anchor)
  }
  func showFailure(_ failure: ActionFailure, snapshot: SelectionSnapshot) {
    dismiss()
    self.snapshot = snapshot
    show(failureContent(failure, snapshot: snapshot), anchor: snapshot.anchor)
  }
  func failureContent(_ failure: ActionFailure, snapshot: SelectionSnapshot) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    let title = NSTextField(labelWithString: L10n.text("未能完成「") + failure.title + "」")
    title.font = .systemFont(ofSize: 13, weight: .semibold)
    title.lineBreakMode = .byTruncatingTail
    title.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
    title.setAccessibilityIdentifier("selectionbar.failure.title")
    stack.addArrangedSubview(title)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
    details.string = failure.message
    details.font = .systemFont(ofSize: 12)
    details.textColor = .labelColor
    details.drawsBackground = false
    details.isEditable = false
    details.isSelectable = true
    details.isVerticallyResizable = true
    details.isHorizontallyResizable = false
    details.textContainer?.widthTracksTextView = true
    details.textContainer?.containerSize = NSSize(
      width: 400, height: CGFloat.greatestFiniteMagnitude)
    details.setAccessibilityIdentifier("selectionbar.failure.details")
    scroll.documentView = details
    if let container = details.textContainer, let layout = details.layoutManager {
      layout.ensureLayout(for: container)
      details.setFrameSize(
        NSSize(width: 400, height: max(44, layout.usedRect(for: container).height + 16)))
    }
    scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
    scroll.heightAnchor.constraint(
      equalToConstant: min(140, max(44, CGFloat(failure.message.count / 50 + 1) * 17))
    ).isActive = true
    stack.addArrangedSubview(scroll)
    let controls = NSStackView()
    controls.spacing = 8
    func add(_ title: String, id: String, action: @escaping () -> Void) {
      let button = NSButton(title: title, target: self, action: #selector(clicked(_:)))
      let key = UUID().uuidString
      button.identifier = NSUserInterfaceItemIdentifier(key)
      button.setAccessibilityIdentifier(id)
      actions[key] = action
      controls.addArrangedSubview(button)
    }
    if let id = failure.instanceID {
      add(L10n.text("擴充設定"), id: "selectionbar.failure.settings") { [weak self] in
        self?.dismiss()
        self?.model.selectedExtension = id
        self?.model.showSettings?()
      }
    }
    add(L10n.text("複製詳情"), id: "selectionbar.failure.copy") { [weak self] in
      try? self?.model.executor.copy(failure.title + "\n" + failure.message)
    }
    add(L10n.text("重新選取"), id: "selectionbar.failure.recapture") { [weak self] in
      self?.dismiss()
      self?.model.reappear?()
    }
    add(L10n.text("關閉"), id: "selectionbar.failure.close") { [weak self] in self?.dismiss() }
    stack.addArrangedSubview(controls)
    for app in failure.missingApplications.prefix(4) {
      guard let link = app.link else { continue }
      let button = NSButton(
        title: L10n.text("取得 ") + app.name + "…", target: self, action: #selector(clicked(_:)))
      let key = UUID().uuidString
      button.identifier = NSUserInterfaceItemIdentifier(key)
      actions[key] = { NSWorkspace.shared.open(link) }
      stack.addArrangedSubview(button)
    }
    return stack
  }
  func showLargeText(_ text: String) {
    let anchor = snapshot?.anchor ?? .zero
    redrawIcons = nil
    activeSubmenu = nil
    dismiss()
    let screen =
      NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
      ?? NSScreen.screens[0]
    let panel = NSPanel(
      contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
      defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
    panel.title = L10n.text("SelectionBar · 大字顯示")
    let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
    visual.material = .hudWindow
    visual.blendingMode = .behindWindow
    visual.state = .active
    let scroll = NSScrollView(frame: visual.bounds.insetBy(dx: 60, dy: 100))
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autoresizingMask = [.width, .height]
    let content = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
    content.string = text
    content.isEditable = false
    content.isSelectable = true
    content.drawsBackground = false
    content.font = .systemFont(ofSize: min(96, max(26, CGFloat(6500 / max(60, text.count)))))
    content.textColor = .labelColor
    content.alignment = .center
    content.isVerticallyResizable = true
    content.isHorizontallyResizable = false
    content.textContainer?.widthTracksTextView = true
    content.textContainer?.containerSize = NSSize(
      width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    content.textContainerInset = NSSize(width: 18, height: 18)
    if let container = content.textContainer, let manager = content.layoutManager {
      manager.ensureLayout(for: container)
      content.setFrameSize(
        NSSize(
          width: scroll.contentSize.width,
          height: max(scroll.contentSize.height, manager.usedRect(for: container).height + 36)))
    }
    scroll.documentView = content
    visual.addSubview(scroll)
    let close = NSButton(title: L10n.text("關閉  Esc"), target: self, action: #selector(close))
    close.frame = NSRect(x: visual.bounds.midX + 10, y: 32, width: 100, height: 34)
    close.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
    visual.addSubview(close)
    let copy = NSButton(title: L10n.text("複製"), target: self, action: #selector(clicked(_:)))
    let key = UUID().uuidString
    copy.identifier = NSUserInterfaceItemIdentifier(key)
    copy.frame = NSRect(x: visual.bounds.midX - 110, y: 32, width: 100, height: 34)
    copy.autoresizingMask = close.autoresizingMask
    actions[key] = { [weak self] in
      do { try self?.model.executor.copy(text) } catch {
        self?.model.notice = error.localizedDescription
      }
    }
    visual.addSubview(copy)
    panel.contentView = visual
    panel.setFrame(screen.frame, display: true)
    revealOverlay(panel)
    SelectionDiagnostics.record(
      "bar visible=\(panel.isVisible) frame=\(panel.frame) anchor=\(anchor) screen=\(screen.frame)")
    self.panel = panel
    installOutsideMonitors()
  }
  func presentBusy(_ snapshot: SelectionSnapshot) {
    redrawIcons = nil
    self.snapshot = snapshot
    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 8)
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.controlSize = .small
    spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
    spinner.startAnimation(nil)
    stack.addArrangedSubview(spinner)
    let cancel = NSButton(
      title: L10n.text("取消"), target: self, action: #selector(cancelCurrentAction))
    cancel.isBordered = false
    cancel.heightAnchor.constraint(equalToConstant: 34).isActive = true
    cancel.setAccessibilityIdentifier("selectionbar.cancel-action")
    stack.addArrangedSubview(cancel)
    show(stack, anchor: snapshot.anchor)
    isBusy = true
  }
  func dismissBusy() { if isBusy { dismiss() } }
  @objc private func cancelCurrentAction() {
    model.cancelAction()
    dismiss()
  }
  private func show(_ view: NSView, anchor: CGRect, primary: NSView? = nil) {
    // Population updates and spelling completion rebuild the controls, not the
    // native window or event monitors. Reuse lasts only until dismissal.
    let reusable = panel?.title == L10n.text("SelectionBar 操作列") ? panel : nil
    if reusable == nil { dismissPanel() }
    isBusy = false
    let panel =
      reusable
      ?? NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
        defer: false)
    panel.level = .popUpMenu
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    // Spaces and Stage Manager have separate grouping policies. A toolbar must
    // join the source application's stage, not SelectionBar's preferences stage.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
    panel.isMovable = false
    panel.title = L10n.text("SelectionBar 操作列")
    let visual = NSVisualEffectView()
    visual.material = .popover
    visual.blendingMode = .behindWindow
    visual.state = .active
    visual.wantsLayer = true
    visual.layer?.cornerRadius = 10
    visual.layer?.masksToBounds = true
    let screen =
      NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
    let fitting = view.fittingSize
    view.frame = NSRect(origin: .zero, size: fitting)
    view.layoutSubtreeIfNeeded()
    let maximum = max(80, screen.visibleFrame.width - 24)
    let content: NSView
    var scrollOffset: CGFloat = 0
    if fitting.width > maximum {
      let scroll = NSScrollView()
      scroll.drawsBackground = false
      scroll.borderType = .noBorder
      scroll.hasHorizontalScroller = true
      scroll.autohidesScrollers = true
      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = NSRect(origin: .zero, size: fitting)
      scroll.documentView = view
      if let primary {
        let center = view.convert(primary.bounds, from: primary).midX
        scrollOffset = min(max(0, center - maximum / 2), fitting.width - maximum)
        scroll.contentView.scroll(to: NSPoint(x: scrollOffset, y: 0))
      }
      content = scroll
    } else {
      content = view
    }
    visual.addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
      content.topAnchor.constraint(equalTo: visual.topAnchor),
      content.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
    ])
    panel.contentView = visual
    visual.setAccessibilityIdentifier("selectionbar.popup")
    let size = CGSize(width: min(maximum, max(80, fitting.width)), height: max(44, fitting.height))
    visual.setFrameSize(size)
    visual.layoutSubtreeIfNeeded()
    if let scroll = content as? NSScrollView, let primary {
      let center = view.convert(primary.bounds, from: primary).midX
      scrollOffset = min(
        max(0, center - scroll.contentSize.width / 2),
        max(0, fitting.width - scroll.contentSize.width))
      scroll.contentView.scroll(to: NSPoint(x: scrollOffset, y: 0))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    let frame = Placement.frame(
      anchor: anchor, size: size, visible: screen.visibleFrame,
      below: model.library.settings.placement == "below",
      primaryOffset: primary.map { view.convert($0.bounds, from: $0).midX - scrollOffset },
      pointerX: primary == nil ? nil : snapshot?.pointer?.x)
    panel.setFrame(frame, display: true)
    primaryScreenX = primary.map { panel.convertToScreen($0.convert($0.bounds, to: nil)).midX }
    panel.appearance =
      model.library.settings.appearance == "auto"
      ? nil
      : NSAppearance(
        named: model.library.settings.appearance == "dark" ? .darkAqua : .aqua)
    revealOverlay(panel)
    SelectionDiagnostics.record(
      "toolbar visible=\(panel.isVisible) hiddenApp=\(NSApp.isHidden) activeSpace=\(panel.isOnActiveSpace) window=\(panel.windowNumber) frame=\(panel.frame) anchor=\(anchor) screen=\(screen.frame) pointer=\(String(describing: snapshot?.pointer))"
    )
    self.panel = panel
    installOutsideMonitors()
  }
  private func revealOverlay(_ panel: NSPanel) {
    // Login items and `open -j` can hide the entire accessory application.
    // orderFrontRegardless alone does not unhide it, even on the active Space.
    // Keep its settings/other document windows closed while revealing only the
    // overlay, and preserve the source application's keyboard focus.
    if NSApp.isHidden {
      for window in NSApp.windows
      where window !== panel && window.styleMask.contains(.titled) && !window.isMiniaturized {
        window.orderOut(nil)
      }
      NSApp.unhideWithoutActivation()
    }
    panel.orderFrontRegardless()
  }
  private func installOutsideMonitors() {
    guard outside == nil, localOutside == nil else { return }
    outside = NSEvent.addGlobalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown,
    ]) { [weak self] event in
      Task { @MainActor in
        guard let self else { return }
        if event.type == .keyDown {
          if event.keyCode == 53 { self.dismiss() }
        } else if self.panel?.frame.contains(NSEvent.mouseLocation) != true {
          self.dismiss()
        }
      }
    }
    localOutside = NSEvent.addLocalMonitorForEvents(matching: [
      .leftMouseDown, .rightMouseDown, .keyDown,
    ]) { [weak self] event in
      guard let self else { return event }
      if event.type == .keyDown, event.keyCode == 53 {
        self.dismiss()
        return nil
      }
      if event.type != .keyDown, self.panel?.frame.contains(NSEvent.mouseLocation) != true {
        self.dismiss()
      }
      return event
    }
  }
  private func dismissPanel() {
    isBusy = false
    primaryScreenX = nil
    if let localOutside {
      NSEvent.removeMonitor(localOutside)
      self.localOutside = nil
    }
    if let outside {
      NSEvent.removeMonitor(outside)
      self.outside = nil
    }
    panel?.orderOut(nil)
    panel = nil
  }
  func dismiss() {
    SelectionDiagnostics.record("bar dismissed")
    model.cancelPopulation()
    spelling.cancel()
    dismissPanel()
    actions = [:]
    population = PopulationState()
    populationSelection = nil
    groupID = nil
    activeSubmenu = nil
    submenuHistory.removeAll()
    redrawIcons = nil
    snapshot = nil
    model.selection = nil
    initialHandled = false
    builtinVisibility.removeAll()
    pasteboardGeneration = -1
  }
  func refreshIcons() {
    guard panel?.isVisible == true, !isBusy else { return }
    redrawIcons?()
  }
  @objc private func clicked(_ sender: NSButton) {
    if let id = sender.identifier?.rawValue { actions[id]?() }
  }
  @objc private func menuSelected(_ sender: NSMenuItem) {
    if let key = sender.representedObject as? String { actions[key]?() }
  }
  @objc private func openSettings() {
    dismiss()
    model.showSettings?()
  }
  @objc private func close() { dismiss() }
  var diagnosticGeometry: [String: Value] {
    let retained: [String: Value] = [
      "retainsSelection": .bool(snapshot != nil || model.selection != nil),
      "retainsMenu": .bool(activeSubmenu != nil || redrawIcons != nil || !submenuHistory.isEmpty),
      "retainedCatalogCount": .number(Double(population.actions.count + population.initial.count)),
      "retainedSpellingWords": .number(Double(spelling.retainedWordCount)),
      "spellingRequests": .number(Double(spelling.requestCount)),
    ]
    guard let panel else { return retained.merging(["visible": .bool(false)]) { _, new in new } }
    let onScreen =
      (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
      as? [[String: Any]] ?? []).contains {
        ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber
      }
    func hasScroll(_ view: NSView) -> Bool {
      (view as? NSScrollView)?.hasHorizontalScroller == true
        || view.subviews.contains(where: hasScroll)
    }
    return retained.merging([
      "visible": .bool(panel.isVisible), "x": .number(panel.frame.minX),
      "onScreen": .bool(onScreen),
      "y": .number(panel.frame.minY),
      "width": .number(panel.frame.width), "height": .number(panel.frame.height),
      "canBecomeKey": .bool(panel.canBecomeKey), "popupLevel": .bool(panel.level == .popUpMenu),
      "joinsOtherApplications": .bool(panel.collectionBehavior.contains(.canJoinAllApplications)),
      "horizontalScroll": .bool(panel.contentView.map(hasScroll) ?? false),
      "primaryX": primaryScreenX.map { .number(Double($0)) } ?? .null,
    ]) { _, new in new }
  }
  func diagnosticClickCopy() -> Bool {
    diagnosticClickAction(title: L10n.text("複製"))
  }
  private var diagnosticButtons: [NSButton] {
    func buttons(_ view: NSView) -> [NSButton] {
      view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons($0) }
    }
    return panel?.contentView.map(buttons) ?? []
  }
  var diagnosticActionTitles: [String] {
    diagnosticButtons.compactMap { $0.accessibilityLabel() ?? $0.toolTip }
  }
  func diagnosticClickAction(title: String) -> Bool {
    guard
      let button = diagnosticButtons.first(where: {
        $0.accessibilityLabel() == title || $0.toolTip == title
      })
    else { return false }
    button.performClick(nil)
    return true
  }
}
