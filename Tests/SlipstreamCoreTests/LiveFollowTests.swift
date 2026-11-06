import CustomDump
import Foundation
import SlipstreamCore
import Synchronization
import Testing

@Suite(.serialized, .enabled(if: LiveDaemon.store != nil, "Set SLIPSTREAM_STORE to a disposable qa:daemon store"))
struct LiveFollowTests {
  @Test(.timeLimit(.minutes(1)))
  func followMatchesFiniteReplay() async throws {
    let daemon = try LiveDaemon()
    let start = try await daemon.durableSeq()
    let recorder = Recorder()
    let follow = daemon.follow(after: start, recorder: recorder)
    defer { follow.cancel() }

    let id = UUID().uuidString.prefix(8).lowercased()
    let function = "src/live-\(id).ts"
    let scratch = "src/scratch-\(id).ts"
    let notes = "notes-\(id).md"

    try daemon.write(function, "export function greet(name: string): string {\n  const greeting = \"Hello\";\n  return `${greeting}, ${name}`;\n}\n")
    try await recorder.waitForChange(to: function) { $0.before == .absent }
    try daemon.write(function, "export function greet(name: string): string {\n  const greeting = \"Hi\";\n  return `${greeting}, ${name}`;\n}\n")
    try await recorder.waitForChange(to: function) { $0.before != .absent }
    try daemon.write(scratch, "export const scratch = 1;\n")
    try await recorder.waitForChange(to: scratch) { $0.after != .absent }
    try daemon.remove(scratch)
    try await recorder.waitForChange(to: scratch) { $0.after == .absent }
    try daemon.write(notes, "# Notes\n\nFirst line.\n")
    try await recorder.waitForChange(to: notes) { _ in true }
    follow.cancel()

    let applied = recorder.events
    let replay = try await daemon.replay(after: start).prefix { $0.seq <= applied.last!.seq }
    expectNoDifference(applied, Array(replay))
    #expect(applied.map(\.seq) == Array(sequence(first: start.successor) { $0.successor }.prefix(applied.count)))

    let liveCards = try await daemon.cards(for: applied)

    let functionCards = liveCards.filter { $0.path.hasSuffix(function) }
    try #require(functionCards.count == 2)
    #expect(functionCards[0].blocks.flatMap { $0 }.allSatisfy { $0.isChanged })
    #expect(functionCards[1].methods == ["function"])
    #expect(functionCards[1].spans == ["1-4"])
    #expect(functionCards[1].blocks.flatMap { $0 }.filter(\.isChanged).map(\.number) == [2])
    let deleted = try #require(liveCards.last { $0.path.hasSuffix(scratch) })
    #expect(deleted.after == "absent")
    let notesCard = try #require(liveCards.first { $0.path.hasSuffix(notes) })
    #expect(!notesCard.methods.contains("function"))
    #expect(notesCard.blocks.flatMap { $0 }.contains { $0.isChanged })

    print("live follow: applied #\(applied.first!.seq)…#\(applied.last!.seq) (\(applied.count) events) == finite replay")
    for card in liveCards {
      let marked = card.blocks.flatMap { $0 }.filter(\.isChanged).map { String($0.number) }
      print("  #\(card.seq) \(card.path) after=\(card.after) methods=\(card.methods) spans=\(card.spans) markers=\(marked)")
    }
  }

  @Test(
    .enabled(if: ProcessInfo.processInfo.environment["SLIPSTREAM_QA_RESTART"] == "1", "Set SLIPSTREAM_QA_RESTART=1 and restart the daemon while it waits"),
    .timeLimit(.minutes(5))
  )
  func followResumesAcrossDaemonRestart() async throws {
    let daemon = try LiveDaemon()
    let start = try await daemon.durableSeq()
    let recorder = Recorder()
    let follow = daemon.follow(after: start, recorder: recorder)
    defer { follow.cancel() }
    let firstPort = try await recorder.waitForPort()

    let writer = Task {
      var count = 0
      while !Task.isCancelled {
        count += 1
        try? daemon.write("src/restart-probe.ts", "export const beat = \(count);\n")
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
    defer { writer.cancel() }
    print("live restart: following from #\(start) on port \(firstPort); restart the daemon now")

    try await recorder.waitUntil(timeout: .seconds(240)) {
      $0.ports.contains { $0 != firstPort } && $0.statuses.last == .live
    }
    writer.cancel()
    try await Task.sleep(for: .seconds(3))
    follow.cancel()

    let applied = recorder.events
    let replay = try await daemon.replay(after: start)
    let seqs = applied.map(\.seq)
    #expect(Set(seqs).count == seqs.count)
    expectNoDifference(seqs, replay.map(\.seq))
    expectNoDifference(applied, replay)
    #expect(recorder.statuses.contains { if case .reconnecting = $0 { true } else { false } })
    print("live restart: ports \(recorder.ports.uniqued()) statuses \(recorder.statuses.map(String.init(describing:)).uniqued())")
    print("live restart: applied #\(seqs.first!)…#\(seqs.last!) (\(seqs.count) events), replay has \(replay.count); no gaps, no duplicates")
  }
}

struct LiveCard: Equatable {
  var seq: Seq
  var path: String
  var after: String
  var methods: [String]
  var spans: [String]
  var blocks: [[ClipLine]]
}

struct LiveDaemon: Sendable {
  static var store: URL? {
    ProcessInfo.processInfo.environment["SLIPSTREAM_STORE"].map { URL(fileURLWithPath: $0) }
  }

  let store: URL
  let worktree: URL
  let sessionID: String
  let transport = DaemonTransport()

  init() throws {
    store = try #require(Self.store)
    let env = store.deletingLastPathComponent().appendingPathComponent("qa-env.json")
    let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: env)) as? [String: Any])
    worktree = URL(fileURLWithPath: try #require(json["worktree"] as? String))
    sessionID = try #require(json["session_id"] as? String)
  }

  func descriptor() throws -> DaemonDescriptor {
    try DescriptorDiscovery.discover(store: store)
  }

  func durableSeq() async throws -> Seq {
    let sessions = try await transport.sessions(descriptor())
    return try #require(sessions.first { $0.id == sessionID }).durableSeq
  }

  func follow(after start: Seq, recorder: Recorder) -> Task<FollowerExit, Never> {
    let follower = EventFollower(
      discover: {
        let descriptor = try descriptor()
        recorder.record(port: descriptor.baseURL.port ?? 0)
        return descriptor
      },
      open: { transport.follow($0, sessionID: sessionID, after: $1) },
      clock: ContinuousClock(),
      jitter: { Double.random(in: 0...1) }
    )
    return Task {
      await follower.run(after: start, status: { recorder.record(status: $0) }, apply: { recorder.record(event: $0) })
    }
  }

  func replay(after start: Seq) async throws -> [SlipstreamEvent] {
    let descriptor = try descriptor()
    var components = URLComponents(url: descriptor.baseURL, resolvingAgainstBaseURL: false)!
    components.path = "/v1/sessions/\(sessionID)/events"
    components.queryItems = [URLQueryItem(name: "after", value: start.decimal), URLQueryItem(name: "follow", value: "false")]
    var request = URLRequest(url: components.url!)
    request.setValue("Bearer \(descriptor.token)", forHTTPHeaderField: "Authorization")
    let (data, response) = try await URLSession.shared.data(for: request)
    try #require((response as? HTTPURLResponse)?.statusCode == 200)
    return try data.split(separator: UInt8(ascii: "\n")).map { try SlipstreamEvent.decode(Data($0)) }
  }

  func cards(for events: [SlipstreamEvent]) async throws -> [LiveCard] {
    let descriptor = try descriptor()
    var cards: [LiveCard] = []
    for event in events {
      guard case .fileChanged(let change) = event.payload else { continue }
      var card = LiveCard(seq: event.seq, path: change.path, after: "\(change.after)", methods: [], spans: [], blocks: [])
      if case .content(let afterSHA, _) = change.after {
        let clips = try await transport.clips(descriptor, sessionID: sessionID, seq: event.seq)
        let after = String(decoding: try await transport.blob(descriptor, sha256: afterSHA), as: UTF8.self)
        var before: String?
        if case .content(let beforeSHA, _) = change.before {
          before = String(decoding: try await transport.blob(descriptor, sha256: beforeSHA), as: UTF8.self)
        }
        let comparison = ChangedLines.compare(before: before, after: after, spans: clips.clips.compactMap(\.after.span))
        for clip in clips.clips {
          guard let span = clip.after.span else { continue }
          card.methods.append(clip.after.method.rawValue)
          card.spans.append("\(span.lineStart)-\(span.lineEnd)")
          card.blocks.append(comparison.clipLines(lineStart: span.lineStart, lineEnd: span.lineEnd))
        }
      }
      cards.append(card)
    }
    return cards
  }

  func write(_ path: String, _ text: String) throws {
    let url = worktree.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  func remove(_ path: String) throws {
    try FileManager.default.removeItem(at: worktree.appendingPathComponent(path))
  }
}

final class Recorder: Sendable {
  struct State {
    var events: [SlipstreamEvent] = []
    var statuses: [FollowerStatus] = []
    var ports: [Int] = []
  }

  private let state = Mutex(State())

  var events: [SlipstreamEvent] { state.withLock { $0.events } }
  var statuses: [FollowerStatus] { state.withLock { $0.statuses } }
  var ports: [Int] { state.withLock { $0.ports } }

  func record(event: SlipstreamEvent) -> Bool {
    state.withLock { $0.events.append(event) }
    return true
  }

  func record(status: FollowerStatus) {
    state.withLock { $0.statuses.append(status) }
  }

  func record(port: Int) {
    state.withLock { $0.ports.append(port) }
  }

  func waitUntil(timeout: Duration = .seconds(20), _ condition: (State) -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !state.withLock({ condition($0) }) {
      guard ContinuousClock.now < deadline else {
        Issue.record("Timed out waiting for the daemon")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  func waitForChange(to path: String, where predicate: @escaping (FileChange) -> Bool) async throws {
    try await waitUntil { state in
      state.events.contains { event in
        guard case .fileChanged(let change) = event.payload else { return false }
        return change.path.hasSuffix(path) && predicate(change)
      }
    }
  }

  func waitForPort() async throws -> Int {
    try await waitUntil { !$0.ports.isEmpty }
    return ports[0]
  }
}

extension Array where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen: Set<Element> = []
    return filter { seen.insert($0).inserted }
  }
}
