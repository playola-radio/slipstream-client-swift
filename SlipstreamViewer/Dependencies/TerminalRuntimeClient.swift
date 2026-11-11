import Dependencies
import Foundation
import SlipstreamCore

struct TerminalSize: Equatable, Sendable {
  var columns: Int
  var rows: Int
}

struct TerminalEnvironment: Equatable, Sendable {
  var variables: [String: String]
  var shell: String
  var slipstream: String
}

struct TerminalLaunch: Equatable, Sendable {
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var directory: String
  var size: TerminalSize
}

enum TerminalEvent: Equatable, Sendable {
  case output([UInt8])
  case finished(TerminalExit)
}

struct TerminalLaunchError: Error, Equatable {
  var text: String
}

struct TerminalProcessHandle: Sendable {
  var events: AsyncStream<TerminalEvent>
  var write: @Sendable ([UInt8]) -> Void
  var resize: @Sendable (TerminalSize) -> Void
  var isBusy: @Sendable () -> Bool
  var stop: @Sendable () async -> Void
}

/// Runs shells and commands in pseudo-terminals the app owns.
struct TerminalRuntimeClient: Sendable {
  var environment: @Sendable () async throws -> TerminalEnvironment
  var folderExists: @Sendable (String) -> Bool
  var launch: @Sendable (TerminalLaunch) throws -> TerminalProcessHandle
}

extension TerminalRuntimeClient {
  static func terminalEnvironment(
    login: [String: String], passwordDatabaseShell: String?, slipstream: String
  ) throws -> TerminalEnvironment {
    guard let path = login["PATH"], !path.isEmpty else {
      throw TerminalLaunchError(text: "Couldn't read PATH from your login shell")
    }
    var variables = login
    variables["TERM"] = "xterm-256color"
    variables["COLORTERM"] = "truecolor"
    if ["LANG", "LC_ALL", "LC_CTYPE"].allSatisfy({ login[$0]?.isEmpty ?? true }) {
      variables["LANG"] = "en_US.UTF-8"
    }
    return TerminalEnvironment(
      variables: variables,
      shell: AgentEnvironmentClient.loginShell(environment: login, passwordDatabaseShell: passwordDatabaseShell),
      slipstream: slipstream
    )
  }
}

extension TerminalRuntimeClient: DependencyKey {
  static var liveValue: Self {
    Self(
      environment: {
        let login: [String: String]
        do {
          login = try await AgentEnvironmentClient.loginEnvironment()
        } catch let error as AgentEnvironmentError {
          throw TerminalLaunchError(text: error.message)
        }
        return try terminalEnvironment(
          login: login, passwordDatabaseShell: AgentEnvironmentClient.passwordDatabaseShell(),
          slipstream: RuntimeInstallClient.shim.path)
      },
      folderExists: { path in
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
      },
      launch: { launch in
        let process = try TerminalProcess(launch)
        return TerminalProcessHandle(
          events: process.events,
          write: { process.write($0) },
          resize: { process.resize($0) },
          isBusy: { process.isBusy() },
          stop: { await process.stop() }
        )
      }
    )
  }

  static var testValue: Self {
    Self(
      environment: unimplemented("TerminalRuntimeClient.environment"),
      folderExists: unimplemented("TerminalRuntimeClient.folderExists", placeholder: false),
      launch: unimplemented("TerminalRuntimeClient.launch")
    )
  }
}

extension DependencyValues {
  var terminalRuntime: TerminalRuntimeClient {
    get { self[TerminalRuntimeClient.self] }
    set { self[TerminalRuntimeClient.self] = newValue }
  }
}
