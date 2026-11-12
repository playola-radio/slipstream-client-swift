import Foundation

/// What a read-only copy of a chat needs from the user's Claude Code settings to reach the API.
/// `--restricted` ignores settings files, so this keeps only API credentials and helper settings.
/// Hooks, plugins and permissions stay out.
public struct ForkCredentials: Equatable, Sendable {
  public var environment: [String: String]
  /// JSON for `--settings`; `nil` when the user has no credential settings.
  public var settings: String?

  public static let none = Self(environment: [:], settings: nil)
  static let helperKeys = ["apiKeyHelper", "awsAuthRefresh", "awsCredentialExport", "gcpAuthRefresh"]
  static let launchVariableKeys: Set<String> = ["PATH", "HOME", "CLAUDE_CONFIG_DIR"]

  public init(environment: [String: String], settings: String?) {
    self.environment = environment
    self.settings = settings
  }

  public init(userSettings data: Data) throws(ForkCredentialsError) {
    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
      throw ForkCredentialsError(reason: "it isn't a JSON object")
    }
    var environment: [String: String] = [:]
    var settingsEnvironment: [String: JSONValue] = [:]
    if let env = object["env"] {
      guard case .object(let variables) = env else { throw ForkCredentialsError(reason: "its env isn't an object") }
      for (name, value) in variables {
        guard case .string(let text) = value else {
          throw ForkCredentialsError(reason: "its env value for \(name) isn't text")
        }
        if Self.launchVariableKeys.contains(name) {
          settingsEnvironment[name] = .string(text)
        } else {
          environment[name] = text
        }
      }
    }
    var settings: [String: JSONValue] = [:]
    for key in Self.helperKeys {
      guard let value = object[key] else { continue }
      guard case .string(let command) = value else { throw ForkCredentialsError(reason: "its \(key) isn't text") }
      settings[key] = .string(command)
    }
    if !settingsEnvironment.isEmpty {
      settings["env"] = .object(settingsEnvironment)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.environment = environment
    self.settings = settings.isEmpty ? nil : (try? encoder.encode(settings)).map { String(decoding: $0, as: UTF8.self) }
  }
}

public struct ForkCredentialsError: Error, Equatable, Sendable {
  public let reason: String

  public init(reason: String) {
    self.reason = reason
  }
}
