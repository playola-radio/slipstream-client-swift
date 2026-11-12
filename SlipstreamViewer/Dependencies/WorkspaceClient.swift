import AppKit
import Darwin
import Dependencies
import Foundation

/// Runs `slipstream workspace archive`, which archives git worktree workspaces under
/// `~/slipstream/workspaces`. Creating one runs in a Setup terminal tab instead.
struct WorkspaceClient: Sendable {
  var roots: @Sendable () async -> WorkspaceRoots
  var chooseFolder: @MainActor @Sendable (_ message: String, _ prompt: String) async -> URL?
  var nextFolder: @Sendable (_ repository: String, _ managedRoot: String) -> String
  /// Returns why the command failed, or nil once the workspace is archived.
  var archive: @Sendable (_ workspace: URL, _ store: String) async -> String?
  /// The main checkout of the git repository holding `folder`, or nil when it isn't in one.
  var repository: @Sendable (_ folder: URL) async -> URL?
}

extension WorkspaceClient {
  static let failureLineLimit = 12

  /// Follows `$HOME` the way the `slipstream` CLI it launches does.
  static func managedRoot(environment: [String: String]) -> URL {
    URL(filePath: environment["HOME"] ?? NSHomeDirectory())
      .appending(path: "slipstream/workspaces").resolvingSymlinksInPath()
  }

  /// The first `workspace-N` folder that doesn't exist yet, as `slipstream workspace create`
  /// picks it. The daemon also skips a leftover branch, so this is only a guess.
  static func nextFolder(repository: String, managedRoot: String, exists: (String) -> Bool) -> String {
    let parent = URL(filePath: managedRoot).appending(path: repository)
    var number = 1
    while exists(parent.appending(path: "workspace-\(number)").path) { number += 1 }
    return parent.appending(path: "workspace-\(number)").path
  }

  /// Resolves a worktree to its main checkout the way `slipstream workspace create` does.
  static func repository(of folder: URL) async -> URL? {
    let arguments = [
      "-C", folder.path, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir",
    ]
    guard
      let (output, status) = try? await runInBackground(
        "/usr/bin/git", arguments, environment: ProcessInfo.processInfo.environment),
      status == 0
    else { return nil }
    let lines = output.split(whereSeparator: \.isNewline).map(String.init)
    guard lines.count == 3 else { return nil }
    let (top, gitDir, commonDir) = (lines[0], lines[1], lines[2])
    return gitDir == commonDir ? URL(filePath: top) : URL(filePath: commonDir).deletingLastPathComponent()
  }

  static func failureText(output: String, status: Int32) -> String? {
    guard status != 0 else { return nil }
    let tail = output.split(whereSeparator: \.isNewline)
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      .suffix(failureLineLimit)
    return (tail + ["slipstream exited with status \(status)."]).joined(separator: "\n")
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
      nextFolder: { repository, managedRoot in
        nextFolder(repository: repository, managedRoot: managedRoot, exists: FileManager.default.fileExists(atPath:))
      },
      archive: { workspace, store in
        let environment: [String: String]
        let shim: String
        do {
          environment = try await AgentEnvironmentClient.loginEnvironment()
          shim = try RuntimeInstallClient.installedShim()
        } catch {
          return error.localizedDescription
        }
        return await runShim(
          shim, ["workspace", "archive", workspace.path, "--store", store], environment: environment)
      },
      repository: { await repository(of: $0) }
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
      nextFolder: { repository, managedRoot in nextFolder(repository: repository, managedRoot: managedRoot) { _ in false } },
      archive: unimplemented("WorkspaceClient.archive", placeholder: nil),
      repository: unimplemented("WorkspaceClient.repository", placeholder: nil)
    )
  }

  private static let outputLimit = 65_536

  static func runShim(_ shim: String, _ arguments: [String], environment: [String: String]) async -> String? {
    do {
      let (output, status) = try await runInBackground(shim, arguments, environment: environment)
      return failureText(output: output, status: status)
    } catch {
      return "Couldn't run \(shim): \(error.localizedDescription)"
    }
  }

  static func runInBackground(
    _ executable: String, _ arguments: [String], environment: [String: String], keepsAllOutput: Bool = false
  ) async throws -> (output: String, status: Int32) {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(
          with: Result { try run(executable, arguments, environment: environment, keepsAllOutput: keepsAllOutput) })
      }
    }
  }

  /// Runs a command to completion with stdout and stderr merged, keeping the last
  /// `outputLimit` bytes unless `keepsAllOutput`. Stops reading once it has exited and its output is drained, so a
  /// background job started by a setup script can't hold the pipe open.
  static func run(
    _ executable: String, _ arguments: [String], environment: [String: String], keepsAllOutput: Bool = false
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
        if !keepsAllOutput, output.count > outputLimit { output.removeFirst(output.count - outputLimit) }
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
