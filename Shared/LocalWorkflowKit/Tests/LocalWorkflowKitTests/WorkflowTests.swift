import Foundation
import XCTest
@testable import LocalWorkflowKit

final class WorkflowTests: XCTestCase {
    func testDraftRoundTripPreservesSourceAndDestinationWithoutURLContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = WorkflowDraft(kind: .note, text: "中文\n한국어 日本語", source: .init(application: "SelectionBar", url: "https://example.test/page?q=one"), targetNoteID: UUID())
        let file = try WorkflowFiles.writeDraft(draft, in: root)
        XCTAssertEqual(try WorkflowFiles.readDraft(file, in: root), draft)
        XCTAssertFalse(file.absoluteString.contains("中文"))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testRejectsSymlinkOversizeBadVersionAndOutsideDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try WorkflowFiles.writeDraft(.init(kind: .vocabulary, text: "memory"), in: root)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try WorkflowFiles.read(link, limit: 10000))
        XCTAssertThrowsError(try WorkflowFiles.readDraft(file, in: root.appendingPathComponent("other")))
        XCTAssertThrowsError(try WorkflowFiles.read(file, limit: 4))
        var invalid = WorkflowDraft(kind: .vocabulary, text: "word")
        invalid.version = 2
        XCTAssertThrowsError(try invalid.validate())
        invalid.version = 1; invalid.text = String(repeating: "a", count: 8193)
        XCTAssertThrowsError(try invalid.validate())
    }
    func testWriteRejectsExistingSymlinkWithoutModifyingTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try WorkflowFiles.prepare(root)
        let original = root.appendingPathComponent("original")
        try Data("keep".utf8).write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try WorkflowFiles.write(Data("replace".utf8), to: link, limit: 100))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "keep")
    }
    func testCatalogueContainsOnlyChosenNoteMetadataAndDoesNotRewriteUnchangedData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogue = NoteDestinations(notes: [.init(id: UUID(), folderID: UUID(), title: "Work", folderName: "Inbox")])
        try WorkflowFiles.publish(catalogue, in: root)
        let file = root.appendingPathComponent("edgenotes-destinations.json")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        try WorkflowFiles.publish(catalogue, in: root)
        XCTAssertEqual(try WorkflowFiles.destinations(in: root), catalogue)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("attachments")); XCTAssertFalse(text.contains("body"))
    }
    func testCleanupIsOrderedUnicodeSafeAndBounded() throws {
        XCTAssertEqual(try CleanupStep.apply([.normalizeLines, .trim, .collapseSpaces], to: "  a\t  B\r\n 中文  "), "a B\n 中文")
        XCTAssertEqual(try CleanupStep.apply([.uppercase, .lowercase], to: "École 中文"), "école 中文")
        XCTAssertThrowsError(try CleanupStep.apply(Array(repeating: .trim, count: 13), to: "x"))
    }
    func testSourceRejectsActiveSchemesAndCredentials() throws {
        XCTAssertNil(DraftSource(application: "fixture", url: "javascript:alert(1)").url)
        XCTAssertNil(DraftSource(application: "fixture", url: "https://name:password@example.test").url)
        var source = DraftSource(application: "fixture")
        source.url = "file:///private/secret"
        XCTAssertThrowsError(try source.validate())
    }
}
