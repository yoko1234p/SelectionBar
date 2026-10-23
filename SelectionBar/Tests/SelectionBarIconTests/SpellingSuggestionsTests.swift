import AppKit
import XCTest

@testable import SelectionBar

final class SpellingSuggestionsTests: XCTestCase {
  @MainActor private final class Checker {
    var words: [String] = []
    var languages: [String] = []
    var callbacks: [@MainActor (SpellingSuggestions.LanguageResult) -> Void] = []
    lazy var suggestions = SpellingSuggestions(
      available: { ["en", "fr", "ko"] }, preferred: { ["en", "fr"] },
      check: { [unowned self] word, language, completion in
        self.words.append(word)
        self.languages.append(language)
        self.callbacks.append(completion)
      })
    func finish(recognized: Bool = false, words: [String]) {
      callbacks.removeFirst()(.init(recognized: recognized, words: words))
    }
  }

  @MainActor func testRepeatedRendersReuseResultAndDismissReleasesWord() {
    let checker = Checker()
    let selected = Date()
    for _ in 0..<100 {
      checker.suggestions.prepare(word: "beuatified", selection: selected, configured: [])
    }
    XCTAssertEqual(checker.words, ["beuatified"])
    checker.finish(words: ["beautified", "beatified"])
    checker.suggestions.prepare(word: "beuatified", selection: selected, configured: [])
    XCTAssertEqual(checker.words.count, 1)
    XCTAssertEqual(checker.suggestions.result.words, ["beautified", "beatified"])
    XCTAssertTrue(checker.suggestions.result.shouldShowFirst)
    checker.suggestions.cancel()
    XCTAssertEqual(checker.suggestions.retainedWordCount, 0)
    XCTAssertTrue(checker.suggestions.result.words.isEmpty)
  }

  @MainActor func testRapidSelectionChangesKeepOneRequestAndOnlyLatestQueuedWord() {
    let checker = Checker()
    let selected = Date()
    checker.suggestions.prepare(word: "first", selection: selected, configured: [])
    for index in 1...200 {
      checker.suggestions.prepare(
        word: "latest", selection: selected.addingTimeInterval(Double(index)), configured: [])
    }
    XCTAssertEqual(checker.words, ["first"])
    XCTAssertEqual(checker.callbacks.count, 1)
    checker.finish(words: ["stale"])
    XCTAssertEqual(checker.words, ["first", "latest"])
    XCTAssertTrue(checker.suggestions.result.words.isEmpty)
    checker.finish(words: ["current"])
    XCTAssertEqual(checker.suggestions.result.words, ["current"])
  }

  @MainActor func testCancelDiscardsLateResultAndDoesNotStartQueuedWork() {
    let checker = Checker()
    checker.suggestions.prepare(word: "first", selection: Date(), configured: [])
    checker.suggestions.prepare(word: "second", selection: Date(), configured: [])
    var updates = 0
    checker.suggestions.onUpdate = { updates += 1 }
    checker.suggestions.cancel()
    checker.finish(words: ["late"])
    XCTAssertEqual(updates, 0)
    XCTAssertEqual(checker.words, ["first"])
    XCTAssertEqual(checker.suggestions.retainedWordCount, 0)
    XCTAssertFalse(checker.suggestions.isPending)
  }

  @MainActor func testSecondLanguageAcceptingWordPreventsAutomaticCorrectionAndDeduplicates() {
    let checker = Checker()
    checker.suggestions.prepare(word: "bonjour", selection: Date(), configured: ["en", "fr"])
    checker.finish(words: [
      "bonjour", "bon jour", "bon jour", "", String(repeating: "x", count: 600),
    ])
    XCTAssertEqual(checker.languages, ["en", "fr"])
    checker.finish(recognized: true, words: [])
    XCTAssertEqual(checker.suggestions.result.words, ["bon jour"])
    XCTAssertFalse(checker.suggestions.result.shouldShowFirst)
    XCTAssertFalse(checker.suggestions.isPending)
  }

  @MainActor func testChangingLanguageInvalidatesSameSelectionAndLimitsToTwoLanguages() {
    let checker = Checker()
    let selected = Date()
    checker.suggestions.prepare(word: "word", selection: selected, configured: ["en"])
    checker.finish(words: ["first"])
    checker.suggestions.prepare(word: "word", selection: selected, configured: ["ko", "fr", "en"])
    XCTAssertTrue(checker.suggestions.result.words.isEmpty)
    checker.finish(words: ["한국어"])
    checker.finish(words: ["français"])
    XCTAssertEqual(checker.languages, ["en", "ko", "fr"])
    XCTAssertEqual(checker.suggestions.result.words, ["한국어", "français"])
  }

  @MainActor func testEligibilityRejectsDocumentsURLsNumbersAndWhitespace() {
    for word in ["beuatified", "École", "한국어", "日本語", "can't", "e\u{301}cole"] {
      XCTAssertTrue(SpellingSuggestions.canCheck(word), word)
    }
    for text in [
      "", "two words", "word\n", "https://example.com", "user@example.com", "123", "🙂",
      String(repeating: "a", count: 2_000_000),
    ] {
      XCTAssertFalse(SpellingSuggestions.canCheck(text), String(text.prefix(20)))
    }
  }

  @MainActor func testLanguageResolutionUsesOneSystemDefaultAndRejectsUnavailableLanguages() {
    let available = ["en", "fr", "ko"]
    XCTAssertEqual(
      SpellingSuggestions.languages(configured: [], available: available, preferred: ["en", "fr"]),
      ["en"])
    XCTAssertEqual(
      SpellingSuggestions.languages(
        configured: ["", "ko"], available: available, preferred: ["en"]), ["en", "ko"])
    XCTAssertEqual(
      SpellingSuggestions.languages(configured: ["en", "en"], available: available, preferred: []),
      ["en"])
    XCTAssertEqual(
      SpellingSuggestions.languages(
        configured: ["not-a-language"], available: available, preferred: []), [])
  }
}
