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
