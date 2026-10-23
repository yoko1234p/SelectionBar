import Darwin
import Foundation

/// Content stays in private local files. No polling, networking or other app's
/// database access is needed by the sending app.
public enum WorkflowFiles {
    public static let destinationsDidChange = Notification.Name("local.pakwingho.workflows.note-destinations-changed")
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Personal App Workflows", isDirectory: true)
    }
    public static func prepare(_ root: URL) throws {
        guard root.isFileURL else { throw WorkflowError.invalid("只接受本機資料夾。") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            throw WorkflowError.invalid("交接資料夾無法安全開啟。")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public static func read(_ url: URL, limit: Int) throws -> Data {
        guard url.isFileURL, limit >= 0, limit < Int.max else { throw WorkflowError.invalid("只接受本機檔案。") }
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WorkflowError.invalid("無法讀取交接檔案，不接受符號連結。") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size >= 0, info.st_size <= limit else {
            throw WorkflowError.invalid("交接檔案類型、擁有人或大小不正確。")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw WorkflowError.invalid("交接檔案過大。") }
        return data
    }
    public static func write(_ data: Data, to url: URL, limit: Int) throws {
        guard data.count <= limit else { throw WorkflowError.invalid("資料超過大小上限。") }
        try prepare(url.deletingLastPathComponent())
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw WorkflowError.invalid("不會取代不明類型的設定檔。") }
        } else if errno != ENOENT { throw WorkflowError.invalid("無法檢查原有設定檔。") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func writeDraft(_ draft: WorkflowDraft, in root: URL = directory) throws -> URL {
        try draft.validate()
        let name = draft.id.uuidString + (draft.kind == .note ? ".edgedraft" : ".vocabdraft")
        let url = root.appendingPathComponent(name)
        try write(JSONEncoder().encode(draft), to: url, limit: 1_100_000)
        // Only generated handoff names are eligible for expiry cleanup.
        for old in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard old != url, ["edgedraft", "vocabdraft"].contains(old.pathExtension), UUID(uuidString: old.deletingPathExtension().lastPathComponent) != nil,
                let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                date < Date().addingTimeInterval(-86400)
            else { continue }
            try? FileManager.default.removeItem(at: old)
        }
        return url
    }
    public static func readDraft(_ url: URL, in root: URL = directory) throws -> WorkflowDraft {
        guard url.standardizedFileURL.deletingLastPathComponent() == root.standardizedFileURL,
            url.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath(),
            ["edgedraft", "vocabdraft"].contains(url.pathExtension)
        else { throw WorkflowError.invalid("只接受私人工作流程資料夾內的交接檔案。") }
        let draft = try JSONDecoder().decode(WorkflowDraft.self, from: read(url, limit: 1_100_000))
        try draft.validate()
        guard url.deletingPathExtension().lastPathComponent == draft.id.uuidString,
            url.pathExtension == (draft.kind == .note ? "edgedraft" : "vocabdraft")
        else { throw WorkflowError.invalid("交接檔案名稱與內容不符。") }
        return draft
    }
    public static func destinations(in root: URL = directory) throws -> NoteDestinations {
        let url = root.appendingPathComponent("edgenotes-destinations.json")
        if !FileManager.default.fileExists(atPath: url.path) { return NoteDestinations(notes: []) }
        let catalogue = try JSONDecoder().decode(NoteDestinations.self, from: read(url, limit: 256_000))
        try catalogue.validate()
        return catalogue
    }
    public static func publish(_ catalogue: NoteDestinations, in root: URL = directory) throws {
        try catalogue.validate()
        if let existing = try? destinations(in: root), existing == catalogue { return }
        try write(JSONEncoder().encode(catalogue), to: root.appendingPathComponent("edgenotes-destinations.json"), limit: 256_000)
        if root.standardizedFileURL == directory.standardizedFileURL {
            DistributedNotificationCenter.default().postNotificationName(destinationsDidChange, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }
}
