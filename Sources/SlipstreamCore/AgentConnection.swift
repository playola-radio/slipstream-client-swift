public enum AgentConnection: Equatable, Sendable {
  case connected
  case setupPending
  case disconnected(reason: String?)
  case unreported

  init(state: String, reason: String? = nil) {
    switch state {
    case "connected": self = .connected
    case "setup_pending": self = .setupPending
    case "disconnected": self = .disconnected(reason: reason)
    default: self = .disconnected(reason: state)
    }
  }
}

struct AgentConnectionWire: Decodable {
  var state: String
  var reason: String?

  var connection: AgentConnection {
    AgentConnection(state: state, reason: reason)
  }
}
