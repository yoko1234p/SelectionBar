import Foundation
import XCTest

@testable import SelectionBarCore

final class BuiltInCatalogTests: XCTestCase {
  func testRestoreDoesNotChangeExistingLayoutOrReenableDisabledInstances() throws {
    var library = Library.initial
    let spelling = try XCTUnwrap(library.layout.firstIndex { $0.provider.hasSuffix(".spelling") })
    library.layout[spelling].enabled = false
    let original = library
    try library.addBuiltIn("spelling")
    XCTAssertEqual(library, original)
    try library.addBuiltIn("alternatingcase")
    XCTAssertEqual(Array(library.layout.dropLast()), original.layout)
    XCTAssertEqual(library.layout.last?.provider, "app.popclip.builtin.alternatingcase")
    XCTAssertTrue(library.layout.last?.enabled == true)
    XCTAssertThrowsError(try library.addBuiltIn("unknown"))
    XCTAssertEqual(library.layout.count, original.layout.count + 1)
  }

  func testAlternatingCasePreservesUncasedUnicodeAndOnlyCountsLetters() {
    XCTAssertEqual(BuiltInCatalog.alternatingCase("HELLO, world!"), "hElLo, WoRlD!")
    XCTAssertEqual(BuiltInCatalog.alternatingCase("中文 a1b🙂c éÖ"), "中文 a1B🙂c Éö")
    XCTAssertEqual(BuiltInCatalog.alternatingCase("a e\u{301}X"), "a E\u{301}x")
  }

  func testOnlineActionsKeepSpecialCharactersInsideTheirOwnParameterOrPath() throws {
    let text = "서울/中環 & x=?#% 🙂"
    let translate = try BuiltInCatalog.webURL(for: "googletranslate", text: text)
    let parts = try XCTUnwrap(URLComponents(url: translate, resolvingAgainstBaseURL: false))
    XCTAssertEqual(parts.host, "translate.google.com")
    XCTAssertEqual(parts.queryItems?.first { $0.name == "text" }?.value, text)
    XCTAssertNil(parts.fragment)
    let map = try BuiltInCatalog.webURL(for: "navermap", text: text)
    let route = try XCTUnwrap(URLComponents(url: map, resolvingAgainstBaseURL: false))
    XCTAssertEqual(route.host, "map.naver.com")
    XCTAssertEqual(
      String(route.percentEncodedPath.dropFirst("/p/search/".count)).removingPercentEncoding, text)
    XCTAssertNil(route.query)
    XCTAssertNil(route.fragment)
    XCTAssertThrowsError(
      try BuiltInCatalog.webURL(for: "navermap", text: String(repeating: "中", count: 3000)))
    XCTAssertThrowsError(try BuiltInCatalog.webURL(for: "googletranslate", text: ""))
  }

  func testOldSettingsGetSpellingDefaultsAndNewSettingsRoundTrip() throws {
    var settings = try JSONDecoder().decode(Settings.self, from: Data("{\"enabled\":false}".utf8))
    XCTAssertFalse(settings.enabled)
    XCTAssertTrue(settings.spellingShowFirst)
    XCTAssertEqual(settings.spellingLanguages, [])
    settings.spellingShowFirst = false
    settings.spellingLanguages = ["en", "ko"]
    XCTAssertEqual(
      try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)), settings)
    let limited = try JSONDecoder().decode(
      Settings.self, from: Data("{\"spellingLanguages\":[\"en\",\"ko\",\"fr\"]}".utf8))
    XCTAssertEqual(limited.spellingLanguages, ["en", "ko"])
  }
}
