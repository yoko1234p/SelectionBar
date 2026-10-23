import AppKit
import EventKit
import SelectionBarCore

@MainActor
enum PermissionCoordinator {
  static func request(_ permissions: [String]) async throws {
    guard permissions.allSatisfy({ $0 == "reminders" }) else {
      throw LibraryError.invalid(L10n.text("未識別的系統權限。"))
    }
    guard permissions.contains("reminders") else { return }
    let status = EKEventStore.authorizationStatus(for: .reminder)
    var allowed = status == .fullAccess
    if status == .notDetermined {
      allowed = try await EKEventStore().requestFullAccessToReminders()
    }
    try Task.checkCancellation()
    guard allowed else {
      if let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
      {
        NSWorkspace.shared.open(url)
      }
      throw LibraryError.invalid(L10n.text("提醒事項權限未開啟。請在「系統設定 → 私隱與保安 → 提醒事項」允許 SelectionBar。"))
    }
  }
}
