import Darwin
import Foundation

/// Resolves an interpreter separately from the environment used to execute an extension.
public enum InterpreterResolver {
  public static func resolve(
    _ name: String, shell: String? = nil, home: URL? = nil, directory: URL? = nil
  ) throws -> String {
    guard !name.isEmpty, name.utf8.count <= 4096, !name.contains("\0") else {
      throw LibraryError.invalid("Interpreter name is empty or invalid.")
    }
    if name.hasPrefix("/") { return try executable(name) }
    guard !name.contains("/") else {
      throw LibraryError.invalid("Interpreter must be an absolute path or bare executable name.")
    }
    let fixtureOrUserHome = home ?? FileManager.default.homeDirectoryForCurrentUser
    let workingDirectory =
      directory ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    guard fixtureOrUserHome.isFileURL, workingDirectory.isFileURL else {
      throw LibraryError.invalid("Interpreter lookup requires local directories.")
    }
    let preferredShell =
      shell ?? ProcessInfo.processInfo.environment["SHELL"]
      ?? getpwuid(getuid()).flatMap { entry in
        entry.pointee.pw_shell.map { String(cString: $0) }
      } ?? "/bin/zsh"
    let shellPath = try executable(preferredShell)
    let marker = "selectionbar-path-" + UUID().uuidString
    // Both the marker and interpreter name remain data. No executable name or PATH
    // component is interpolated into shell code, and profile output is not script output.
    let result = try ProcessRunner.run(
      shellPath,
      ["-l", "-c", "printf '\\0%s\\0%s\\0' \"$1\" \"$PATH\"", "selectionbar-path", marker],
      environment: [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
        "HOME": fixtureOrUserHome.path,
      ], directory: workingDirectory, timeout: 0, processGroup: getpgrp())
    guard result.status == 0,
      let delimiter = result.stdout.range(of: "\0" + marker + "\0", options: .backwards),
      let end = result.stdout[delimiter.upperBound...].firstIndex(of: "\0")
    else { throw LibraryError.invalid("The login shell could not provide its executable PATH.") }
    let path = String(result.stdout[delimiter.upperBound..<end])
    for component in path.split(separator: ":", omittingEmptySubsequences: false) {
      let base: URL
      if component.hasPrefix("/") {
        base = URL(fileURLWithPath: String(component), isDirectory: true)
      } else {
        base = workingDirectory.appendingPathComponent(String(component), isDirectory: true)
      }
      let candidate = base.appendingPathComponent(name).standardizedFileURL
      if let value = try? executable(candidate.path) { return value }
    }
    throw LibraryError.invalid("Interpreter was not found in the login shell PATH: \(name)")
  }

  private static func executable(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0") else {
      throw LibraryError.invalid("Interpreter path must be absolute.")
    }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
      FileManager.default.isExecutableFile(atPath: url.path)
    else { throw LibraryError.invalid("Interpreter is not an executable file: \(url.path)") }
    return url.path
  }
}
