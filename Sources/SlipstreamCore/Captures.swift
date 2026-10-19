import Foundation

public struct CaptureList: Decodable, Equatable, Sendable {
  public var captures: [CaptureSummary]

  public init(captures: [CaptureSummary]) {
    self.captures = captures
  }
}

public struct CaptureSummary: Decodable, Equatable, Sendable {
  public var sessionID: String
  public var root: String
  public var state: CaptureState
  public var reason: String?
  public var retryAtMs: Int64?
  public var binding: CaptureBinding?

  public init(
    sessionID: String, root: String, state: CaptureState, reason: String? = nil,
    retryAtMs: Int64? = nil, binding: CaptureBinding? = nil
  ) {
    self.sessionID = sessionID
    self.root = root
    self.state = state
    self.reason = reason
    self.retryAtMs = retryAtMs
    self.binding = binding
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sessionID = try container.decode(String.self, forKey: .sessionID)
    root = try container.decode(String.self, forKey: .root)
    state = CaptureState(rawValue: try container.decode(String.self, forKey: .state))
    reason = try container.decode(String?.self, forKey: .reason)
    retryAtMs = try container.decode(Retry?.self, forKey: .retry)?.nextAttemptAtMs
    binding = try container.decode(CaptureBinding?.self, forKey: .binding)
  }

  private struct Retry: Decodable {
    var nextAttemptAtMs: Int64

    enum CodingKeys: String, CodingKey {
      case nextAttemptAtMs = "next_attempt_at_ms"
    }
  }

  enum CodingKeys: String, CodingKey {
    case sessionID = "session_id", root, state, reason, retry, binding
  }
}

public struct CaptureBinding: Decodable, Equatable, Sendable {
  public var generation: String
  public var state: BindingState
  public var reason: String?

  public init(generation: String, state: BindingState, reason: String? = nil) {
    self.generation = generation
    self.state = state
    self.reason = reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    generation = try container.decode(String.self, forKey: .generation)
    state = BindingState(rawValue: try container.decode(String.self, forKey: .state))
    reason = try container.decode(String?.self, forKey: .reason)
  }

  enum CodingKeys: String, CodingKey {
    case generation = "binding_generation", state, reason
  }
}

public enum CaptureState: Equatable, Sendable {
  case queued, baselining, recording, stopped, notRecording
  case unknown(String)

  init(rawValue: String) {
    switch rawValue {
    case "queued": self = .queued
    case "baselining": self = .baselining
    case "recording": self = .recording
    case "stopped": self = .stopped
    case "not_recording": self = .notRecording
    default: self = .unknown(rawValue)
    }
  }
}

public enum BindingState: Equatable, Sendable {
  case setupPending, connected, unavailable, unlinked
  case unknown(String)

  init(rawValue: String) {
    switch rawValue {
    case "setup_pending": self = .setupPending
    case "connected": self = .connected
    case "unavailable": self = .unavailable
    case "unlinked": self = .unlinked
    default: self = .unknown(rawValue)
    }
  }
}
