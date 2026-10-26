import CustomDump
import Foundation
import IdentifiedCollections
import Testing

@testable import SlipstreamViewer

struct TerminalStateTests {
  static let setup = UUID(uuidString: "6E1D7A40-0000-4000-8000-000000000001")!
  static let first = UUID(uuidString: "6E1D7A40-0000-4000-8000-000000000002")!
  static let second = UUID(uuidString: "6E1D7A40-0000-4000-8000-000000000003")!
  static let other = UUID(uuidString: "6E1D7A40-0000-4000-8000-000000000004")!

  @Test func codableRoundTrip() throws {
    let state = TerminalState(
      tabs: [
        TerminalTabRecord(id: Self.setup, folder: nil, kind: .setup(.running)),
        TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .setup(.finished(seconds: 14))),
        TerminalTabRecord(id: Self.second, folder: "/w/a", kind: .setup(.failed(exitStatus: 2))),
        TerminalTabRecord(id: Self.other, folder: nil, kind: .setup(.failed(exitStatus: nil))),
        TerminalTabRecord(id: UUID(), folder: "/w/b", kind: .setup(.interrupted)),
        TerminalTabRecord(id: UUID(), folder: "/w/b", kind: .terminal(number: 3)),
      ],
      selectedTabIDs: ["/w/a": Self.second]
    )

    let decoded = try JSONDecoder().decode(TerminalState.self, from: JSONEncoder().encode(state))

    expectNoDifference(decoded, state)
  }

  @Test func orphanSetupShowsFirstInEveryFolder() {
    let state = TerminalState(tabs: [
      TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .terminal(number: 1)),
      TerminalTabRecord(id: Self.setup, folder: nil, kind: .setup(.running)),
      TerminalTabRecord(id: Self.other, folder: "/w/unlisted", kind: .setup(.failed(exitStatus: 1))),
      TerminalTabRecord(id: Self.second, folder: "/w/b", kind: .terminal(number: 1)),
    ])

    expectNoDifference(
      state.tabs(shownIn: "/w/a", listed: ["/w/a", "/w/b"]).map(\.id), [Self.setup, Self.other, Self.first])
    expectNoDifference(
      state.tabs(shownIn: "/w/b", listed: ["/w/a", "/w/b"]).map(\.id), [Self.setup, Self.other, Self.second])
  }

  @Test func orphanSetupShowsAloneWithNoFolder() {
    let state = TerminalState(tabs: [
      TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .terminal(number: 1)),
      TerminalTabRecord(id: Self.setup, folder: nil, kind: .setup(.running)),
    ])

    expectNoDifference(state.tabs(shownIn: nil, listed: ["/w/a"]).map(\.id), [Self.setup])
  }

  @Test func listedSetupShowsOnlyInItsFolder() {
    let state = TerminalState(tabs: [
      TerminalTabRecord(id: Self.setup, folder: "/w/a", kind: .setup(.finished(seconds: 3))),
      TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .terminal(number: 1)),
      TerminalTabRecord(id: Self.second, folder: "/w/b", kind: .terminal(number: 1)),
    ])

    expectNoDifference(state.tabs(shownIn: "/w/a", listed: ["/w/a", "/w/b"]).map(\.id), [Self.setup, Self.first])
    expectNoDifference(state.tabs(shownIn: "/w/b", listed: ["/w/a", "/w/b"]).map(\.id), [Self.second])
  }

  @Test func nextNumberIsHighestPlusOne() {
    let state = TerminalState(tabs: [
      TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .terminal(number: 1)),
      TerminalTabRecord(id: Self.second, folder: "/w/a", kind: .terminal(number: 3)),
      TerminalTabRecord(id: Self.other, folder: "/w/b", kind: .terminal(number: 7)),
    ])

    #expect(state.nextTerminalNumber(in: "/w/a") == 4)
    #expect(state.nextTerminalNumber(in: "/w/c") == 1)
  }

  @Test func moveSetupSetsFolderAndSelectsIt() {
    var state = TerminalState(
      tabs: [
        TerminalTabRecord(id: Self.setup, folder: nil, kind: .setup(.running)),
        TerminalTabRecord(id: Self.first, folder: "/w/a", kind: .terminal(number: 1)),
      ],
      selectedTabIDs: ["/w/a": Self.setup]
    )

    expectDifference(state) {
      state.moveSetup(Self.setup, to: "/w/new")
    } changes: {
      $0.tabs[id: Self.setup]?.folder = "/w/new"
      $0.selectedTabIDs["/w/new"] = Self.setup
    }
  }
}
