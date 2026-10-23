import Foundation

public struct TextRecipe: Codable, Identifiable, Equatable, Sendable {
    public enum Destination: String, Codable, CaseIterable, Sendable { case copy, paste, note }
    public var id: UUID
    public var name: String
    public var steps: [CleanupStep]
    public var destination: Destination
    public var targetNoteID: UUID?
    public init(id: UUID = UUID(), name: String, steps: [CleanupStep], destination: Destination, targetNoteID: UUID? = nil) {
        self.id = id; self.name = name; self.steps = steps; self.destination = destination; self.targetNoteID = targetNoteID
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256, steps.count <= 12,
            destination == .note || targetNoteID == nil
        else { throw WorkflowError.invalid("配方名稱、步驟或目的地不正確。") }
    }
}

public enum DraftContext {
    public static func sentence(in text: String, selected: String) -> String? {
        guard !selected.isEmpty, text.utf8.count <= 1_000_000 else { return nil }
        let value = text as NSString
        let match = value.range(of: selected)
        guard match.location != NSNotFound else { return nil }
        let start = max(0, match.location - 512)
        let end = min(value.length, NSMaxRange(match) + 512)
        guard let range = Range(NSRange(location: start, length: end - start), in: text) else { return String(selected.prefix(1000)) }
        let excerpt = String(text[range])
        let lines = excerpt.components(separatedBy: .newlines)
        return String((lines.first(where: { $0.contains(selected) }) ?? excerpt).prefix(2000))
    }
}
