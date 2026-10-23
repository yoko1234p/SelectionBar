import Foundation

public struct AssociatedApplication: Equatable, Sendable {
  public var name: String
  public var identifiers: [String]
  public var link: URL?
}

public enum AssociatedApplications {
  /// Each dictionary describes one required product; bundle identifiers within
  /// it are alternatives (for example the standalone and Setapp editions).
  public static func missing(
    in config: [String: Value], installed: (String) -> Bool
  ) -> [AssociatedApplication] {
    let values = config["apps"]?.array ?? config["app"].map { [$0] } ?? []
    return values.compactMap { value in
      let app = Manifest.normalized(value.object.mapValues(\.any))
      guard app["checkinstalled"]?.bool == true else { return nil }
      let identifiers = app["bundleidentifiers"]?.array.map(\.string).filter { !$0.isEmpty } ?? []
      guard !identifiers.contains(where: installed) else { return nil }
      let candidate = app["link"].flatMap { URL(string: $0.string) }
      let link = candidate.flatMap {
        ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
      }
      return AssociatedApplication(
        name: Manifest.localized(app["name"], fallback: L10n.text("所需 App")),
        identifiers: identifiers, link: link)
    }
  }
}

public struct MissingApplicationsError: LocalizedError {
  public var applications: [AssociatedApplication]
  public init(applications: [AssociatedApplication]) { self.applications = applications }
  public var errorDescription: String? {
    L10n.text("未找到「") + applications.map(\.name).joined(separator: "」、「")
      + L10n.text("」。請安裝後再執行此動作。")
  }
}

public struct ActionFailure: Equatable, Sendable {
  public var title: String
  public var message: String
  public var instanceID: String?
  public var missingApplications: [AssociatedApplication]
  public init(
    title: String, message: String, instanceID: String? = nil,
    missingApplications: [AssociatedApplication] = []
  ) {
    self.title = String(title.prefix(200))
    self.message = String(message.prefix(32 * 1024))
    self.instanceID = instanceID
    self.missingApplications = missingApplications
  }
}
