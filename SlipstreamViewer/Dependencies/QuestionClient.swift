import Dependencies
import Foundation
import SlipstreamCore

struct QuestionClient: Sendable {
  var send: @Sendable (QuestionRequest) async throws -> QuestionAcknowledgment
  var record: @Sendable (QuestionRequest) async throws -> ExchangeAcknowledgment
  var updateRelay: @Sendable (QuestionRelayUpdateRequest) async throws -> RelayAcknowledgment
  var supportsRelays: @Sendable (_ sessionID: String) async throws -> Bool
}

extension QuestionClient: DependencyKey {
  static var liveValue: Self {
    let store = DescriptorDiscovery.storeURL(
      environment: ProcessInfo.processInfo.environment,
      home: FileManager.default.homeDirectoryForCurrentUser
    )
    let transport = ControlTransport(store: store)
    return Self(
      send: { try await transport.ask($0) },
      record: { try await transport.recordExchange($0) },
      updateRelay: { try await transport.updateRelay($0) },
      supportsRelays: { try await transport.supportsRelays(sessionID: $0) }
    )
  }

  static var testValue: Self {
    Self(
      send: unimplemented("QuestionClient.send"),
      record: unimplemented("QuestionClient.record"),
      updateRelay: unimplemented("QuestionClient.updateRelay"),
      supportsRelays: unimplemented("QuestionClient.supportsRelays")
    )
  }
}

extension DependencyValues {
  var questionClient: QuestionClient {
    get { self[QuestionClient.self] }
    set { self[QuestionClient.self] = newValue }
  }
}
