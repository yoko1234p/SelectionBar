import Darwin
import Foundation
import XCTest

@testable import SelectionBarCore

final class OwnedProcessTests: XCTestCase {
  func testChildAndGrandchildShareTheOwnedGroup() throws {
    let result = try OwnedProcess.run(
      "/bin/sh",
      ["-c", "/bin/ps -o pgid= -p \"$$\"; /bin/sh -c '/bin/ps -o pgid= -p \"$$\"'"],
      environment: ["PATH": "/usr/bin:/bin"], timeout: 5, processGroup: getpgrp())
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32(String($0)) },
      [getpgrp(), getpgrp()])
  }

  func testArgumentsWorkingDirectoryAndLargeInputAreNotShellInterpolated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let input = Data(repeating: 65, count: 1024 * 1024)
    let result = try OwnedProcess.run(
      "/bin/sh",
      ["-c", "printf '%s\\n' \"$1\"; /bin/pwd; /bin/cat", "synthetic", "$(touch owned)"],
      input: input, environment: ["PATH": "/usr/bin:/bin"], directory: directory,
      timeout: 5, processGroup: getpgrp())
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.stdout.hasPrefix("$(touch owned)\n"))
    XCTAssertTrue(result.stdout.contains(directory.resolvingSymlinksInPath().path))
    XCTAssertTrue(result.stdout.hasSuffix(String(repeating: "A", count: input.count)))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: directory.appendingPathComponent("owned").path))
  }

  func testSignalStatusAndBoundedTimeoutUseOnlyTheDirectChild() throws {
    let signal = try OwnedProcess.run(
      "/bin/sh", ["-c", "printf before; kill -TERM \"$$\""], timeout: 5, processGroup: getpgrp())
    XCTAssertEqual(signal.status, SIGTERM)
    XCTAssertEqual(signal.terminationReason, "uncaughtSignal")
    XCTAssertEqual(signal.stdout, "before")
    let start = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(
      try OwnedProcess.run(
        "/bin/sleep", ["10"], timeout: 0.05, processGroup: getpgrp()))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
  }

  func testIgnoredLargeInputAndBackgroundPipeDoNotHangReaping() throws {
    let inputStart = ProcessInfo.processInfo.systemUptime
    let ignored = try OwnedProcess.run(
      "/bin/sleep", ["0.02"], input: Data(repeating: 65, count: 2 * 1024 * 1024),
      timeout: 2, processGroup: getpgrp())
    XCTAssertEqual(ignored.status, 0)
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - inputStart, 1.5)
    let start = ProcessInfo.processInfo.systemUptime
    let background = try OwnedProcess.run(
      "/bin/sh", ["-c", "/bin/sleep 3 & printf '%s\\n' \"$!\""],
      timeout: 2, processGroup: getpgrp())
    let pid = try XCTUnwrap(
      Int32(background.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { kill(pid, SIGTERM) }
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1.5)
  }

  func testForeignGroupInvalidEnvironmentAndOutputOverflowAreRejected() throws {
    XCTAssertThrowsError(
      try OwnedProcess.run(
        "/bin/echo", ["safe"], processGroup: getpgrp() + 100000))
    XCTAssertThrowsError(
      try OwnedProcess.run(
        "/bin/echo", ["bad\0argument"], processGroup: getpgrp()))
    XCTAssertThrowsError(
      try OwnedProcess.run(
        "/bin/echo", [], environment: ["bad=key": "value"], processGroup: getpgrp()))
    XCTAssertThrowsError(
      try OwnedProcess.run(
        "/usr/bin/head", ["-c", "8388609", "/dev/zero"], timeout: 5, processGroup: getpgrp()))
  }
}
