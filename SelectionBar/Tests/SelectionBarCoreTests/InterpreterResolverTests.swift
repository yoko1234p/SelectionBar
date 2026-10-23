import Foundation
import XCTest

@testable import SelectionBarCore

final class InterpreterResolverTests: XCTestCase {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "selectionbar-interpreter-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func file(_ path: URL, content: String, executable: Bool = false) throws {
    try content.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: path.path)
  }

  func testAbsolutePathsAreValidatedWithoutStartingAShell() throws {
    XCTAssertEqual(try InterpreterResolver.resolve("/bin/sh", shell: "/missing/shell"), "/bin/sh")
    XCTAssertThrowsError(try InterpreterResolver.resolve(""))
    XCTAssertThrowsError(try InterpreterResolver.resolve("/tmp"))
    XCTAssertThrowsError(try InterpreterResolver.resolve("/missing/interpreter"))
    XCTAssertThrowsError(try InterpreterResolver.resolve("../relative"))
    XCTAssertThrowsError(try InterpreterResolver.resolve("name\0suffix"))
    let root = try fixture()
    let regular = root.appendingPathComponent("not-executable")
    try file(regular, content: "plain")
    XCTAssertThrowsError(try InterpreterResolver.resolve(regular.path))
  }

  func testLoginPathLookupIgnoresProfileNoiseAndKeepsExecutionEnvironmentMinimal() throws {
    let root = try fixture()
    let tools = root.appendingPathComponent("bin with spaces", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let interpreter = tools.appendingPathComponent("synthetic-python")
    try file(
      interpreter,
      content: "#!/bin/sh\nprintf '%s|%s' \"$PATH\" \"" + "$" + "{PROFILE_ONLY-unset}\"\n",
      executable: true)
    // Deliberately noisy profile. This isolated child home never changes the user's home.
    try file(
      root.appendingPathComponent(".zprofile"),
      content:
        "print 'profile banner'\nexport PROFILE_ONLY=private-to-profile\nexport PATH=\"$HOME/bin with spaces:/usr/bin:/bin\"\n"
    )
    let resolved = try InterpreterResolver.resolve(
      "synthetic-python", shell: "/bin/zsh", home: root, directory: root)
    XCTAssertEqual(resolved, interpreter.path)
    let result = try ProcessRunner.run(
      resolved, [], environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"],
      directory: root, timeout: 5)
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(result.stdout, "/usr/bin:/bin:/usr/sbin:/sbin|unset")
    XCTAssertFalse(result.stdout.contains("profile banner"))
  }

  func testBareNameIsNeverEvaluatedAsShellCodeAndRelativePathEntriesUsePackageDirectory() throws {
    let root = try fixture()
    let tools = root.appendingPathComponent("tools", isDirectory: true)
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
    let interpreter = tools.appendingPathComponent("runner")
    try file(interpreter, content: "#!/bin/sh\nexit 0\n", executable: true)
    try file(root.appendingPathComponent(".zprofile"), content: "export PATH=tools:/usr/bin:/bin\n")
    XCTAssertEqual(
      try InterpreterResolver.resolve("runner", shell: "/bin/zsh", home: root, directory: root),
      interpreter.path)
    XCTAssertThrowsError(
      try InterpreterResolver.resolve(
        "$(touch owned)", shell: "/bin/zsh", home: root, directory: root))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: root.appendingPathComponent("owned").path))
    XCTAssertThrowsError(
      try InterpreterResolver.resolve("missing", shell: "/bin/zsh", home: root, directory: root))
  }
}
