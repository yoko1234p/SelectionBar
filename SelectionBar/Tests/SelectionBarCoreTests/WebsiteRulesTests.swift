import XCTest

@testable import SelectionBarCore

final class WebsiteRulesTests: XCTestCase {
  func testImportedOriginalDomainHostAndPathPrefixSemantics() {
    let rules = WebsiteRules.imported(["example.com", "localhost", "127.0.0.1", "example.org/foo"])
    XCTAssertEqual(rules.map(\.kind), [.domain, .host, .host, .address])
    XCTAssertTrue(rules[0].matches("https://a.example.com/page"))
    XCTAssertFalse(rules[0].matches("https://evil-example.com"))
    XCTAssertFalse(rules[1].matches("https://sub.localhost/"))
    XCTAssertTrue(rules[2].matches("http://127.0.0.1:8080/page"))
    XCTAssertTrue(rules[3].matches("http://example.org:8080/foobar?private=query"))
    XCTAssertFalse(rules[3].matches("https://sub.example.org/foo"))
    XCTAssertFalse(rules[3].matches("https://example.org/bar/foo"))
    XCTAssertEqual(WebsiteRules.imported(["example.com/"])[0].kind, .address)
  }
  func testHostAndPathWildcardsNormalizeCaseWithoutRegexBacktracking() throws {
    let rule = try WebsiteRule(pattern: "https://*.EXAMPLE.com/foo*/bar*", kind: .address)
      .validated()
    XCTAssertTrue(rule.matches("http://api.example.com/foobar/barbaz?q=1"))
    XCTAssertFalse(rule.matches("https://example.com/foobar/barbaz"))
    XCTAssertFalse(rule.matches("https://api.example.net/foo/bar"))
    XCTAssertFalse(rule.matches("https://api.example.com/bar/foo"))
    XCTAssertTrue(LinearGlob.matches("a**b*c", "abbc"))
    XCTAssertFalse(LinearGlob.matches("a*b", "a"))
    XCTAssertFalse(LinearGlob.matches("ab*bc", "abc"))
    XCTAssertTrue(LinearGlob.matches("*日本*", "ab日本cd"))
    let expensive = String(repeating: "*a", count: 1800) + "b"
    XCTAssertFalse(LinearGlob.matches(expensive, String(repeating: "a", count: 64000)))
  }
  func testDisabledInvalidAndPasswordSchemeRulesNeverExclude() throws {
    let rule = WebsiteRule(pattern: "example.com", enabled: false)
    XCTAssertFalse(rule.matches("https://example.com"))
    XCTAssertThrowsError(try WebsiteRule(pattern: "https://example.com").validated())
    XCTAssertThrowsError(try WebsiteRule(pattern: "file:///tmp", kind: .address).validated())
    XCTAssertFalse(WebsiteRule(pattern: "example.com").matches("javascript:example.com"))
    XCTAssertTrue(WebsiteRule(pattern: "*.example.com").matches("https://sub.example.com"))
    XCTAssertFalse(WebsiteRule(pattern: "*.example.com").matches("https://example.com"))
  }
}
