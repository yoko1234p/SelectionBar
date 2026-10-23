import AppKit
import SelectionBarCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  @ObservedObject var model: SelectionModel
  private var tab: String { model.settingsTab }
  @State private var query = ""
  @State private var showRecovery = false
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 14) {
        navigation(L10n.text("一般"), symbol: "slider.horizontal.3", value: "general")
        navigation(L10n.text("動作"), symbol: "puzzlepiece.extension", value: "actions")
        navigation("App", symbol: "app", value: "app")
        navigation(L10n.text("流程"), symbol: "arrow.triangle.branch", value: "workflows")
      }.frame(maxWidth: .infinity).padding(.vertical, 10).background(.bar)
      Divider()
      if model.busy {
        HStack {
          ProgressView().controlSize(.small)
          Text(L10n.text("正在執行…"))
          Spacer()
          Button(L10n.text("取消")) { model.cancelAction() }
        }.font(.callout).padding(10)
      }
      if model.conflict { banner(L10n.text("PopClip 正在運行，已暫停自動彈出。"), color: .orange) }
      if !model.permission {
        HStack {
          Label(L10n.text("輔助使用權限"), systemImage: "hand.raised")
          Spacer()
          Button(L10n.text("授權…")) { model.requestPermission() }
          Button {
            model.refreshStatus()
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }.font(.callout).padding(10).background(Color.orange.opacity(0.08))
      }
      if !model.notice.isEmpty { banner(model.notice, color: .blue) }
      if let error = model.storageError {
        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.text("設定檔需要處理")).font(.headline)
          Text(error).font(.caption)
          Button(L10n.text("保留原檔並重建設定…")) { showRecovery = true }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(
          Color.orange.opacity(0.1))
      }
      Group {
        switch tab {
        case "actions": actions
        case "app": appInfo
        case "workflows":
          WorkflowSettingsView(store: model.workflows, directory: model.workflowDirectory)
        default: general
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.storageError != nil)
    }.frame(minWidth: 480, minHeight: 480).preferredColorScheme(
      model.library.settings.appearance == "dark"
        ? .dark : model.library.settings.appearance == "light" ? .light : nil
    )
    .onAppear { model.refreshStatus() }
    .confirmationDialog(L10n.text("重建 SelectionBar 設定？"), isPresented: $showRecovery) {
      Button(L10n.text("保留原檔並重建")) { model.recoverStore() }
      Button(L10n.text("取消"), role: .cancel) {}
    } message: {
      Text(L10n.text("現有檔案會原封不動移到私人 Recovery 資料夾，然後建立預設設定。PopClip 的原設定不受影響。"))
    }
    .sheet(
      isPresented: Binding(
        get: { model.selectedExtension != nil }, set: { if !$0 { model.selectedExtension = nil } })
    ) {
      VStack(spacing: 0) {
        HStack {
          Text(isSpellingSettings ? L10n.text("拼字設定") : L10n.text("擴充設定")).font(.headline)
          Spacer()
          Button(L10n.text("完成")) { model.selectedExtension = nil }
        }.padding(16)
        Divider()
        extensionDetails
      }.frame(width: 560, height: isSpellingSettings ? 340 : 520)
    }
  }
  private func navigation(_ title: String, symbol: String, value: String) -> some View {
    Button {
      model.settingsTab = value
    } label: {
      VStack(spacing: 4) {
        Image(systemName: symbol).font(.system(size: 18, weight: .medium))
        Text(title).font(.caption)
      }.frame(width: 54, height: 45).background(
        tab == value ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).accessibilityIdentifier("selectionbar.tab." + value)
  }
  private func banner(_ text: String, color: Color) -> some View {
    Text(text).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(12)
      .background(color.opacity(0.1))
  }
  private var actions: some View { ActionListView(model: model) }
  private var isSpellingSettings: Bool {
    model.library.layout.contains {
      $0.id == model.selectedExtension && BuiltInAction($0.provider).id == "spelling"
    }
  }
  private var extensionDetails: some View {
    ScrollView {
      if let record = model.library.record(forSelection: model.selectedExtension) {
        VStack(alignment: .leading, spacing: 16) {
          HStack {
            ActionIcon(record: record, builtin: BuiltInAction("")).frame(width: 28, height: 28)
            Text(record.name).font(.title3.bold())
          }
          ExtensionSignInView(model: model, record: record)
          ForEach(record.config["options"]?.array ?? [], id: \.self) { option in
            optionView(option, record: record)
          }
          if record.actions.contains(where: { $0.kind == "module" }) {
            Button(L10n.text("讀取擴充選項")) { model.loadOptions(record) }.disabled(model.busy)
          }
          ForEach(record.warnings, id: \.self) {
            Text($0).font(.caption).foregroundStyle(.secondary)
          }
          Divider()
          Text(record.id).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
          HStack {
            Button(L10n.text("顯示套件副本")) {
              NSWorkspace.shared.activateFileViewerSelecting([
                URL(fileURLWithPath: record.packagePath)
              ])
            }
            Spacer()
            Text(record.actions.map(\.kind).joined(separator: " · ")).font(.caption2)
              .foregroundStyle(.secondary)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
      } else if let entry = model.library.layout.first(where: { $0.id == model.selectedExtension }),
        BuiltInAction(entry.provider).id == "spelling"
      {
        SpellingSettingsView(model: model)
      }
    }
  }
  @ViewBuilder private func optionView(_ option: Value, record: ExtensionRecord) -> some View {
    let d = option.object
    let id = d["identifier"]?.string ?? ""
    let type = d["type"]?.string ?? "string"
    let label = Manifest.localized(d["label"], fallback: id)
    let current = ExtensionOptions.effective([option], stored: record.options)[id] ?? .string("")
    let binding = Binding<String>(
      get: { current.string },
      set: { model.setOption(.string($0), record: record, id: id, definition: d) })
    if d["hidden"]?.bool != true && type != "password" {
      switch type {
      case "heading": Text(label).font(.headline)
      case "boolean":
        Toggle(
          label,
          isOn: Binding(
            get: { current.bool },
            set: { model.setOption(.bool($0), record: record, id: id, definition: d) }))
      case "multiple":
        let values = d["values"]?.array ?? []
        let labels = d["valuelabels"]?.array ?? []
        Picker(label, selection: binding) {
          if d["allownone"]?.bool == true { Text(L10n.text("無")).tag("") }
          ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            Text(
              index < labels.count
                ? Manifest.localized(labels[index], fallback: value.string) : value.string
            ).tag(value.string)
          }
          if d["allowother"]?.bool == true, !values.contains(current), !current.string.isEmpty {
            Text(L10n.text("其他：") + current.string).tag(current.string)
          }
        }
        if d["allowother"]?.bool == true { TextField(L10n.text("其他值"), text: binding) }
      case "secret": SecretOptionView(model: model, record: record, id: id, label: label)
      default:
        VStack(alignment: .leading, spacing: 6) {
          Text(label)
          if d["multiline"]?.bool == true {
            TextEditor(text: binding).frame(minHeight: 80).border(.quaternary)
          } else {
            TextField("", text: binding).textFieldStyle(.roundedBorder)
          }
        }
      }
      if let description = d["description"], !Manifest.localized(description).isEmpty {
        Text(Manifest.localized(description)).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private var general: some View {
    Form {
      Section(L10n.text("操作列")) {
        Toggle(L10n.text("啟用 SelectionBar"), isOn: setting(\.enabled))
        Toggle(
          L10n.text("登入時開啟"),
          isOn: Binding(get: { model.library.settings.launchAtLogin }, set: { model.setLogin($0) }))
        Picker(L10n.text("位置"), selection: setting(\.placement)) {
          Text(L10n.text("選區上方")).tag("above")
          Text(L10n.text("選區下方")).tag("below")
        }
        Picker(L10n.text("外觀"), selection: setting(\.appearance)) {
          Text(L10n.text("跟隨系統")).tag("auto")
          Text(L10n.text("深色")).tag("dark")
          Text(L10n.text("淺色")).tag("light")
        }
        HStack {
          Text(L10n.text("按鈕大小"))
          Slider(value: setting(\.size), in: 26...52)
          Text("\(Int(model.library.settings.size))")
        }
        HStack {
          Text(L10n.text("顯示延遲"))
          Slider(value: setting(\.delay), in: 0.05...0.6)
          Text(L10n.text("%1$@ 秒", String(format: "%.2f", model.library.settings.delay)))
        }
        ShortcutRecorder(value: setting(\.hotkey))
      }
      Section(L10n.text("不在以下 App 顯示")) {
        Toggle(L10n.text("只在名單內的 App 自動顯示"), isOn: setting(\.includedAppsOnly))
        ForEach(model.library.settings.excludedApps, id: \.self) { id in
          HStack {
            Text(id)
            Spacer()
            Button(L10n.text("移除")) {
              model.library.settings.excludedApps.removeAll { $0 == id }
              model.save()
            }
          }
        }
        Button(L10n.text("加入 App…")) {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.allowedContentTypes = [.application]
          if panel.runModal() == .OK, let url = panel.url,
            let id = Bundle(url: url)?.bundleIdentifier,
            !model.library.settings.excludedApps.contains(id)
          {
            model.library.settings.excludedApps.append(id)
            model.save()
          }
        }
      }
      WebsiteRulesView(model: model)
      BrowserSettingsView(model: model)
    }.formStyle(.grouped)
  }
  private var appInfo: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack {
          Image(systemName: "character.cursor.ibeam").font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.orange)
          VStack(alignment: .leading) {
            Text("SelectionBar").font(.title2.bold())
            Text(
              (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? L10n.text("開發版本")) + L10n.text(" · 獨立原生版本")
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
        Toggle(
          L10n.text("登入時開啟"),
          isOn: Binding(get: { model.library.settings.launchAtLogin }, set: { model.setLogin($0) }))
        Divider()
        Text(L10n.text("沿用你的 PopClip 工作流程")).font(.headline)
        HStack {
          Button(L10n.text("匯入原設定")) { model.importOriginal() }
          Button(L10n.text("重設為原排列")) { model.importOriginal(reset: true) }
        }.disabled(model.busy)
        Text(
          L10n.text(
            "%1$@ 個排列項目 · %2$@ 個擴充", String(describing: model.library.layout.count),
            String(describing: model.library.extensions.count))
        ).font(
          .caption
        ).foregroundStyle(.secondary)
        if let date = model.library.migratedAt {
          Text(L10n.text("上次匯入：") + date.formatted()).font(.caption).foregroundStyle(.secondary)
        }
        Divider()
        Text(L10n.text("相容官方擴充套件")).font(.headline)
        Text(L10n.text("plist／JSON／YAML、snippets、CommonJS／TypeScript 及官方文件列出的 19 個 JavaScript 模組。"))
          .font(
            .callout)
        Text(L10n.text("原 App 與新 App 的權限、登入及秘密選項分開儲存。需要登入的擴充可在擴充設定重新登入。")).font(.caption)
          .foregroundStyle(
            .secondary)
        Button(L10n.text("擴充文件")) {
          NSWorkspace.shared.open(URL(string: "https://www.popclip.app/dev/")!)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
    }
  }
  private func setting<T>(_ key: WritableKeyPath<SelectionBarCore.Settings, T>) -> Binding<T> {
    Binding(
      get: { model.library.settings[keyPath: key] },
      set: {
        model.library.settings[keyPath: key] = $0
        model.save()
      })
  }
}

struct ExtensionSignInView: View {
  @ObservedObject var model: SelectionModel
  let record: ExtensionRecord
  @State private var username = ""
  @State private var password = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if record.config["__hasauth"]?.bool == true {
        HStack {
          Button(L10n.text("登入擴充…")) {
            model.signIn(
              record,
              username: username.isEmpty ? (record.options["username"]?.string ?? "") : username,
              password: password)
          }.disabled(
            model.busy)
          Button(L10n.text("登出")) { model.signOut(record) }
        }
      }
      if record.config["options"]?.array.contains(where: { $0.object["type"]?.string == "password" }
      ) == true {
        TextField(L10n.text("使用者名稱"), text: $username)
        SecureField(L10n.text("密碼（不儲存）"), text: $password)
      }
    }
  }
}
struct SecretOptionView: View {
  @ObservedObject var model: SelectionModel
  let record: ExtensionRecord
  let id: String
  let label: String
  @State private var value = ""
  var body: some View {
    HStack {
      SecureField(label, text: $value)
      Button(L10n.text("儲存鑰匙圈")) {
        model.setSecret(value, record: record, option: id)
        value = ""
      }
    }
  }
}

struct ActionIcon: View {
  let record: ExtensionRecord?
  let builtin: BuiltInAction
  var overrideIcon: Value? = nil
  var assetRoot: URL? = nil
  var body: some View {
    Group {
      if let overrideIcon,
        let image = ExtensionIcon.image(
          config: overrideIcon, packageRoot: assetRoot ?? PrivateStore.root, size: 20)
      {
        Image(nsImage: image).resizable().scaledToFit()
      } else if let record,
        let image = ExtensionIcon.image(
          config: record.config["icon"], packageRoot: URL(fileURLWithPath: record.packagePath),
          size: 20, properties: record.config)
      {
        Image(nsImage: image).resizable().scaledToFit()
      } else {
        Image(systemName: record == nil ? builtin.symbol : "puzzlepiece.extension").resizable()
          .scaledToFit().fontWeight(.medium)
      }
    }.frame(width: 18, height: 18)
  }
}
