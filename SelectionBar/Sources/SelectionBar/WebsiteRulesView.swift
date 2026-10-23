import SelectionBarCore
import SwiftUI

struct WebsiteRulesView: View {
  @ObservedObject var model: SelectionModel
  @State private var editing: WebsiteRule?
  var body: some View {
    Section(L10n.text("不在以下網站自動顯示")) {
      ForEach(model.library.settings.websiteRules) { rule in
        HStack {
          Toggle(
            rule.pattern,
            isOn: Binding(
              get: { rule.enabled },
              set: { enabled in
                model.editLibrary { library in
                  if let index = library.settings.websiteRules.firstIndex(where: {
                    $0.id == rule.id
                  }) {
                    library.settings.websiteRules[index].enabled = enabled
                  }
                }
              })
          ).lineLimit(1).help(rule.pattern)
          Spacer()
          Button(L10n.text("編輯")) { editing = rule }.buttonStyle(.borderless)
          Button {
            model.editLibrary { $0.settings.websiteRules.removeAll { $0.id == rule.id } }
          } label: {
            Image(systemName: "minus.circle")
          }.buttonStyle(.borderless).help(L10n.text("移除網站規則"))
        }
      }
      HStack {
        Button(L10n.text("加入網站…")) { editing = WebsiteRule(pattern: "") }.accessibilityIdentifier(
          "selectionbar.website.add")
        if let address = model.selection?.context.browserURL,
          let host = URLComponents(string: address)?.host
        {
          Button(L10n.text("加入 ") + host) { editing = WebsiteRule(pattern: host) }
        }
      }
      Text(L10n.text("網站規則只影響自動彈出；手動快捷鍵仍可使用。")).font(.caption).foregroundStyle(.secondary)
    }.sheet(item: $editing) { rule in
      WebsiteRuleEditor(rule: rule) { changed in
        model.editLibrary { library in
          if let index = library.settings.websiteRules.firstIndex(where: { $0.id == changed.id }) {
            library.settings.websiteRules[index] = changed
          } else {
            library.settings.websiteRules.append(changed)
          }
        }
      }
    }
  }
}

private struct WebsiteRuleEditor: View {
  let rule: WebsiteRule
  let save: (WebsiteRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var pattern = ""
  @State private var kind: WebsiteRule.Kind = .domain
  @State private var testAddress = ""
  @State private var error = ""
  private var candidate: WebsiteRule {
    WebsiteRule(id: rule.id, pattern: pattern, kind: kind, enabled: rule.enabled)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(L10n.text("網站規則")).font(.headline)
      Picker(L10n.text("比對範圍"), selection: $kind) {
        Text(L10n.text("整個網域")).tag(WebsiteRule.Kind.domain)
        Text(L10n.text("指定主機")).tag(WebsiteRule.Kind.host)
        Text(L10n.text("指定網址")).tag(WebsiteRule.Kind.address)
      }.pickerStyle(.segmented)
      TextField(kind == .domain ? "example.com" : "https://example.com/path/*", text: $pattern)
        .textFieldStyle(.roundedBorder).accessibilityIdentifier("selectionbar.website.pattern")
      Text(
        kind == .domain
          ? L10n.text("包括這個網域及其子網域；*.example.com 只包括子網域。")
          : kind == .host
            ? L10n.text("只比對這個主機名稱，不包括子網域。") : L10n.text("依主機及路徑開頭比對，忽略 http／https、埠號及查詢參數；亦可使用 *。")
      )
      .font(.caption).foregroundStyle(.secondary)
      Divider()
      TextField(L10n.text("貼上網址測試（不會開啟網頁）"), text: $testAddress).textFieldStyle(.roundedBorder)
      if !testAddress.isEmpty {
        Label(
          candidate.matches(testAddress) ? L10n.text("符合這條規則") : L10n.text("不符合這條規則"),
          systemImage: candidate.matches(testAddress) ? "checkmark.circle" : "minus.circle"
        )
        .font(.callout)
      }
      if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.red) }
      HStack {
        Button(L10n.text("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(L10n.text("儲存")) {
          do {
            save(try candidate.validated())
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).accessibilityIdentifier("selectionbar.website.save")
      }
    }.padding(22).frame(width: 440).onAppear {
      pattern = rule.pattern
      kind = rule.kind
    }
  }
}
