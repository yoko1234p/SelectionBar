import AppKit

/// At most one system request is in flight, plus one latest selection. AppKit
/// has no cancellation API for text checking; invalidating a generation discards
/// its callback and coalesces queued words instead of launching more requests.
@MainActor
final class SpellingSuggestions {
  struct LanguageResult: Equatable {
    var recognized: Bool
    var words: [String]
  }
  struct Result: Equatable {
    var words: [String] = []
    var recognizedInAnyLanguage = false
    var shouldShowFirst: Bool { !words.isEmpty && !recognizedInAnyLanguage }
  }
  typealias Check =
    @MainActor (String, String, @escaping @MainActor (LanguageResult) -> Void) -> Void
  private struct Key: Equatable {
    var word: String
    var selection: Date
    var configured: [String]
  }
  private struct Request {
    let id: UUID
    let key: Key
    let languages: [String]
    var responses: [LanguageResult] = []
  }
  private let check: Check
  private let available: () -> [String]
  private let preferred: () -> [String]
  private var desired: Request?
  private var inFlight = false
  private(set) var result = Result()
  private(set) var isPending = false
  private(set) var requestCount = 0
  var onUpdate: (() -> Void)?
  var retainedWordCount: Int { desired == nil ? 0 : 1 }

  init(
    available: @escaping () -> [String] = { NSSpellChecker.shared.availableLanguages },
    preferred: @escaping () -> [String] = { NSSpellChecker.shared.userPreferredLanguages },
    check: @escaping Check = SpellingSuggestions.nativeCheck
  ) {
    self.available = available
    self.preferred = preferred
    self.check = check
  }

  static func canCheck(_ text: String) -> Bool {
    // Checking the prefix first avoids scanning a megabyte-long selection just
    // to decide that it cannot be a spelling candidate.
    guard !text.isEmpty, text.utf8.prefix(513).count <= 512 else { return false }
    let scalars = text.unicodeScalars
    return scalars.contains(where: CharacterSet.letters.contains)
      && scalars.allSatisfy {
        CharacterSet.letters.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
          || "'’-".unicodeScalars.contains($0)
      }
  }

  static func languages(configured: [String], available: [String], preferred: [String]) -> [String]
  {
    let fallback = preferred.first(where: available.contains) ?? available.first
    var seen: Set<String> = []
    return configured.isEmpty
      ? fallback.map { [$0] } ?? []
      : Array(configured.prefix(2)).enumerated().compactMap { index, code in
        let candidate = code.isEmpty && index == 0 ? fallback : code
        guard let candidate, available.contains(candidate), seen.insert(candidate).inserted else {
          return nil
        }
        return candidate
      }
  }

  func prepare(word: String, selection: Date, configured: [String]) {
    guard Self.canCheck(word) else {
      cancel()
      return
    }
    let key = Key(word: word, selection: selection, configured: Array(configured.prefix(2)))
    guard desired?.key != key else { return }
    let languages = Self.languages(
      configured: key.configured, available: available(), preferred: preferred())
    result = Result()
    desired = Request(id: UUID(), key: key, languages: languages)
    isPending = !languages.isEmpty
    pump()
  }

  func cancel() {
    desired = nil
    isPending = false
    result = Result()
    onUpdate = nil
  }

  private func pump() {
    guard !inFlight, let current = desired, isPending else { return }
    guard current.responses.count < current.languages.count else {
      var seen: Set<String> = []
      result = Result(
        words: Array(
          current.responses.flatMap(\.words).filter {
            !$0.isEmpty && $0 != current.key.word && $0.utf8.prefix(513).count <= 512
              && seen.insert($0).inserted
          }.prefix(12)),
        recognizedInAnyLanguage: current.responses.contains(where: \.recognized))
      isPending = false
      onUpdate?()
      return
    }
    inFlight = true
    requestCount += 1
    check(current.key.word, current.languages[current.responses.count]) { [weak self] response in
      guard let self else { return }
      self.inFlight = false
      if self.desired?.id == current.id { self.desired?.responses.append(response) }
      self.pump()
    }
  }

  private static func nativeCheck(
    _ word: String, language: String, completion: @escaping @MainActor (LanguageResult) -> Void
  ) {
    let checker = NSSpellChecker.shared
    let range = NSRange(location: 0, length: (word as NSString).length)
    let tag = NSSpellChecker.uniqueSpellDocumentTag()
    _ = checker.requestChecking(
      of: word, range: range, types: NSTextCheckingResult.CheckingType.spelling.rawValue,
      options: [.orthography: NSOrthography.defaultOrthography(forLanguage: language)],
      inSpellDocumentWithTag: tag
    ) { _, results, _, _ in
      Task { @MainActor in
        defer { checker.closeSpellDocument(withTag: tag) }
        let misspelled = results.filter { $0.resultType.contains(.spelling) }
        let words =
          misspelled.contains(where: { $0.range == range })
          ? Array(
            (checker.guesses(
              forWordRange: range, in: word, language: language, inSpellDocumentWithTag: tag) ?? [])
              .prefix(12))
          : []
        completion(LanguageResult(recognized: misspelled.isEmpty, words: words))
      }
    }
  }
}
