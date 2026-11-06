import CustomDump
import SlipstreamCore
import Testing

struct FollowStateTests {
  @Test func userScrollAwayFromBottomPauses() {
    var state = FollowState.following
    state.userScrolled(distanceFromBottom: 200)
    expectNoDifference(state, .paused(newCount: 0))
  }

  @Test func smallUserScrollWithinThresholdKeepsFollowing() {
    var state = FollowState.following
    state.userScrolled(distanceFromBottom: FollowState.bottomThreshold)
    expectNoDifference(state, .following)
  }

  @Test func fileCardsWhilePausedIncrementCount() {
    var state = FollowState.paused(newCount: 0)
    state.fileCardAppended()
    state.fileCardAppended()
    expectNoDifference(state, .paused(newCount: 2))
  }

  @Test func fileCardsWhileFollowingDoNotPause() {
    var state = FollowState.following
    state.fileCardAppended()
    expectNoDifference(state, .following)
  }

  @Test func userScrollBackToBottomResumesFollowing() {
    var state = FollowState.paused(newCount: 3)
    state.userScrolled(distanceFromBottom: 0)
    expectNoDifference(state, .following)
  }

  @Test func userScrollWhilePausedAwayFromBottomKeepsCount() {
    var state = FollowState.paused(newCount: 3)
    state.userScrolled(distanceFromBottom: 500)
    expectNoDifference(state, .paused(newCount: 3))
  }

  @Test func jumpToLatestResumesFollowing() {
    var state = FollowState.paused(newCount: 5)
    state.jumpToLatest()
    expectNoDifference(state, .following)
  }
}
