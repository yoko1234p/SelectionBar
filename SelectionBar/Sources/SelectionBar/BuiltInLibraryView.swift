import AppKit
import SelectionBarCore
import SwiftUI

struct BuiltInLibraryView: View {
  @ObservedObject var model: SelectionModel
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(L10n.text("內置動作")).font(.headline)
        Spacer()
        Button(L10n.text("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
      }.padding(16)
      TextField(L10n.text("搜尋內置動作"), text: $query).textFieldStyle(.roundedBorder)
        .accessibilityIdentifier("selectionbar.library.search")
        .padding(.horizontal, 16).padding(.bottom, 10)
      Divider()
      List {
        ForEach(
          BuiltInCatalog.actions.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
              || $0.id.localizedCaseInsensitiveContains(query)
          }
        ) { action in
          let existing = model.library.layout.first {
            $0.provider == action.provider && $0.kind == 1
          }
          HStack(spacing: 12) {
            Image(systemName: action.symbol).font(.system(size: 18)).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
              Text(action.title).font(.body.weight(.medium))
              Text(action.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(
              existing == nil
                ? L10n.text("加入")
                : existing?.enabled == true ? L10n.text("已加入") : L10n.text("已加入・停用")
            ) {
              model.editLibrary { try $0.addBuiltIn(action.id) }
            }.disabled(existing != nil)
              .accessibilityIdentifier("selectionbar.library.add." + action.id)
          }.padding(.vertical, 4)
        }
      }.listStyle(.plain)
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Text(L10n.text("其他擴充")).font(.subheadline.bold())
        Text(
          L10n.text(
            "Notes 沿用 EdgeNotes，可選資料夾及筆記。短網址、OpenAI Chat、Evernote 可另外匯入相應擴充；部分需要帳戶、API 金鑰或已安裝 App。")
        )
        .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(L10n.text("匯入擴充…")) {
            dismiss()
            model.chooseImport()
          }
          Link(
            L10n.text("查看官方擴充"), destination: URL(string: "https://www.popclip.app/extensions/")!)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }.frame(width: 550, height: 610)
  }
}

struct SpellingSettingsView: View {
  @ObservedObject var model: SelectionModel
  private let languages = NSSpellChecker.shared.availableLanguages
  private var configured: [String] { model.library.settings.spellingLanguages }
  private func language(_ index: Int) -> Binding<String> {
    Binding(
      get: { configured.indices.contains(index) ? configured[index] : "" },
      set: { value in
        var values = configured
        while values.count < 2 { values.append("") }
        values[index] = value
        model.library.settings.spellingLanguages = values
        model.save()
      })
  }
  private func name(_ code: String) -> String {
    Locale.autoupdatingCurrent.localizedString(forIdentifier: code) ?? code
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(L10n.text("拼字修正"), systemImage: "text.badge.checkmark").font(.headline)
      Toggle(
        L10n.text("選中錯字時優先顯示候選字"),
        isOn: Binding(
          get: { model.library.settings.spellingShowFirst },
          set: {
            model.library.settings.spellingShowFirst = $0
            model.save()
          })
      )
      .accessibilityIdentifier("selectionbar.spelling.show-first")
      ForEach(0..<2, id: \.self) { index in
        Picker(index == 0 ? L10n.text("主要語言") : L10n.text("第二語言"), selection: language(index)) {
          Text(index == 0 ? L10n.text("跟隨系統") : L10n.text("無")).tag("")
          ForEach(languages, id: \.self) { code in Text(name(code)).tag(code) }
          if configured.indices.contains(index), !configured[index].isEmpty,
            !languages.contains(configured[index])
          {
            Text(configured[index] + L10n.text("（系統未提供）")).tag(configured[index])
          }
        }.accessibilityIdentifier("selectionbar.spelling.language.\(index)")
      }
      Text(L10n.text("只檢查可編輯欄位中的單一字詞。按候選字替換；Shift 按一下只複製；↑ 返回所有動作。任何已選語言接受此字時，保留一般工具列。"))
        .font(.caption).foregroundStyle(.secondary)
      Text(L10n.text("候選字由 macOS 本機拼字字典提供。這份語言清單與 OCR／翻譯支援語言不同。"))
        .font(.caption).foregroundStyle(.secondary)
    }.padding(20)
  }
}
