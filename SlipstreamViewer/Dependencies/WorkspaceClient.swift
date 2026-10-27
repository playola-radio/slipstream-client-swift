import AppKit
import Darwin
import Dependencies
import Foundation

struct WorkspaceOutcome: Equatable, Sendable {
  var workspacePath: String?
  var failureText: String?
}

/// Runs `slipstream workspace create|archive`, which makes, sets up, records and archives
/// git worktree workspaces under `~/slipstream/workspaces`.
struct WorkspaceClient: Sendable {
  var roots: @Sendable () async -> WorkspaceRoots
  var chooseRepository: @MainActor @Sendable () async -> URL?
  var create: @Sendable (_ repository: URL, _ store: String) async -> WorkspaceOutcome
  var archive: @Sendable (_ workspace: URL, _ store: String) async -> WorkspaceOutcome
}

extension WorkspaceClient {
  static let pathPrefix = "workspace_path: "
  static let failureLineLimit = 12

  /// Follows `$HOME` the way the `slipstream` CLI it launches does.
  static func managedRoot(environment: [String: String]) -> URL {
    URL(filePath: environment["HOME"] ?? NSHomeDirectory())
      .appending(path: "slipstream/workspaces").resolvingSymlinksInPath()
  }

  static func outcome(output: String, status: Int32) -> WorkspaceOutcome {
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    let path = lines.last { $0.hasPrefix(pathPrefix) }.map { String($0.dropFirst(pathPrefix.count)) }
    guard status != 0 else { return WorkspaceOutcome(workspacePath: path, failureText: nil) }
    let tail = lines
      .filter { !$0.hasPrefix(pathPrefix) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .suffix(failureLineLimit)
    return WorkspaceOutcome(
      workspacePath: path,
      failureText: tail.isEmpty ? "slipstream exited with status \(status)." : tail.joined(separator: "\n")
    )
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
      chooseRepository: {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a git repository for the new workspace"
        panel.prompt = "Create Workspace"
        return panel.runModal() == .OK ? panel.url : nil
      },
      create: { repository, store in await runSlipstream(["workspace", "create", repository.path, "--store", store]) },
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
      chooseRepository: unimplemented("WorkspaceClient.chooseRepository", placeholder: nil),
      create: unimplemented("WorkspaceClient.create", placeholder: WorkspaceOutcome()),
      archive: unimplemented("WorkspaceClient.archive", placeholder: WorkspaceOutcome())
    )
  }

  private static let outputLimit = 65_536

  private static func runSlipstream(_ arguments: [String]) async -> WorkspaceOutcome {
    let variables: [String: String]
    do {
      variables = try await AgentEnvironmentClient.loginEnvironment()
    } catch {
      return WorkspaceOutcome(failureText: error.localizedDescription)
    }
    guard let slipstream = slipstreamExecutable(in: variables) else {
      return WorkspaceOutcome(failureText: slipstreamNotFoundText)
    }
    do {
      let (output, status) = try await runInBackground(slipstream, arguments, environment: variables)
      return outcome(output: output, status: status)
    } catch {
      return WorkspaceOutcome(failureText: "Couldn't run slipstream: \(error.localizedDescription)")
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
