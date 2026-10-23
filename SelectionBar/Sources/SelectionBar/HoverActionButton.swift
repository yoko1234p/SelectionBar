import AppKit

/// Folder hover never invokes a leaf action. The delayed click uses the same
/// generation-scoped callback as an explicit click and cancels on pointer exit.
@MainActor
final class HoverActionButton: NSButton {
  var opensOnHover = false
  private var tracking: NSTrackingArea?
  private var pending: DispatchWorkItem?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    tracking = area
  }
  override func mouseEntered(with event: NSEvent) {
    guard opensOnHover, isEnabled else { return }
    pending?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.window?.isVisible == true, self.opensOnHover, self.isEnabled else {
        return
      }
      self.performClick(nil)
    }
    pending = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: item)
  }
  override func mouseExited(with event: NSEvent) {
    pending?.cancel()
    pending = nil
  }
  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      pending?.cancel()
      pending = nil
    }
    super.viewWillMove(toWindow: newWindow)
  }
  deinit { pending?.cancel() }
}
