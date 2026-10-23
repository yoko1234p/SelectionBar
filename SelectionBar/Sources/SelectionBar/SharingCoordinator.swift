import AppKit
import SelectionBarCore

@MainActor
final class SharingCoordinator {
  private var jobs: [UUID: ShareJob] = [:]
  func perform(name: String, values: [Value]) async throws {
    guard !values.isEmpty else { throw LibraryError.invalid(L10n.text("分享項目不可留空。")) }
    let items: [Any] = try values.map { value in
      if case .string(let text) = value { return text as NSString }
      let object = value.object
      if let raw = object["url"]?.string, let url = URL(string: raw) { return url as NSURL }
      if object["__richString"]?.bool == true, let rtf = object["rtf"]?.string,
        let rich = try? NSAttributedString(
          data: Data(rtf.utf8),
          options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
      {
        return rich
      }
      throw LibraryError.invalid(L10n.text("分享項目需要文字、URL 或 RichString。"))
    }
    guard let service = NSSharingService(named: NSSharingService.Name(name)),
      service.canPerform(withItems: items)
    else {
      throw LibraryError.invalid(L10n.text("macOS 分享服務不支援這些項目。"))
    }
    let id = UUID()
    let job = ShareJob(service: service)
    jobs[id] = job
    defer { jobs.removeValue(forKey: id) }
    try await job.perform(items)
  }
  func cancel() {
    let pending = Array(jobs.values)
    jobs.removeAll()
    for job in pending { job.cancel() }
  }
}

/// Each share owns its delegate and promise, so two unawaited shares cannot
/// overwrite a single continuation or lose their completion callbacks.
@MainActor
private final class ShareJob: NSObject, NSSharingServiceDelegate {
  private let service: NSSharingService
  private var continuation: CheckedContinuation<Void, Error>?
  init(service: NSSharingService) { self.service = service }
  func perform(_ items: [Any]) async throws {
    service.delegate = self
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        service.perform(withItems: items)
      }
    } onCancel: {
      Task { @MainActor in self.cancel() }
    }
  }
  func cancel() { finish(CancellationError()) }
  private func finish(_ error: Error? = nil) {
    let pending = continuation
    continuation = nil
    service.delegate = nil
    if let error { pending?.resume(throwing: error) } else { pending?.resume() }
  }
  func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { finish() }
  func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: Error) {
    finish((error as NSError).code == NSUserCancelledError ? nil : error)
  }
  func sharingService(
    _ service: NSSharingService, sourceWindowForShareItems items: [Any],
    sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
  ) -> NSWindow? {
    NSApp.keyWindow
  }
}
