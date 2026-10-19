import Darwin
import Dependencies
import Foundation

struct AgentEnvironment: Equatable, Sendable {
  var claudePath: String
  var variables: [String: String]
  var configDirectory: URL
}

enum AgentEnvironmentError: Error, Equatable {
  case shellTimedOut
  case claudeNotFound
  case tooOld(found: String)
  case unreadableVersion
}

extension AgentEnvironmentError {
  var message: String {
    switch self {
    case .shellTimedOut:
      "Your login shell took longer than 10 seconds to start"
    case .claudeNotFound:
      "Couldn't find claude on your login shell's PATH"
    case .tooOld(let found):
      "Slipstream needs Claude Code \(AgentEnvironmentClient.minimumVersion) or newer (found \(found))"
    case .unreadableVersion:
      "Couldn't read the version of claude on your login shell's PATH"
    }
  }
}

struct AgentEnvironmentClient: Sendable {
  var resolve: @Sendable () async throws -> AgentEnvironment
}

extension AgentEnvironmentClient {
  static let minimumVersion = "2.1.293"

  static func parseEnvironment(_ output: Data, marker: String) -> [String: String] {
    let fields = output.split(separator: 0, omittingEmptySubsequences: false)
    guard let markerIndex = fields.firstIndex(of: Data(marker.utf8)) else { return [:] }
    var variables: [String: String] = [:]
    for field in fields[(markerIndex + 1)...] {
      let entry = String(decoding: field, as: UTF8.self)
      guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
      variables[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return variables
  }

  static func isSupported(version: String) -> Bool {
    guard let found = versionComponents(version), let minimum = versionComponents(minimumVersion)
    else { return false }
    return !found.lexicographicallyPrecedes(minimum)
  }

  static func configDirectory(_ variables: [String: String], home: URL) -> URL {
    if let directory = variables["CLAUDE_CONFIG_DIR"], !directory.isEmpty {
      return URL(fileURLWithPath: directory)
    }
    return home.appending(path: ".claude")
  }

  static func loginShell(environment: [String: String], passwordDatabaseShell: String?) -> String {
    if let shell = environment["SHELL"], !shell.isEmpty { return shell }
    if let passwordDatabaseShell, !passwordDatabaseShell.isEmpty { return passwordDatabaseShell }
    return "/bin/zsh"
  }

  private static func passwordDatabaseShell() -> String? {
    guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
    return String(cString: shell)
  }

  private static func versionComponents(_ version: String) -> [Int]? {
    guard let token = version.split(separator: " ").first else { return nil }
    let components = token.split(separator: ".").map { Int($0) }
    guard components.count == 3, components.allSatisfy({ $0 != nil }) else { return nil }
    return components.compactMap(\.self)
  }
}

actor AgentEnvironmentCache {
  private let load: @Sendable () async throws -> AgentEnvironment
  private var current: Task<AgentEnvironment, any Error>?

  init(load: @escaping @Sendable () async throws -> AgentEnvironment) {
    self.load = load
  }

  func resolve() async throws -> AgentEnvironment {
    let task = current ?? Task { try await load() }
    current = task
    do {
      return try await task.value
    } catch {
      if current == task { current = nil }
      throw error
    }
  }
}

extension AgentEnvironmentClient: DependencyKey {
  static var liveValue: Self {
    let cache = AgentEnvironmentCache(load: loadFromLoginShell)
    return Self(resolve: { try await cache.resolve() })
  }

  static var testValue: Self {
    Self(resolve: unimplemented("AgentEnvironmentClient.resolve"))
  }

  private static let timeout: TimeInterval = 10

  @Sendable private static func loadFromLoginShell() async throws -> AgentEnvironment {
    let shell = loginShell(
      environment: ProcessInfo.processInfo.environment,
      passwordDatabaseShell: passwordDatabaseShell()
    )
    let marker = "SLIPSTREAM-ENV-\(UUID().uuidString)"
    guard
      let output = try await captureOutput(
        shell, ["-ilc", "printf '\\0\(marker)\\0'; env -0"], environment: nil)
    else { throw AgentEnvironmentError.shellTimedOut }
    let variables = parseEnvironment(output, marker: marker)

    let directories = (variables["PATH"] ?? "").split(separator: ":")
    guard
      let claudePath = directories.map({ "\($0)/claude" })
        .first(where: FileManager.default.isExecutableFile(atPath:))
    else { throw AgentEnvironmentError.claudeNotFound }

    guard
      let versionOutput = try await captureOutput(claudePath, ["--version"], environment: variables),
      let version = String(decoding: versionOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init),
      versionComponents(version) != nil
    else { throw AgentEnvironmentError.unreadableVersion }
    guard isSupported(version: version) else { throw AgentEnvironmentError.tooOld(found: version) }

    return AgentEnvironment(
      claudePath: claudePath,
      variables: variables,
      configDirectory: configDirectory(variables, home: FileManager.default.homeDirectoryForCurrentUser)
    )
  }

  /// Runs a command and returns its stdout, or nil if it doesn't finish within the timeout.
  /// Stops reading once the command has exited and its output is drained, so a background
  /// job started by the user's shell profile can't hold the pipe open.
  static func captureOutput(
    _ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval = timeout
  ) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(
          with: Result { try captureOutputBlocking(executable, arguments, environment: environment, timeout: timeout) })
      }
    }
  }

  private static func captureOutputBlocking(
    _ executable: String, _ arguments: [String], environment: [String: String]?, timeout: TimeInterval
  ) throws -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    process.standardInput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    try process.run()
    defer { try? pipe.fileHandleForReading.close() }

    let descriptor = pipe.fileHandleForReading.fileDescriptor
    let deadline = Date.now.addingTimeInterval(timeout)
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while Date.now < deadline {
      let hasExited = !process.isRunning
      var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let ready = poll(&request, 1, hasExited ? 0 : 100)
      if ready > 0 {
        let count = read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { break }
        output.append(contentsOf: buffer[..<count])
      } else if ready == 0 && hasExited {
        return output
      }
    }
    while process.isRunning && Date.now < deadline { usleep(10_000) }
    if !process.isRunning { return output }
    // An interactive shell ignores SIGTERM.
    kill(process.processIdentifier, SIGKILL)
    process.waitUntilExit()
    return nil
  }
}

extension DependencyValues {
  var agentEnvironment: AgentEnvironmentClient {
    get { self[AgentEnvironmentClient.self] }
    set { self[AgentEnvironmentClient.self] = newValue }
  }
}
