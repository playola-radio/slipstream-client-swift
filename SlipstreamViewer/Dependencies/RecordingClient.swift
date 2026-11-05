import Dependencies
import Foundation
import SlipstreamCore

struct RecordingClient: Sendable {
  var record: @Sendable (_ folder: String) async throws -> Void
  var pause: @Sendable (_ folder: String) async throws -> Void
}

extension RecordingClient: DependencyKey {
  static var liveValue: Self {
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    let transport = ControlTransport(store: store)
    return Self(
      record: { try await transport.record(folder: $0) },
      pause: { try await transport.pause(folder: $0) }
    )
  }

  static var testValue: Self {
    Self(
      record: unimplemented("RecordingClient.record"),
      pause: unimplemented("RecordingClient.pause")
    )
  }
}

extension DependencyValues {
  var recording: RecordingClient {
    get { self[RecordingClient.self] }
    set { self[RecordingClient.self] = newValue }
  }
}
