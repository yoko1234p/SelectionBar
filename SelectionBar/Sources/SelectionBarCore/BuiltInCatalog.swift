import Foundation

/// Native actions are available without importing or executing an extension.
public struct BuiltInDescriptor: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let symbol: String
  public let detail: String
  public var provider: String { "app.popclip.builtin." + id }
}

public enum BuiltInCatalog {
  public static let actions: [BuiltInDescriptor] = [
    .init(
      id: "spelling", title: L10n.text("拼字"), symbol: "text.badge.checkmark",
      detail: L10n.text("本機拼字候選字；按一下替換，Shift 按一下複製")),
    .init(
      id: "openlink", title: L10n.text("開啟連結"), symbol: "link", detail: L10n.text("開啟所選文字中的網址")),
    .init(
      id: "search", title: L10n.text("搜尋"), symbol: "magnifyingglass",
      detail: L10n.text("以 Google 搜尋所選文字")),
    .init(id: "cut", title: L10n.text("剪下"), symbol: "scissors", detail: L10n.text("剪下可編輯欄位中的選區")),
    .init(id: "copy", title: L10n.text("複製"), symbol: "doc.on.doc", detail: L10n.text("複製所選文字")),
    .init(
      id: "paste", title: L10n.text("貼上"), symbol: "doc.on.clipboard",
      detail: L10n.text("將剪貼簿貼入可編輯欄位")),
    .init(
      id: "plainpaste", title: L10n.text("純文字貼上"), symbol: "text.badge.minus",
      detail: L10n.text("移除格式後貼上")),
    .init(
      id: "lookup", title: L10n.text("查字典"), symbol: "character.book.closed",
      detail: L10n.text("使用本機 macOS 字典")),
    .init(
      id: "revealfile", title: L10n.text("Finder 顯示"), symbol: "folder",
      detail: L10n.text("在 Finder 顯示所選檔案路徑")),
    .init(
      id: "uppercase", title: L10n.text("大寫"), symbol: "textformat.abc",
      detail: L10n.text("將文字轉為大寫")),
    .init(
      id: "lowercase", title: L10n.text("小寫"), symbol: "textformat", detail: L10n.text("將文字轉為小寫")),
    .init(
      id: "alternatingcase", title: L10n.text("交替大小寫"), symbol: "textformat.size",
      detail: L10n.text("交替轉換有大小寫的字母，保留標點及其他文字")),
    .init(
      id: "googletranslate", title: "Google Translate", symbol: "character.bubble",
      detail: L10n.text("按一下才將文字帶到 Google 翻譯網頁")),
    .init(
      id: "navermap", title: "Naver Map", symbol: "mappin.and.ellipse",
      detail: L10n.text("按一下才在 Naver 地圖搜尋所選地點")),
    .init(
      id: "speak", title: L10n.text("朗讀"), symbol: "speaker.wave.2",
      detail: L10n.text("使用 macOS 聲音朗讀，再按一下停止")),
    .init(
      id: "openmail", title: L10n.text("傳送電郵"), symbol: "envelope", detail: L10n.text("開啟所選電郵地址")),
    .init(
      id: "favorites", title: L10n.text("收藏到筆記"), symbol: "star.bubble",
      detail: L10n.text("送到常用 EdgeNotes 筆記，保留來源連結")),
    .init(
      id: "vocabulary", title: L10n.text("詞卡草稿"), symbol: "rectangle.stack.badge.plus",
      detail: L10n.text("連原句及來源送到 NotchHub，確認後加入個人詞庫")),
    .init(
      id: "recipes", title: L10n.text("文字配方"), symbol: "line.3.horizontal.decrease.circle",
      detail: L10n.text("依次清理文字，再複製、貼上或收藏到筆記")),
  ]

  public static func action(_ id: String) -> BuiltInDescriptor? {
    actions.first { $0.id == id }
  }

  public static func alternatingCase(_ text: String) -> String {
    var uppercase = false
    var result = ""
    result.reserveCapacity(text.utf8.count)
    for character in text {
      let original = String(character)
      let lower = original.lowercased()
      let upper = original.uppercased()
      guard lower != upper else {
        result += original
        continue
      }
      result += uppercase ? upper : lower
      uppercase.toggle()
    }
    return result
  }

  public static func webURL(for id: String, text: String) throws -> URL {
    guard !text.isEmpty, text.utf8.count <= 8000 else {
      throw LibraryError.invalid(L10n.text("網頁動作最多接受 8 KB 文字，請縮小選區。"))
    }
    let url: URL?
    switch id {
    case "googletranslate":
      var parts = URLComponents(string: "https://translate.google.com/")!
      parts.queryItems = [
        .init(name: "sl", value: "auto"), .init(name: "tl", value: "zh-TW"),
        .init(name: "text", value: text), .init(name: "op", value: "translate"),
      ]
      url = parts.url
    case "navermap":
      var parts = URLComponents(string: "https://map.naver.com/")!
      // Encoding as one path component prevents '/' or '?' in a place name
      // from changing the destination route.
      var allowed = CharacterSet.urlPathAllowed
      allowed.remove(charactersIn: "/%?#")
      parts.percentEncodedPath =
        "/p/search/" + (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
      url = parts.url
    default: throw LibraryError.invalid(L10n.text("找不到此網頁動作。"))
    }
    guard let url else { throw LibraryError.invalid(L10n.text("無法建立網頁網址。")) }
    return url
  }
}

extension Library {
  /// Restore a missing action without changing existing entries or re-enabling
  /// an action the user deliberately disabled.
  public mutating func addBuiltIn(_ id: String) throws {
    guard let action = BuiltInCatalog.action(id) else {
      throw LibraryError.invalid(L10n.text("找不到此內置動作。"))
    }
    guard !layout.contains(where: { $0.kind == 1 && $0.provider == action.provider }) else {
      return
    }
    layout.append(
      LayoutEntry(
        id: UUID().uuidString, provider: action.provider,
        order: (layout.filter { $0.parent == nil }.map(\.order).max() ?? -1000) + 1000))
  }
}
