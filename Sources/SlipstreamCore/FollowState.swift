public enum FollowState: Equatable, Sendable {
  case following
  case paused(newCount: Int)

  public static let bottomThreshold: Double = 24

  public mutating func userScrolled(distanceFromBottom: Double) {
    let atBottom = distanceFromBottom <= Self.bottomThreshold
    switch (self, atBottom) {
    case (.following, false): self = .paused(newCount: 0)
    case (.paused, true): self = .following
    default: break
    }
  }

  public mutating func fileCardAppended() {
    if case .paused(let count) = self {
      self = .paused(newCount: count + 1)
    }
  }

  public mutating func jumpToLatest() {
    self = .following
  }
}
