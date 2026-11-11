import CryptoKit
import Darwin
import Foundation

public struct RuntimeIdentity: Equatable, Sendable {
  public let version: String
  public let build: String

  public init(version: String, build: String) {
    self.version = version
    self.build = build
  }

  var directoryName: String { "\(version)-\(build.prefix(8))" }
}

public struct PreparedRuntime: Equatable, Sendable {
  public let identity: RuntimeIdentity
  public let directory: URL

  public init(identity: RuntimeIdentity, directory: URL) {
    self.identity = identity
    self.directory = directory
  }
}

public enum Activation: Equatable, Sendable {
  case activated
  case newerActive(RuntimeIdentity)
}

public struct LinkProblem: Equatable, Sendable {
  public let path: String
  public let message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

public enum RuntimeInstallError: Error, Equatable, Sendable {
  case io(step: String, path: String, errno: Int32, message: String)
  /// `expected` describes the bundle and `actual` the copy: a sha256, a mode, `absent` or `present`.
  case differs(path: String, expected: String, actual: String)
}

/// Copies the runtime embedded in the app bundle to a versioned directory under `root`, checks the
/// copy against the bundle, and points `current` and the `slipstream` shims at it.
public struct RuntimeInstall: Sendable {
  public let root: URL
  public let bundled: URL
  public let commandsDirectory: URL
  let afterCopy: @Sendable (URL) -> Void

  /// Creates an installer for the bundled payload and the runtime and command locations it owns.
  public init(
    root: URL,
    bundled: URL,
    commandsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".local/bin", isDirectory: true)
  ) {
    self.init(root: root, bundled: bundled, commandsDirectory: commandsDirectory, afterCopy: { _ in })
  }

  /// Creates an installer with a post-copy hook used to exercise verification failures in tests.
  init(root: URL, bundled: URL, commandsDirectory: URL, afterCopy: @escaping @Sendable (URL) -> Void) {
    self.root = root
    self.bundled = bundled
    self.commandsDirectory = commandsDirectory
    self.afterCopy = afterCopy
  }

  /// Reads the daemon version and build identifier from the embedded runtime payload.
  public func bundledIdentity() throws(RuntimeInstallError) -> RuntimeIdentity {
    try Self.identity(of: bundled.path)
  }

  /// Verifies and installs the embedded runtime into its immutable versioned directory.
  public func prepare() throws(RuntimeInstallError) -> PreparedRuntime {
    try withLock { () throws(RuntimeInstallError) -> PreparedRuntime in
      let identity = try bundledIdentity()
      // Under the lock, any staging dir left here belongs to a run that died before cleaning up.
      for name in try Self.children(of: root.path) where name.hasPrefix(".staging-") {
        Self.removeTree("\(root.path)/\(name)")
      }
      let directory = root.appendingPathComponent(identity.directoryName, isDirectory: true)
      let prepared = PreparedRuntime(identity: identity, directory: directory)
      // The versioned directory only ever appears through the rename below, after the comparison.
      if access(directory.path, F_OK) == 0 { return prepared }

      let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
      guard mkdir(staging.path, 0o700) == 0 else { throw .posix(step: "create staging", path: staging.path) }
      do throws(RuntimeInstallError) {
        try Self.copyTree(from: bundled.path, to: staging.path)
        afterCopy(staging)
        try Self.compareTree(bundled.path, staging.path)
        guard rename(staging.path, directory.path) == 0 else {
          throw .posix(step: "rename staging", path: directory.path)
        }
      } catch {
        Self.removeTree(staging.path)
        throw error
      }
      return prepared
    }
  }

  /// Points `current` and the stable shims at a prepared runtime unless a newer version is active.
  public func activate(_ runtime: PreparedRuntime) throws(RuntimeInstallError) -> Activation {
    try withLock { () throws(RuntimeInstallError) -> Activation in
      if let active = try currentIdentity(), Self.isVersion(active.version, newerThan: runtime.identity.version) {
        return .newerActive(active)
      }
      // The shims only go through `current`, so writing them first leaves `current` alone if they fail.
      try writeShims()
      let current = root.appendingPathComponent("current").path
      let temporary = root.appendingPathComponent("current.tmp-\(UUID().uuidString)").path
      guard symlink(runtime.directory.lastPathComponent, temporary) == 0 else {
        throw .posix(step: "link current", path: temporary)
      }
      guard rename(temporary, current) == 0 else {
        let error = RuntimeInstallError.posix(step: "replace current", path: current)
        unlink(temporary)
        throw error
      }
      return .activated
    }
  }

  /// Links `slipstream` and `slipstream-mcp` in `commandsDirectory` to the shims. Problems are
  /// returned, never thrown, so a link failure never fails an update.
  public func linkCommands() -> [LinkProblem] {
    do {
      try Self.makeDirectories(commandsDirectory.path)
    } catch {
      return [LinkProblem(path: commandsDirectory.path, message: error.description)]
    }
    var problems: [LinkProblem] = []
    for name in Self.shimScripts.keys.sorted() {
      let link = commandsDirectory.appendingPathComponent(name).path
      let target = root.appendingPathComponent("bin/\(name)").path
      if Self.mode(of: link) != nil {
        if Self.symlinkDestination(link) != target {
          problems.append(
            LinkProblem(path: link, message: "\(link) already exists and is not a link to \(target); left it alone."))
        }
        continue
      }
      if symlink(target, link) != 0 {
        problems.append(LinkProblem(path: link, message: RuntimeInstallError.posix(step: "link", path: link).description))
      }
    }
    return problems
  }

  // MARK: - Private helpers

  static let shimScripts = ["slipstream": "cli.js", "slipstream-mcp": "mcp-forwarder.js"]

  /// Produces a shell-safe single-quoted string literal for a POSIX shell assignment.
  static func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\\\''"))'"
  }

  /// Produces a stable command shim that resolves the active runtime at execution time.
  static func shim(execing script: String, root: String) -> String {
    """
    #!/bin/sh
    root=\(shellQuoted(root))
    dir="$(cd "$root/current" 2>/dev/null && pwd -P)" || { echo "slipstream: no runtime at $root/current; open Slipstream once." >&2; exit 127; }
    SLIPSTREAM_APP_RUNTIME="$root" exec "$dir/bin/node" "$dir/app/dist/\(script)" "$@"

    """
  }

  /// Holds `flock(LOCK_EX)` on `root/.lock` for the whole of `body`; closing the descriptor releases it.
  private func withLock<T>(_ body: () throws(RuntimeInstallError) -> T) throws(RuntimeInstallError) -> T {
    try Self.makeDirectories(root.path)
    let path = root.appendingPathComponent(".lock").path
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
    guard descriptor >= 0 else { throw .posix(step: "open lock", path: path) }
    defer { close(descriptor) }
    while flock(descriptor, LOCK_EX) != 0 {
      guard errno == EINTR else { throw .posix(step: "lock", path: path) }
    }
    return try body()
  }

  /// The identity `current` points at, or nil when it points at nothing. A runtime that is there but
  /// unreadable throws, so it is never replaced by one that might be older.
  private func currentIdentity() throws(RuntimeInstallError) -> RuntimeIdentity? {
    let currentPath = root.appendingPathComponent("current").path
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let length = readlink(currentPath, &buffer, Int(PATH_MAX))
    if length < 0 {
      if errno == ENOENT { return nil }
      throw .posix(step: "read current", path: currentPath)
    }
    guard let target = String(
      bytes: buffer[0..<Int(length)].map { UInt8(bitPattern: $0) }, encoding: .utf8
    ) else {
      throw .io(step: "read current", path: currentPath, errno: 0, message: "current link target is not UTF-8")
    }
    let directory = root.appendingPathComponent(target).path
    var info = stat()
    guard lstat(directory, &info) == 0 else {
      if errno == ENOENT { return nil }
      throw .posix(step: "read current runtime", path: directory)
    }
    return try Self.identity(of: directory)
  }

  private func writeShims() throws(RuntimeInstallError) {
    let bin = root.appendingPathComponent("bin").path
    try Self.makeDirectories(bin)
    for (name, script) in Self.shimScripts.sorted(by: { $0.key < $1.key }) {
      let path = "\(bin)/\(name)"
      let temporary = "\(bin)/.\(name).tmp-\(UUID().uuidString)"
      do throws(RuntimeInstallError) {
        try Self.writeFile(Data(Self.shim(execing: script, root: root.path).utf8), to: temporary, mode: 0o755)
        guard rename(temporary, path) == 0 else { throw .posix(step: "replace shim", path: path) }
      } catch {
        unlink(temporary)
        throw error
      }
    }
  }

  /// Reads the runtime identity files without trusting a directory name or manifest.
  private static func identity(of runtime: String) throws(RuntimeInstallError) -> RuntimeIdentity {
    struct Package: Decodable { let version: String }
    let packagePath = "\(runtime)/app/package.json"
    let packageData = try readFile(packagePath)
    guard let package = try? JSONDecoder().decode(Package.self, from: packageData) else {
      throw .io(step: "read daemon version", path: packagePath, errno: 0, message: "no \"version\" string in package.json")
    }
    let buildPath = "\(runtime)/app/dist/build-id"
    let build = String(decoding: try readFile(buildPath), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !build.isEmpty else { throw .io(step: "read daemon build", path: buildPath, errno: 0, message: "build-id is empty") }
    return RuntimeIdentity(version: package.version, build: build)
  }

  /// Returns whether `lhs` has higher SemVer precedence than `rhs`, comparing numeric
  /// major/minor/patch values and then prerelease identifiers.
  static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
    func parts(_ version: String) -> (core: [Int], prerelease: String?) {
      let withoutBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
      let pieces = withoutBuild.split(separator: "-", maxSplits: 1).map(String.init)
      let core = (pieces.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
      return (core + Array(repeating: 0, count: max(0, 3 - core.count)), pieces.count > 1 ? pieces[1] : nil)
    }
    let (left, right) = (parts(lhs), parts(rhs))
    if left.core != right.core { return right.core.lexicographicallyPrecedes(left.core) }
    switch (left.prerelease, right.prerelease) {
    case (nil, nil): return false
    case (nil, _): return true
    case (_, nil): return false
    case let (left?, right?):
      let (leftIdentifiers, rightIdentifiers) = (left.split(separator: "."), right.split(separator: "."))
      for (leftIdentifier, rightIdentifier) in zip(leftIdentifiers, rightIdentifiers) where leftIdentifier != rightIdentifier {
        switch (Int(leftIdentifier), Int(rightIdentifier)) {
        case let (leftNumber?, rightNumber?): return leftNumber > rightNumber
        case (_?, nil): return false
        case (nil, _?): return true
        case (nil, nil): return leftIdentifier > rightIdentifier
        }
      }
      return leftIdentifiers.count > rightIdentifiers.count
    }
  }

  /// Copies regular files and directories with their permission bits and without extended
  /// attributes, so no quarantine flag comes along. Anything else is left for `compareTree` to reject.
  private static func copyTree(from source: String, to destination: String) throws(RuntimeInstallError) {
    for name in try children(of: source) {
      let from = "\(source)/\(name)"
      let to = "\(destination)/\(name)"
      guard let mode = mode(of: from) else { throw .posix(step: "copy", path: from) }
      switch mode & S_IFMT {
      case S_IFDIR:
        guard mkdir(to, 0o700) == 0 else { throw .posix(step: "copy", path: to) }
        try copyTree(from: from, to: to)
      case S_IFREG:
        try copyFile(from: from, to: to)
      default:
        continue
      }
      try stripQuarantine(to)
      guard chmod(to, mode & 0o7777) == 0 else { throw .posix(step: "copy", path: to) }
    }
  }

  /// Copies one regular file with no symlink traversal and flushes it before returning.
  private static func copyFile(from source: String, to destination: String) throws(RuntimeInstallError) {
    let input = open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { throw .posix(step: "copy", path: source) }
    defer { close(input) }
    let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard output >= 0 else { throw .posix(step: "copy", path: destination) }
    defer { close(output) }
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = read(input, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else { throw .posix(step: "copy", path: source) }
      var written = 0
      while written < count {
        let result = buffer.withUnsafeBytes { write(output, $0.baseAddress! + written, count - written) }
        guard result > 0 else { throw .posix(step: "copy", path: destination) }
        written += result
      }
    }
    guard fsync(output) == 0 else { throw .posix(step: "copy", path: destination) }
  }

  /// Removes Finder's quarantine extended attribute while preserving all other metadata choices.
  private static func stripQuarantine(_ path: String) throws(RuntimeInstallError) {
    guard removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) == 0 || errno == ENOATTR else {
      throw .posix(step: "strip quarantine", path: path)
    }
  }

  /// Checks two directory trees for exactly matching paths, modes, and regular-file contents.
  private static func compareTree(_ expected: String, _ actual: String) throws(RuntimeInstallError) {
    let bundle = try modes(under: expected)
    let copy = try modes(under: actual)
    for path in Set(bundle.keys).union(copy.keys).sorted() {
      guard let expectedMode = bundle[path] else { throw .differs(path: path, expected: "absent", actual: "present") }
      guard let actualMode = copy[path] else { throw .differs(path: path, expected: "present", actual: "absent") }
      guard expectedMode == actualMode else {
        throw .differs(path: path, expected: String(expectedMode, radix: 8), actual: String(actualMode, radix: 8))
      }
      if expectedMode & S_IFMT == S_IFREG {
        let expectedHash = try sha256(of: "\(expected)/\(path)")
        let actualHash = try sha256(of: "\(actual)/\(path)")
        guard expectedHash == actualHash else { throw .differs(path: path, expected: expectedHash, actual: actualHash) }
      }
    }
  }

  /// Recursively records every entry beneath `base`, keyed by its relative path and `lstat` mode.
  private static func modes(under base: String, prefix: String = "") throws(RuntimeInstallError) -> [String: mode_t] {
    var result: [String: mode_t] = [:]
    for name in try children(of: prefix.isEmpty ? base : "\(base)/\(prefix)") {
      let relative = prefix.isEmpty ? name : "\(prefix)/\(name)"
      guard let mode = mode(of: "\(base)/\(relative)") else { throw .posix(step: "compare", path: "\(base)/\(relative)") }
      result[relative] = mode
      if mode & S_IFMT == S_IFDIR {
        result.merge(try modes(under: base, prefix: relative)) { $1 }
      }
    }
    return result
  }

  /// Returns the lowercase SHA-256 digest for a regular file opened without following symlinks.
  private static func sha256(of path: String) throws(RuntimeInstallError) -> String {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw .posix(step: "compare", path: path) }
    defer { close(descriptor) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else { throw .posix(step: "compare", path: path) }
      hasher.update(data: buffer[0..<count])
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// Lists direct children in deterministic order and reports directory iteration failures.
  private static func children(of directory: String) throws(RuntimeInstallError) -> [String] {
    guard let stream = opendir(directory) else { throw .posix(step: "list", path: directory) }
    defer { closedir(stream) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let name = withUnsafeBytes(of: entry.pointee.d_name) {
        String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
      }
      if name != "." && name != ".." { names.append(name) }
    }
    guard errno == 0 else { throw .posix(step: "list", path: directory) }
    return names.sorted()
  }

  /// Reads a file through a close-on-exec descriptor and surfaces POSIX failures with context.
  private static func readFile(_ path: String) throws(RuntimeInstallError) -> Data {
    let descriptor = open(path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw .posix(step: "read", path: path) }
    defer { close(descriptor) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
      let count = read(descriptor, &buffer, buffer.count)
      if count == 0 { return data }
      guard count > 0 else { throw .posix(step: "read", path: path) }
      data.append(contentsOf: buffer[0..<count])
    }
  }

  /// Creates and writes a new file with its requested permission bits.
  private static func writeFile(_ data: Data, to path: String, mode: mode_t) throws(RuntimeInstallError) {
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw .posix(step: "write", path: path) }
    defer { close(descriptor) }
    let written = data.withUnsafeBytes { write(descriptor, $0.baseAddress, data.count) }
    guard written == data.count else { throw .posix(step: "write", path: path) }
    guard fchmod(descriptor, mode) == 0 else { throw .posix(step: "write", path: path) }
  }

  /// Recursively creates a directory path, accepting directories created by a concurrent caller.
  private static func makeDirectories(_ path: String) throws(RuntimeInstallError) {
    if mkdir(path, 0o755) == 0 || errno == EEXIST { return }
    guard errno == ENOENT else { throw .posix(step: "create directory", path: path) }
    try makeDirectories((path as NSString).deletingLastPathComponent)
    guard mkdir(path, 0o755) == 0 || errno == EEXIST else { throw .posix(step: "create directory", path: path) }
  }

  /// Removes a failed staging copy, making read-only directories writable first.
  private static func removeTree(_ path: String) {
    if let mode = mode(of: path), mode & S_IFMT == S_IFDIR {
      chmod(path, 0o700)
      for name in (try? children(of: path)) ?? [] { removeTree("\(path)/\(name)") }
      rmdir(path)
    } else {
      unlink(path)
    }
  }

  /// Returns an entry's `lstat` mode without following symlinks.
  private static func mode(of path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode : nil
  }

  /// Returns a link destination for non-safety-critical callers that can treat failures as absent.
  private static func symlinkDestination(_ path: String) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: path)
  }
}

extension RuntimeInstallError: CustomStringConvertible {
  static func posix(step: String, path: String) -> RuntimeInstallError {
    let code = errno
    return .io(step: step, path: path, errno: code, message: String(cString: strerror(code)))
  }

  public var description: String {
    switch self {
    case let .io(step, path, errno, message):
      "\(step) failed at \(path): \(message) (errno \(errno))"
    case let .differs(path, expected, actual):
      "\(path) differs from the bundle: expected \(expected), found \(actual)"
    }
  }
}
