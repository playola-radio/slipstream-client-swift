import AppKit
import Darwin
import Dependencies
import Foundation

/// Runs `slipstream workspace archive`, which archives git worktree workspaces under
/// `~/slipstream/workspaces`. Creating one runs in a Setup terminal tab instead.
struct WorkspaceClient: Sendable {
  var roots: @Sendable () async -> WorkspaceRoots
  var chooseFolder: @MainActor @Sendable (_ message: String, _ prompt: String) async -> URL?
  /// Returns why the command failed, or nil once the workspace is archived.
  var archive: @Sendable (_ workspace: URL, _ store: String) async -> String?
}

extension WorkspaceClient {
  static let failureLineLimit = 12

  /// Follows `$HOME` the way the `slipstream` CLI it launches does.
  static func managedRoot(environment: [String: String]) -> URL {
    URL(filePath: environment["HOME"] ?? NSHomeDirectory())
      .appending(path: "slipstream/workspaces").resolvingSymlinksInPath()
  }

  static func failureText(output: String, status: Int32) -> String? {
    guard status != 0 else { return nil }
    let tail = output.split(whereSeparator: \.isNewline)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .suffix(failureLineLimit)
    return tail.isEmpty ? "slipstream exited with status \(status)." : tail.joined(separator: "\n")
  }
}

extension WorkspaceClient: DependencyKey {
  static var liveValue: Self {
    Self(
      roots: {
        let environment = (try? await AgentEnvironmentClient.loginEnvironment()) ?? ProcessInfo.processInfo.environment
        return WorkspaceRoots(
          managed: managedRoot(environment: environment),
          conductor: URL(filePath: environment["HOME"] ?? NSHomeDirectory()).appending(path: "conductor/workspaces")
        )
      },
      chooseFolder: { message, prompt in
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
      },
      archive: { workspace, store in await runSlipstream(["workspace", "archive", workspace.path, "--store", store]) }
    )
  }

  static var testValue: Self {
    Self(
      roots: {
        WorkspaceRoots(
          managed: URL(filePath: "/tmp/slipstream-test/workspaces"),
          conductor: URL(filePath: "/tmp/conductor-test/workspaces"))
      },
      chooseFolder: unimplemented("WorkspaceClient.chooseFolder", placeholder: nil),
      archive: unimplemented("WorkspaceClient.archive", placeholder: nil)
    )
  }

  private static let outputLimit = 65_536

  private static func runSlipstream(_ arguments: [String]) async -> String? {
    let variables: [String: String]
    do {
      variables = try await AgentEnvironmentClient.loginEnvironment()
    } catch {
      return error.localizedDescription
    }
    guard let slipstream = slipstreamExecutable(in: variables) else { return slipstreamNotFoundText }
    do {
      let (output, status) = try await runInBackground(slipstream, arguments, environment: variables)
      return failureText(output: output, status: status)
    } catch {
      return "Couldn't run slipstream: \(error.localizedDescription)"
    }
  }

  static let slipstreamNotFoundText = "Couldn't find slipstream. Install it with `npm i -g @playola-radio/slipstream`."

  static func slipstreamExecutable(in variables: [String: String]) -> String? {
    (variables["PATH"] ?? "").split(separator: ":").map { "\($0)/slipstream" }
      .first(where: FileManager.default.isExecutableFile(atPath:))
  }

  static func runInBackground(
    _ executable: String, _ arguments: [String], environment: [String: String]
  ) async throws -> (output: String, status: Int32) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result { try run(executable, arguments, environment: environment) })
      }
    }
  }

  /// Runs a command to completion with stdout and stderr merged, keeping the last
  /// `outputLimit` bytes. Stops reading once it has exited and its output is drained, so a
  /// background job started by a setup script can't hold the pipe open.
  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String]
  ) throws -> (output: String, status: Int32) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    defer { try? pipe.fileHandleForReading.close() }

    let descriptor = pipe.fileHandleForReading.fileDescriptor
    var output = Data()
    var outputAfterExit = 0
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
      let hasExited = !process.isRunning
      var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&request, 1, hasExited ? 0 : 100)
      if ready > 0 {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        output.append(contentsOf: buffer[..<count])
        if output.count > outputLimit { output.removeFirst(output.count - outputLimit) }
        if hasExited {
          outputAfterExit += count
          if outputAfterExit >= outputLimit { break }
        }
      } else if ready == 0 && hasExited {
        break
      }
    }
    process.waitUntilExit()
    return (String(decoding: output, as: UTF8.self), process.terminationStatus)
  }
}

extension DependencyValues {
  var workspace: WorkspaceClient {
    get { self[WorkspaceClient.self] }
    set { self[WorkspaceClient.self] = newValue }
  }
}
