import AppKit
import Carbon
import Foundation

/// Uses the shipped Shortcuts scripting dictionary (`srct` / `run `), retaining
/// typed Apple-event output instead of flattening a workflow result into text.
enum ShortcutBridge {
  static func event(name: String, input: String?) throws -> NSAppleEventDescriptor {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw LibraryError.invalid("Shortcut name is required")
    }
    let specifier = NSAppleEventDescriptor.record()
    specifier.setDescriptor(
      NSAppleEventDescriptor(typeCode: fourCC("srct")), forKeyword: AEKeyword(keyAEDesiredClass))
    specifier.setDescriptor(
      NSAppleEventDescriptor(enumCode: OSType(formName)), forKeyword: AEKeyword(keyAEKeyForm))
    specifier.setDescriptor(
      NSAppleEventDescriptor(string: name), forKeyword: AEKeyword(keyAEKeyData))
    specifier.setDescriptor(NSAppleEventDescriptor.null(), forKeyword: AEKeyword(keyAEContainer))
    guard let object = specifier.coerce(toDescriptorType: typeObjectSpecifier) else {
      throw LibraryError.invalid("Cannot build Shortcut object specifier")
    }
    let event = NSAppleEventDescriptor(
      eventClass: fourCC("srct"), eventID: fourCC("run "),
      targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.shortcuts.events"),
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
    )
    event.setParam(object, forKeyword: AEKeyword(keyDirectObject))
    if let input {
      event.setParam(NSAppleEventDescriptor(string: input), forKeyword: fourCC("inpt"))
    }
    return event
  }
  static func run(name: String, input: String?) throws -> [String: Any] {
    let event = try event(name: name, input: input)
    let identifier = "com.apple.shortcuts.events"
    if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
        throw LibraryError.invalid("Shortcuts Events is unavailable")
      }
      let signal = DispatchSemaphore(value: 0)
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.activates = false
      var launchError: Error?
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        launchError = error
        signal.signal()
      }
      signal.wait()
      if let launchError { throw launchError }
    }
    var reply = AppleEvent()
    guard let descriptor = event.aeDesc else {
      throw LibraryError.invalid("Cannot build Shortcut event")
    }
    let status = AESendMessage(
      descriptor, &reply, AESendMode(kAEWaitReply | kAECanInteract), kNoTimeOut)
    guard status == noErr else {
      return ["error": "Shortcuts Events returned OSStatus \(status)", "errorNumber": Int(status)]
    }
    let response = NSAppleEventDescriptor(aeDescNoCopy: &reply)
    if let error = response.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)),
      error.int32Value != 0
    {
      return [
        "error": response.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue
          ?? "Shortcut failed",
        "errorNumber": Int(error.int32Value),
      ]
    }
    return [
      "value": response.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)).map(
        ExternalScripts.value) ?? NSNull()
    ]
  }
  private static func fourCC(_ text: String) -> OSType {
    text.utf8.reduce(0) { ($0 << 8) | OSType($1) }
  }
}
