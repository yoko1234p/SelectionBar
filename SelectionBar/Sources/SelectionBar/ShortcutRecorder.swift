import AppKit
import SelectionBarCore
import SwiftUI

struct ShortcutRecorder: View {
  @Binding var value: String
  var body: some View {
    HStack {
      Text(L10n.text("手動顯示快捷鍵"))
      Spacer()
      RecorderControl(value: $value).frame(width: 170, height: 28)
      if !value.isEmpty {
        Button {
          value = ""
        } label: {
          Image(systemName: "xmark.circle")
        }
        .buttonStyle(.plain).help(L10n.text("清除快捷鍵"))
      }
    }
  }
}

private struct RecorderControl: NSViewRepresentable {
  @Binding var value: String
  func makeNSView(context: Context) -> RecorderButton {
    let button = RecorderButton()
    button.onChange = { value = $0 }
    button.setAccessibilityIdentifier("selectionbar.shortcut-recorder")
    return button
  }
  func updateNSView(_ button: RecorderButton, context: Context) {
    button.value = value
    button.onChange = { value = $0 }
    button.updateTitle()
  }
}

final class RecorderButton: NSButton {
  var value = ""
  var onChange: ((String) -> Void)?
  private var recording = false
  private var keyboardMonitor: Any?
  private var windowObservers: [NSObjectProtocol] = []
  override var acceptsFirstResponder: Bool { true }
  init() {
    super.init(frame: .zero)
    bezelStyle = .rounded
    setButtonType(.momentaryPushIn)
    target = self
    action = #selector(toggleRecording)
    toolTip = L10n.text("點一下，再按快捷鍵；Esc 取消，Delete 清除。")
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  deinit {
    if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
  }
  private func stopRecording() {
    recording = false
    if let keyboardMonitor {
      NSEvent.removeMonitor(keyboardMonitor)
      self.keyboardMonitor = nil
    }
    for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
    windowObservers.removeAll()
    updateTitle()
  }
  @objc private func toggleRecording() {
    if recording {
      stopRecording()
      return
    }
    recording = true
    window?.makeFirstResponder(self)
    // Intercept before AppKit handles menu equivalents or text key bindings.
    // This monitor belongs only to the recording button's focused window.
    keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) {
      [weak self] event in
      guard let self, self.recording, let window = self.window,
        window.firstResponder === self,
        event.window === window || (event.window == nil && window.isKeyWindow && NSApp.isActive)
      else { return event }
      if event.type == .flagsChanged {
        self.flagsChanged(with: event)
      } else {
        self.keyDown(with: event)
      }
      return nil
    }
    if let window {
      for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
        windowObservers.append(
          NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
            [weak self] _ in
            Task { @MainActor in self?.stopRecording() }
          })
      }
    }
    updateTitle()
  }
  override func resignFirstResponder() -> Bool {
    stopRecording()
    return super.resignFirstResponder()
  }
  override func flagsChanged(with event: NSEvent) {
    if recording {
      title = ShortcutRecording.modifierLabel(UInt64(event.modifierFlags.rawValue)) + "…"
    } else {
      super.flagsChanged(with: event)
    }
  }
  override func keyDown(with event: NSEvent) {
    guard recording else { return super.keyDown(with: event) }
    if event.keyCode == 53 {
      stopRecording()
      return
    }
    if event.keyCode == 51
      && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    {
      value = ""
      onChange?("")
      stopRecording()
      return
    }
    do {
      let result = try ShortcutRecording.recorded(
        keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue))
      value = result
      onChange?(result)
      stopRecording()
      window?.makeFirstResponder(nil)
    } catch {
      title = L10n.text("加上 ⌘／⌃／⌥")
      NSSound.beep()
    }
  }
  func updateTitle() {
    title = recording ? L10n.text("請按快捷鍵…") : ShortcutRecording.label(value)
    setAccessibilityLabel(L10n.text("手動顯示快捷鍵：") + title)
  }
}
