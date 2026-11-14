import Foundation

/// Sealed into the candidate bundle by release_pipeline.py, not generated Swift.
public struct BuildIdentity: Codable, Equatable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let buildID: String
    public let sourceRevision: String
    public let contentRevision: String

    public init(appVersion: String, buildNumber: String, buildID: String,
                sourceRevision: String, contentRevision: String) {
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.buildID = buildID
        self.sourceRevision = sourceRevision
        self.contentRevision = contentRevision
    }

    public static var current: BuildIdentity {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("build-identity.json"),
              let identity = try? load(from: url) else { return .development }
        return identity
    }

    public static func load(from url: URL) throws -> BuildIdentity {
        try JSONDecoder().decode(BuildIdentity.self, from: Data(contentsOf: url))
    }

    public static let development = BuildIdentity(appVersion: "development", buildNumber: "development",
        buildID: "development", sourceRevision: "development", contentRevision: "development")
}
