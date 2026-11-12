import Dependencies
import Foundation
import SlipstreamCore

struct RuntimeInstallClient: Sendable {
  var bundledIdentity: @Sendable () throws -> RuntimeIdentity
  var prepare: @Sendable () async throws -> PreparedRuntime
  var activate: @Sendable (PreparedRuntime) async throws -> Activation
  var linkCommands: @Sendable () async -> [LinkProblem]
}

extension RuntimeInstallClient {
  static let runtimeRoot = FileManager.default.homeDirectoryForCurrentUser
    .appending(path: "Library/Application Support/com.playola.SlipstreamViewer/runtime", directoryHint: .isDirectory)
  #if DEBUG
    static let shim =
      ProcessInfo.processInfo.environment["SLIPSTREAM_CLI"].map { URL(fileURLWithPath: $0) }
      ?? runtimeRoot.appending(path: "bin/slipstream")
  #else
    static let shim = runtimeRoot.appending(path: "bin/slipstream")
  #endif

  /// `shim`'s path, or why it isn't there: the app writes it when it switches the recorder to
  /// its own runtime, which it skips while another recorder runs.
  static func installedShim(at shim: URL = shim) throws(ShimMissingError) -> String {
    guard FileManager.default.isExecutableFile(atPath: shim.path) else { throw ShimMissingError(path: shim.path) }
    return shim.path
  }
}

struct ShimMissingError: LocalizedError, Equatable {
  var path: String

  var errorDescription: String? {
    "Slipstream hasn't installed its slipstream command (\(path) is missing). It installs it when it "
      + "switches the recorder to its own; the recorder message says why it hasn't."
  }
}

extension RuntimeInstallClient: DependencyKey {
  static var liveValue: Self {
    let install = RuntimeInstall(
      root: runtimeRoot,
      bundled: Bundle.main.bundleURL.appending(path: "Contents/Resources/SlipstreamRuntime", directoryHint: .isDirectory)
    )
    return Self(
      bundledIdentity: { try install.bundledIdentity() },
      prepare: { try await offMain { try install.prepare() } },
      activate: { runtime in try await offMain { try install.activate(runtime) } },
      linkCommands: { install.linkCommands() }
    )
  }

  static var testValue: Self {
    Self(
      bundledIdentity: unimplemented("RuntimeInstallClient.bundledIdentity"),
      prepare: unimplemented("RuntimeInstallClient.prepare"),
      activate: unimplemented("RuntimeInstallClient.activate"),
      linkCommands: unimplemented("RuntimeInstallClient.linkCommands", placeholder: [])
    )
  }

  private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async { continuation.resume(with: Result { try work() }) }
    }
  }
}

extension DependencyValues {
  var runtimeInstall: RuntimeInstallClient {
    get { self[RuntimeInstallClient.self] }
    set { self[RuntimeInstallClient.self] = newValue }
  }
}
