import Foundation

/// What a read-only copy of a chat needs from the user's Claude Code settings to reach the API.
/// `--restricted` ignores settings files, so the `env` block goes into the copy's environment and
/// the credential helpers go in with `--settings`. Hooks, plugins and permissions stay out.
public struct ForkCredentials: Equatable, Sendable {
  public var environment: [String: String]
  /// JSON for `--settings`; `nil` when the user has no credential helpers.
  public var settings: String?

  public static let none = Self(environment: [:], settings: nil)
  static let helperKeys = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "gcpAuthRefresh"]

  public init(environment: [String: String], settings: String?) {
    self.environment = environment
    self.settings = settings
  }

  public init(userSettings data: Data) throws(ForkCredentialsError) {
    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw ForkCredentialsError(reason: "it isn't a JSON object")
    }
    var environment: [String: String] = [:]
    if let env = object["env"] {
      guard case .object(let variables) = env else { throw ForkCredentialsError(reason: "its env isn't an object") }
      for (name, value) in variables {
        guard case .string(let text) = value else {
          throw ForkCredentialsError(reason: "its env value for \(name) isn't text")
        }
        environment[name] = text
      }
    }
    var helpers: [String: String] = [:]
    for key in Self.helperKeys {
      guard let value = object[key] else { continue }
      guard case .string(let command) = value else { throw ForkCredentialsError(reason: "its \(key) isn't text") }
      helpers[key] = command
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.environment = environment
    settings = helpers.isEmpty ? nil : (try? encoder.encode(helpers)).map { String(decoding: $0, as: UTF8.self) }
  }
}

public struct ForkCredentialsError: Error, Equatable, Sendable {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }
}
