import AppKit
import SelectionBarCore
import SwiftUI

struct BrowserSettingsView: View {
  @ObservedObject var model: SelectionModel
  @State private var selected = ""
  private var browsers: [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
      guard let id = $0.bundleIdentifier, let family = BrowserBridge.family(id) else {
        return false
      }
      return family != .basic
    }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
  }
  var body: some View {
    Section(L10n.text("瀏覽器")) {
      Toggle(
        L10n.text("讀取瀏覽器網頁資訊"),
        isOn: Binding(
          get: { model.library.settings.browserIntegration },
          set: {
            model.library.settings.browserIntegration = $0
            model.save()
          }))
      HStack {
        Picker(L10n.text("連接瀏覽器"), selection: $selected) {
          Text(L10n.text("選擇正在運行的瀏覽器")).tag("")
          ForEach(browsers, id: \.processIdentifier) { app in
            Text(app.localizedName ?? app.bundleIdentifier ?? "Browser").tag(
              app.bundleIdentifier ?? "")
          }
        }
        Button(L10n.text("連接…")) { model.authorizeBrowser(selected) }
          .disabled(selected.isEmpty || model.busy)
      }
      Text(
        L10n.text("自動顯示只使用已授權的瀏覽器；亦會先嘗試標準輔助使用選區。連接後如未能讀取選區，請在瀏覽器的開發選單允許 Apple Events 的 JavaScript。")
      )
      .font(.caption).foregroundStyle(.secondary)
    }
  }
}
