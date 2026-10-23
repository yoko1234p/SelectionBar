import XCTest

@testable import SelectionBarCore

final class AssociatedApplicationsTests: XCTestCase {
  func testVariantsAreAlternativesWhileMultipleProductsAreAllRequired() throws {
    let config: [String: Value] = [
      "apps": .array([
        .object([
          "name": .string("Product A"), "checkInstalled": .bool(true),
          "bundleIdentifiers": .array([.string("fixture.a"), .string("fixture.a.setapp")]),
          "link": .string("https://example.invalid/a"),
        ]),
        .object([
          "name": .string("Product B"), "checkInstalled": .bool(true),
          "bundleIdentifiers": .array([.string("fixture.b")]),
          "link": .string("https://example.invalid/b"),
        ]),
        .object([
          "name": .string("Optional"), "checkInstalled": .bool(false),
          "bundleIdentifiers": .array([.string("fixture.optional")]),
        ]),
      ])
    ]
    let missing = AssociatedApplications.missing(in: config) { $0 == "fixture.a.setapp" }
    XCTAssertEqual(missing.map(\.name), ["Product B"])
    XCTAssertEqual(missing.first?.link?.absoluteString, "https://example.invalid/b")
    XCTAssertTrue(
      AssociatedApplications.missing(in: config) { ["fixture.a", "fixture.b"].contains($0) }.isEmpty
    )
  }
  func testMetadataNeverOpensLinksAndOnlyWebInstallLinksAreOffered() {
    let config: [String: Value] = [
      "app": .object([
        "name": .string("Fixture"), "checkinstalled": .bool(true),
        "bundleidentifiers": .array([.string("fixture.missing")]),
        "link": .string("file:///tmp/must-not-open"),
      ])
    ]
    let missing = AssociatedApplications.missing(in: config) { _ in false }
    XCTAssertEqual(missing.count, 1)
    XCTAssertNil(missing.first?.link)
    XCTAssertTrue(
      MissingApplicationsError(applications: missing).localizedDescription.contains("Fixture"))
  }
}
