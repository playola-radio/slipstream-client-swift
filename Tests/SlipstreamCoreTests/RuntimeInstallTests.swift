import CryptoKit
import CustomDump
import Darwin
import Foundation
import Synchronization
@testable import SlipstreamCore
import Testing

struct RuntimeInstallTests {
  @Test func prepareCopiesAndCompares() throws {
    let sandbox = try Sandbox()

    let prepared = try sandbox.install().prepare()

    expectNoDifference(
      prepared,
      PreparedRuntime(
        identity: RuntimeIdentity(version: "0.3.2", build: "abcdef0123456789", appBuild: 5),
        directory: sandbox.root.appendingPathComponent("0.3.2-abcdef01", isDirectory: true)))
    expectNoDifference(try snapshot(prepared.directory), try snapshot(sandbox.bundled))
    expectNoDifference(try names(in: sandbox.root), [".lock", "0.3.2-abcdef01"])
  }

  @Test func prepareRejectsChangedByte() throws {
    let sandbox = try Sandbox()
    let install = sandbox.install { staging in
      do {
        try Data("console.log('tampered')\n".utf8).write(to: staging.appendingPathComponent("app/dist/cli.js"))
      } catch {
        Issue.record(error)
      }
    }

    expectNoDifference(
      prepareError(install),
      .differs(
        path: "app/dist/cli.js",
        expected: sha256(Sandbox.cliScript),
        actual: sha256("console.log('tampered')\n")))
    expectNoDifference(try names(in: sandbox.root), [".lock"])
  }

  @Test func prepareRejectsExtraFile() throws {
    let sandbox = try Sandbox()
    let install = sandbox.install { staging in
      do {
        try Data("extra".utf8).write(to: staging.appendingPathComponent("app/extra.txt"))
      } catch {
        Issue.record(error)
      }
    }

    expectNoDifference(prepareError(install), .differs(path: "app/extra.txt", expected: "absent", actual: "present"))
    expectNoDifference(try names(in: sandbox.root), [".lock"])
  }

  @Test func prepareRejectsModeChange() throws {
    let sandbox = try Sandbox()
    let install = sandbox.install { staging in
      chmod(staging.appendingPathComponent("bin/node").path, 0o700)
    }

    expectNoDifference(prepareError(install), .differs(path: "bin/node", expected: "100755", actual: "100700"))
    expectNoDifference(try names(in: sandbox.root), [".lock"])
  }

  @Test func prepareRejectsSymlink() throws {
    let sandbox = try Sandbox()
    try FileManager.default.createSymbolicLink(
      atPath: sandbox.bundled.appendingPathComponent("app/link").path, withDestinationPath: "dist/cli.js")

    expectNoDifference(
      prepareError(sandbox.install()), .differs(path: "app/link", expected: "present", actual: "absent"))
    expectNoDifference(try names(in: sandbox.root), [".lock"])
  }

  @Test func copyFailureLeavesCurrent() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.2")
    let unreadable = sandbox.bundled.appendingPathComponent("app/dist/cli.js")
    chmod(unreadable.path, 0o000)
    defer { chmod(unreadable.path, 0o644) }

    expectNoDifference(
      prepareError(install),
      .io(step: "copy", path: unreadable.path, errno: EACCES, message: String(cString: strerror(EACCES))))
    expectNoDifference(try currentTarget(sandbox.root), "0.3.1-abcdef01")
    expectNoDifference(try names(in: sandbox.root), [".lock", "0.3.1-abcdef01", "bin", "current"])
  }

  @Test func prepareRemovesStaleStaging() throws {
    let sandbox = try Sandbox()
    let stale = sandbox.root.appendingPathComponent(".staging-left-by-a-crash/app")
    try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
    try Data("partial".utf8).write(to: stale.appendingPathComponent("cli.js"))

    _ = try sandbox.install().prepare()

    expectNoDifference(try names(in: sandbox.root), [".lock", "0.3.2-abcdef01"])
  }

  @Test func prepareReusesExistingDir() throws {
    let sandbox = try Sandbox()
    let copies = Counter()
    let install = sandbox.install { _ in copies.increment() }

    let first = try install.prepare()
    let second = try install.prepare()

    expectNoDifference(second, first)
    expectNoDifference(copies.value, 1)
  }

  @Test func activateFlipsCurrent() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.2")

    let activation = try install.activate(try install.prepare())

    expectNoDifference(activation, .activated)
    expectNoDifference(try currentTarget(sandbox.root), "0.3.2-abcdef01")
    expectNoDifference(try names(in: sandbox.root), [".lock", "0.3.1-abcdef01", "0.3.2-abcdef01", "bin", "current"])
  }

  @Test func activateNeverMovesBackwards() throws {
    let sandbox = try Sandbox(version: "0.3.2")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.1")

    let activation = try install.activate(try install.prepare())

    expectNoDifference(activation, .newerActive(RuntimeIdentity(version: "0.3.2", build: "abcdef0123456789", appBuild: 5)))
    expectNoDifference(try currentTarget(sandbox.root), "0.3.2-abcdef01")
  }

  @Test func activateBreaksVersionTieByAppBuild() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.1", build: "fedcba9876543210", appBuild: "4")

    let activation = try install.activate(try install.prepare())

    expectNoDifference(activation, .newerActive(RuntimeIdentity(version: "0.3.1", build: "abcdef0123456789", appBuild: 5)))
    expectNoDifference(try currentTarget(sandbox.root), "0.3.1-abcdef01")
  }

  @Test func activateSameVersionHigherAppBuildFlips() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.1", build: "fedcba9876543210", appBuild: "6")

    let activation = try install.activate(try install.prepare())

    expectNoDifference(activation, .activated)
    expectNoDifference(try currentTarget(sandbox.root), "0.3.1-fedcba98")
  }

  @Test func currentWithoutAppBuildCountsAsZero() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("0.3.1-abcdef01/app-build"))
    try sandbox.writeIdentity(version: "0.3.1", build: "fedcba9876543210", appBuild: "1")

    let activation = try install.activate(try install.prepare())

    expectNoDifference(activation, .activated)
    expectNoDifference(try currentTarget(sandbox.root), "0.3.1-fedcba98")
  }

  @Test(arguments: [nil, "five"])
  func bundledIdentityRequiresAppBuild(appBuild: String?) throws {
    let sandbox = try Sandbox()
    let path = sandbox.bundled.appendingPathComponent("app-build")
    if let appBuild {
      try Data("\(appBuild)\n".utf8).write(to: path)
    } else {
      try FileManager.default.removeItem(at: path)
    }

    #expect(throws: RuntimeInstallError.io(
      step: "read app build",
      path: path.path,
      errno: 0,
      message: appBuild == nil ? "app-build is missing" : "app-build is not an integer: \"five\""
    )) {
      try sandbox.install().bundledIdentity()
    }
  }

  @Test func activateKeepsUnreadableCurrent() throws {
    let sandbox = try Sandbox(version: "0.3.2")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    let package = sandbox.root.appendingPathComponent("0.3.2-abcdef01/app/package.json")
    try Data("{}".utf8).write(to: package)
    try sandbox.writeIdentity(version: "0.3.1")
    let older = try install.prepare()

    #expect(throws: RuntimeInstallError.self) { try install.activate(older) }
    expectNoDifference(try currentTarget(sandbox.root), "0.3.2-abcdef01")
  }

  @Test func activateRejectsCurrentThatIsNotASymlink() throws {
    let sandbox = try Sandbox()
    let install = sandbox.install()
    let prepared = try install.prepare()
    let current = sandbox.root.appendingPathComponent("current")
    try Data("not a symlink\n".utf8).write(to: current)

    #expect(throws: RuntimeInstallError.io(
      step: "read current",
      path: current.path,
      errno: EINVAL,
      message: String(cString: strerror(EINVAL))
    )) {
      try install.activate(prepared)
    }
    expectNoDifference(try String(contentsOf: current, encoding: .utf8), "not a symlink\n")
  }

  @Test func shimFailureLeavesCurrent() throws {
    let sandbox = try Sandbox(version: "0.3.1")
    let install = sandbox.install()
    _ = try install.activate(try install.prepare())
    try sandbox.writeIdentity(version: "0.3.2")
    let newer = try install.prepare()
    let bin = sandbox.root.appendingPathComponent("bin")
    chmod(bin.path, 0o500)
    defer { chmod(bin.path, 0o755) }

    #expect(throws: RuntimeInstallError.self) { try install.activate(newer) }
    expectNoDifference(try currentTarget(sandbox.root), "0.3.1-abcdef01")
  }

  @Test(arguments: [
    ("0.3.10", "0.3.9"),
    ("1.0.0", "1.0.0-rc.1"),
    ("1.0.0-alpha.10", "1.0.0-alpha.2"),
    ("1.0.0-alpha2", "1.0.0-alpha10"),
    ("1.0.0-alpha.1", "1.0.0-alpha"),
    ("1.0.0-alpha", "1.0.0-1"),
  ])
  func versionPrecedenceFollowsSemver(newer: String, older: String) {
    #expect(RuntimeInstall.isVersion(newer, newerThan: older))
    #expect(!RuntimeInstall.isVersion(older, newerThan: newer))
  }

  @Test func activateWritesShims() throws {
    let sandbox = try Sandbox()
    let install = sandbox.install()

    _ = try install.activate(try install.prepare())

    let bin = sandbox.root.appendingPathComponent("bin")
    expectNoDifference(
      try String(contentsOf: bin.appendingPathComponent("slipstream"), encoding: .utf8),
      shim("cli.js", root: sandbox.root))
    expectNoDifference(
      try String(contentsOf: bin.appendingPathComponent("slipstream-mcp"), encoding: .utf8),
      shim("mcp-forwarder.js", root: sandbox.root))
    expectNoDifference(try mode(bin.appendingPathComponent("slipstream")), 0o100755)
    expectNoDifference(try mode(bin.appendingPathComponent("slipstream-mcp")), 0o100755)
  }

  @Test func linkCommandsReportsForeignFile() throws {
    let sandbox = try Sandbox()
    try FileManager.default.createDirectory(at: sandbox.commands, withIntermediateDirectories: true)
    let foreign = sandbox.commands.appendingPathComponent("slipstream")
    try Data("#!/bin/sh\n".utf8).write(to: foreign)

    let problems = sandbox.install().linkCommands()

    let shim = sandbox.root.appendingPathComponent("bin/slipstream").path
    expectNoDifference(
      problems,
      [LinkProblem(path: foreign.path, message: "\(foreign.path) already exists and is not a link to \(shim); left it alone.")])
    expectNoDifference(
      try FileManager.default.destinationOfSymbolicLink(atPath: sandbox.commands.appendingPathComponent("slipstream-mcp").path),
      sandbox.root.appendingPathComponent("bin/slipstream-mcp").path)
    expectNoDifference(sandbox.install().linkCommands(), problems)
  }

  @Test func concurrentPrepareIsSerialized() async throws {
    let sandbox = try Sandbox()
    let copies = Counter()
    let install = sandbox.install { _ in copies.increment() }

    async let first = Task.detached { try install.prepare() }.value
    async let second = Task.detached { try install.prepare() }.value
    let results = try await [first, second]

    expectNoDifference(results[0], results[1])
    expectNoDifference(copies.value, 1)
    expectNoDifference(try names(in: sandbox.root), [".lock", "0.3.2-abcdef01"])
  }
}

private struct Sandbox {
  static let cliScript = "console.log('slipstream')\n"

  let root: URL
  let bundled: URL
  let commands: URL

  init(version: String = "0.3.2") throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("RuntimeInstallTests-\(UUID().uuidString)", isDirectory: true)
    root = base.appendingPathComponent("runtime", isDirectory: true)
    bundled = base.appendingPathComponent("SlipstreamRuntime", isDirectory: true)
    commands = base.appendingPathComponent("local-bin", isDirectory: true)
    try write("node binary", to: "bin/node", mode: 0o755)
    try write(Self.cliScript, to: "app/dist/cli.js")
    try write("console.log('forwarder')\n", to: "app/dist/mcp-forwarder.js")
    try write("module.exports = {}\n", to: "app/node_modules/@parcel/watcher/index.js")
    try writeIdentity(version: version)
  }

  func install(afterCopy: @escaping @Sendable (URL) -> Void = { _ in }) -> RuntimeInstall {
    RuntimeInstall(root: root, bundled: bundled, commandsDirectory: commands, afterCopy: afterCopy)
  }

  func writeIdentity(version: String, build: String = "abcdef0123456789", appBuild: String = "5") throws {
    try write(#"{"name":"slipstream","version":"\#(version)"}"#, to: "app/package.json")
    try write("\(build)\n", to: "app/dist/build-id")
    try write("\(appBuild)\n", to: "app-build")
  }

  private func write(_ text: String, to relativePath: String, mode: Int = 0o644) throws {
    let url = bundled.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }
}

private final class Counter: Sendable {
  private let count = Mutex(0)
  var value: Int { count.withLock { $0 } }
  func increment() { count.withLock { $0 += 1 } }
}

private func prepareError(_ install: RuntimeInstall) -> RuntimeInstallError? {
  do {
    _ = try install.prepare()
    return nil
  } catch {
    return error
  }
}

private func shim(_ script: String, root: URL) -> String {
  """
  #!/bin/sh
  root='\(root.path)'
  dir="$(cd "$root/current" 2>/dev/null && pwd -P)" || { echo "slipstream: no runtime at $root/current; open Slipstream once." >&2; exit 127; }
  SLIPSTREAM_APP_RUNTIME="$root" exec "$dir/bin/node" "$dir/app/dist/\(script)" "$@"

  """
}

private func sha256(_ text: String) -> String {
  SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func names(in directory: URL) throws -> [String] {
  try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
}

private func currentTarget(_ root: URL) throws -> String {
  try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("current").path)
}

private func mode(_ url: URL) throws -> mode_t {
  var info = stat()
  guard lstat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
  return info.st_mode
}

/// Every relative path under `directory` with its mode and contents.
private func snapshot(_ directory: URL) throws -> [String: String] {
  var result: [String: String] = [:]
  let paths = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
  for path in paths {
    let url = directory.appendingPathComponent(path)
    let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? "<directory>"
    result[path] = "\(String(try mode(url), radix: 8)) \(contents)"
  }
  return result
}
