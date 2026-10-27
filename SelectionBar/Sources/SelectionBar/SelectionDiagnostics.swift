import Foundation
import OSLog

/// Explicit troubleshooting only. Never log selected text, URLs or key codes.
enum SelectionDiagnostics {
  private static let enabled = CommandLine.arguments.contains("--diagnose-selection")
  private static let logger = Logger(
    subsystem: "local.pakwingho.selectionbar", category: "selection")
  static func record(_ message: @autoclosure () -> String) {
    guard enabled else { return }
    let value = message()
    logger.notice("\(value, privacy: .public)")
  }
}
