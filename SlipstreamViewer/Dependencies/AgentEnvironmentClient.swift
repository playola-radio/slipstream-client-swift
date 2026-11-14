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

  static func passwordDatabaseShell() -> String? {
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

actor AgentEnvironmentCache<Value: Sendable> {
  private let load: @Sendable () async throws -> Value
  private var current: Task<Value, any Error>?

  init(load: @escaping @Sendable () async throws -> Value) {
    self.load = load
  }

  func resolve() async throws -> Value {
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

/// Keeps the last login environment that loaded. Callers get it immediately while one shell
/// refreshes it in the background, so profile edits show up a call or two later. Until a load
/// succeeds, callers share the one in flight; a failure is never kept.
actor LoginEnvironmentCache {
  private let load: @Sendable () async throws -> [String: String]
  private var value: [String: String]?
  private var loading: Task<[String: String], any Error>?

  init(load: @escaping @Sendable () async throws -> [String: String]) {
    self.load = load
  }

  func resolve() async throws -> [String: String] {
    if let value {
      if loading == nil { refreshInBackground() }
      return value
    }
    let task = loading ?? startLoading()
    let result = await task.result
    finished(task, result)
    return try result.get()
  }

  private func startLoading() -> Task<[String: String], any Error> {
    let task = Task { try await load() }
    loading = task
    return task
  }

  private func refreshInBackground() {
    let task = startLoading()
    Task { finished(task, await task.result) }
  }

  private func finished(_ task: Task<[String: String], any Error>, _ result: Result<[String: String], any Error>) {
    guard loading == task else { return }
    loading = nil
    if case .success(let loaded) = result { value = loaded }
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
    let variables = try await loginEnvironment()

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

  /// The environment of the user's login shell. Starting the shell takes about a second, so this
  /// answers from a cache that refreshes itself in the background.
  static func loginEnvironment() async throws -> [String: String] {
    try await loginEnvironmentCache.resolve()
  }

  private static let loginEnvironmentCache = LoginEnvironmentCache(load: loadLoginEnvironment)

  @Sendable private static func loadLoginEnvironment() async throws -> [String: String] {
    let shell = loginShell(
      environment: ProcessInfo.processInfo.environment,
      passwordDatabaseShell: passwordDatabaseShell()
    )
    let marker = "SLIPSTREAM-ENV-\(UUID().uuidString)"
    guard
      let output = try await captureOutput(
        shell, ["-ilc", "printf '\\0\(marker)\\0'; env -0"], environment: nil)
    else { throw AgentEnvironmentError.shellTimedOut }
    return parseEnvironment(output, marker: marker)
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
          with: Result {
            let capture = try runBlocking(
              executable, arguments, environment: environment, directory: nil, capturesStandardError: false,
              timeout: timeout)
            return capture.didTimeOut ? nil : capture.standardOutput
          })
      }
    }
  }

  struct ProcessCapture {
    var standardOutput = Data()
    var standardError = Data()
    var status: Int32 = 0
    var didTimeOut = false
  }

  /// Drains stdout, and stderr when asked, while the command runs, so a command that fills a pipe
  /// can't block. Kills it at the deadline and returns what it had printed.
  static func runBlocking(
    _ executable: String, _ arguments: [String], environment: [String: String]?, directory: URL?,
    capturesStandardError: Bool, timeout: TimeInterval
  ) throws -> ProcessCapture {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment { process.environment = environment }
    if let directory { process.currentDirectoryURL = directory }
    process.standardInput = FileHandle.nullDevice
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = capturesStandardError ? errorPipe : FileHandle.nullDevice
    try process.run()
    defer {
      try? outputPipe.fileHandleForReading.close()
      if capturesStandardError { try? errorPipe.fileHandleForReading.close() }
    }

    var capture = ProcessCapture()
    var streams = [Stream(descriptor: outputPipe.fileHandleForReading.fileDescriptor, isStandardError: false)]
    if capturesStandardError {
      streams.append(Stream(descriptor: errorPipe.fileHandleForReading.fileDescriptor, isStandardError: true))
    }
    let deadline = Date.now.addingTimeInterval(timeout)
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while !streams.isEmpty && Date.now < deadline {
      let hasExited = !process.isRunning
      var requests = streams.map { pollfd(fd: $0.descriptor, events: Int16(POLLIN), revents: 0) }
      let ready = poll(&requests, nfds_t(requests.count), hasExited ? 0 : 100)
      if ready == 0 && hasExited {
        capture.status = process.terminationStatus
        return capture
      }
      guard ready > 0 else { continue }
      var open: [Stream] = []
      for (stream, request) in zip(streams, requests) {
        guard request.revents != 0 else {
          open.append(stream)
          continue
        }
        let count = read(stream.descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR {
          open.append(stream)
        } else if count > 0 {
          if stream.isStandardError {
            capture.standardError.append(contentsOf: buffer[..<count])
          } else {
            capture.standardOutput.append(contentsOf: buffer[..<count])
          }
          open.append(stream)
        }
      }
      streams = open
    }
    while process.isRunning && Date.now < deadline { usleep(10_000) }
    if !process.isRunning {
      capture.status = process.terminationStatus
      return capture
    }
    // An interactive shell ignores SIGTERM. The command leads its own process group, so killing
    // the group also stops anything it started.
    let pid = process.processIdentifier
    if kill(-pid, SIGKILL) != 0 { kill(pid, SIGKILL) }
    process.waitUntilExit()
    capture.didTimeOut = true
    return capture
  }

  private struct Stream {
    var descriptor: Int32
    var isStandardError: Bool
  }
}

extension DependencyValues {
  var agentEnvironment: AgentEnvironmentClient {
    get { self[AgentEnvironmentClient.self] }
    set { self[AgentEnvironmentClient.self] = newValue }
  }
}
