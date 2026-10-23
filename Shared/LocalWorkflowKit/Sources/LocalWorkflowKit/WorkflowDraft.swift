import Foundation

public enum WorkflowError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

public struct DraftSource: Codable, Equatable, Sendable {
    public var application: String
    public var url: String?
    public var title: String?
    public init(application: String, url: String? = nil, title: String? = nil) {
        self.application = application
        self.url = url.flatMap(Self.webURL)
        self.title = title.map { String($0.prefix(256)) }
    }
    public static func webURL(_ value: String) -> String? {
        guard value.utf8.count <= 4096, let url = URL(string: value),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
            url.user == nil, url.password == nil
        else { return nil }
        return url.absoluteString
    }
    public func validate() throws {
        guard application.utf8.count <= 256, (title?.utf8.count ?? 0) <= 1024,
            url == nil || url.flatMap(Self.webURL) == url
        else { throw WorkflowError.invalid("來源資料或連結格式不正確。") }
    }
}

public struct WorkflowDraft: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case note, vocabulary }
    public var version = 1
    public var id: UUID
    public var kind: Kind
    public var text: String
    public var sentence: String?
    public var source: DraftSource?
    public var targetNoteID: UUID?
    public var createdAt: Date
    public var vocabularyFields: VocabularyDraftFields? = nil
    public init(kind: Kind, text: String, sentence: String? = nil, source: DraftSource? = nil, targetNoteID: UUID? = nil, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.text = text; self.sentence = sentence
        self.source = source; self.targetNoteID = targetNoteID; self.createdAt = createdAt
    }
    public func validate() throws {
        guard version == 1, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= (kind == .note ? 1_000_000 : 8192),
            (sentence?.utf8.count ?? 0) <= 8192, createdAt.timeIntervalSince1970.isFinite,
            (kind == .note || targetNoteID == nil), (kind == .vocabulary || vocabularyFields == nil)
        else { throw WorkflowError.invalid("交接內容版本、大小或目的地不正確。") }
        try source?.validate()
        try vocabularyFields?.validate()
    }
}

public struct VocabularyDraftFields: Codable, Equatable, Sendable {
    public var spelling: String
    public var language: String
    public var level: String
    public var reading: String
    public var meaning: String
    public var sentence: String
    public var sourceURL: String
    public init(spelling: String, language: String, level: String, reading: String = "", meaning: String = "", sentence: String = "", sourceURL: String = "") {
        self.spelling = spelling; self.language = language; self.level = level
        self.reading = reading; self.meaning = meaning; self.sentence = sentence; self.sourceURL = sourceURL
    }
    public func validate() throws {
        guard ["ja", "en"].contains(language), level.utf8.count <= 32, spelling.utf8.count <= 8192,
            [reading, meaning, sentence].allSatisfy({ $0.utf8.count <= 8192 }), sourceURL.utf8.count <= 4096
        else { throw WorkflowError.invalid("詞卡草稿欄位超過大小上限或語言不受支援。") }
    }
}

public struct NoteDestination: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var folderID: UUID
    public var title: String
    public var folderName: String
    public init(id: UUID, folderID: UUID, title: String, folderName: String) {
        self.id = id; self.folderID = folderID
        self.title = String(title.prefix(100)); self.folderName = String(folderName.prefix(100))
    }
}

public struct NoteDestinations: Codable, Equatable, Sendable {
    public var version = 1
    public var notes: [NoteDestination]
    public init(notes: [NoteDestination]) { self.notes = notes }
    public func validate() throws {
        guard version == 1, notes.count <= 100, Set(notes.map(\.id)).count == notes.count,
            notes.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 1024 && $0.folderName.utf8.count <= 1024 })
        else { throw WorkflowError.invalid("常用筆記清單無效，請在 EdgeNotes 重新儲存。") }
    }
}

public enum CleanupStep: String, Codable, CaseIterable, Identifiable, Sendable {
    case trim, normalizeLines, collapseSpaces, removeEmptyLines, lowercase, uppercase
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .trim: return "移除前後空白"
        case .normalizeLines: return "統一換行"
        case .collapseSpaces: return "合併重複空格"
        case .removeEmptyLines: return "移除空白行"
        case .lowercase: return "轉小寫"
        case .uppercase: return "轉大寫"
        }
    }
    public func apply(_ text: String) -> String {
        switch self {
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .normalizeLines: return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        case .collapseSpaces: return text.replacingOccurrences(of: "[\\t \\u00a0]+", with: " ", options: .regularExpression)
        case .removeEmptyLines: return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .lowercase: return text.lowercased()
        case .uppercase: return text.uppercased()
        }
    }
    public static func apply(_ steps: [Self], to text: String) throws -> String {
        guard text.utf8.count <= 1_000_000, steps.count <= 12 else { throw WorkflowError.invalid("文字配方最多 12 步、1 MB 輸入。") }
        var output = text
        for step in steps {
            try Task.checkCancellation()
            output = step.apply(output)
            guard output.utf8.count <= 1_000_000 else { throw WorkflowError.invalid("配方結果超過 1 MB。") }
        }
        return output
    }
}
