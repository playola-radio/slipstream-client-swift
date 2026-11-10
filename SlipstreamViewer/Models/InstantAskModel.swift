import Dependencies
import Foundation
import IdentifiedCollections
import IssueReporting
import SlipstreamCore

struct InstantQuestion: Equatable, Sendable {
  let storeID: String
  let sessionID: String
  let folder: String
  let source: QuestionSource
  let replyToQuestionID: String?
  /// The tab that answered the thread's first question; `nil` for a new question.
  let threadChatSessionID: String?
  let earlier: [AskPrompt.Exchange]
  let text: String
}

struct PendingAsk: Identifiable, Equatable, Sendable {
  let id: String
  let storeID: String
  let sessionID: String
  let chatSessionID: UUID
  let source: QuestionSource
  let replyToQuestionID: String?
  let text: String
  var state: State

  enum State: Equatable, Sendable {
    case answering
    case recording
    case recorded
    case couldntAnswer(AskFailure)
    /// The daemon's reply never came back, so the exact request is kept to send again.
    case couldntRecord
  }

  /// The thread a new question shows as until its answer folds into the capture's log.
  var rootThread: QuestionThread {
    QuestionThread(id: id, source: source, turns: [], link: .recorded(chatSessionID: chatSessionID.uuidString.lowercased()))
  }
}

struct AskFailure: Equatable, Sendable {
  enum Kind: Equatable, Sendable { case noReply, noChat, environment, unavailable, badReply, notSaved }

  let kind: Kind
  let detail: String?

  static let noReply = Self(kind: .noReply, detail: nil)

  static func noChat(folder: String) -> Self {
    Self(
      kind: .noChat,
      detail: "No chat is open for \(URL(fileURLWithPath: folder).lastPathComponent). Open one in Slipstream, then try again.")
  }

  static func environment(_ error: any Error) -> Self {
    Self(kind: .environment, detail: sentence(for: error))
  }

  static func notSaved(_ error: any Error) -> Self {
    Self(kind: .notSaved, detail: QuestionFailure.reason(error))
  }

  static func sentence(for error: any Error) -> String {
    let message = (error as? AgentEnvironmentError)?.message ?? error.localizedDescription
    return message.hasSuffix(".") ? message : message + "."
  }
}

/// A change request written to a chat tab, from the write until its report says it is done.
struct RelayRun: Equatable, Sendable {
  let storeID: String
  let sessionID: String
  let questionID: String
  let chatSessionID: UUID
  let folder: String?
  let source: QuestionSource
  let earlier: [AskPrompt.Exchange]
  let request: String
  /// `nil` when this app run never wrote it.
  var delivery: Delivery?
  var report: Report = .idle
  /// When the last check failed; it stays shown while a new check runs.
  var checkFailedAtMs: Int64?
  var checkFailure: String?
  var lastReportRequestID: String?
  var isDone = false
  /// Checked once the log replay catches up, if its chat is idle: set when a replay hands it over
  /// or its chat's turn ends mid-replay, cleared once a check starts.
  var checksAfterReplay = false
  /// Replaced by a newer relay, so it can't be sent again.
  var isSentAgain = false
  /// Steps whose retries ran out, sent again when the daemon reconnects.
  var unrecorded: [QuestionRelayUpdateRequest] = []

  enum Delivery: Equatable, Sendable {
    case writing, waitingForEcho, pickedUp, exitedUnread
  }

  enum Report: Equatable, Sendable {
    case idle
    /// `rerun` is set when the chat's turn ends again before this check finishes.
    case checking(rerun: Bool)
  }
}

/// Answers questions from a read-only copy of a chat tab, then records each question with its
/// answer. One per app: it owns every copy run and recording, so closing the panel or selecting
/// another capture cancels nothing. Work stops only when its capture is deleted or the app quits.
@MainActor
@Observable
final class InstantAskModel: ViewModel {
  // MARK: - Dependencies

  @ObservationIgnored @Dependency(\.agentEnvironment) var agentEnvironment
  @ObservationIgnored @Dependency(\.askFork) var askFork
  @ObservationIgnored @Dependency(\.continuousClock) var clock
  @ObservationIgnored @Dependency(\.date.now) var now
  @ObservationIgnored @Dependency(\.questionClient) var questionClient
  @ObservationIgnored @Dependency(\.uuid) var uuid

  // MARK: - Initialization

  init(chat: ChatPageModel) {
    self.chat = chat
    super.init()
    chat.onRelayDelivery = { [weak self] _, delivery in self?.relayDelivered(delivery) }
    chat.onTabTurnEnded = { [weak self] tabID in self?.tabTurnEnded(tabID) }
  }

  // MARK: - Properties

  static let recordingAttempts = 3
  static let recordingRetryDelay = Duration.milliseconds(2500)

  /// Questions whose answer hasn't folded into a thread yet.
  private(set) var pending: IdentifiedArrayOf<PendingAsk> = []
  /// Keyed by lowercase relay id.
  private(set) var relayRuns: [String: RelayRun] = [:]

  @ObservationIgnored private let chat: ChatPageModel
  @ObservationIgnored private var questions: [String: InstantQuestion] = [:]
  @ObservationIgnored private var recordings: [String: QuestionRequest] = [:]
  /// Keyed by request id. Each run bumps the attempt, so only the latest run can publish.
  @ObservationIgnored private var runs: [String: Run] = [:]
  @ObservationIgnored private var isQuitting = false
  /// Whether each store's daemon can record relays, asked once per connection.
  @ObservationIgnored private var relaySupport: [String: Bool] = [:]
  @ObservationIgnored private var relayTasks: [Int: RelayTask] = [:]
  @ObservationIgnored private var nextRelayTaskID = 0
  /// The capture whose log is replaying; its turn ends wait for the replay to catch up.
  @ObservationIgnored private var replayingSessionID: String?
  /// Question ids with a Send again in flight.
  private var sendingAgain: Set<String> = []

  // MARK: - View Helpers

  /// What the log says, overridden by what this app run has seen and not yet logged.
  func relayStatus(_ relay: QuestionRelay) -> QuestionRelayStatus {
    var relay = relay
    let run = relayRuns[relay.id]
    if run?.delivery == .exitedUnread { relay.isNotDelivered = true }
    return relay.status(
      livePickup: run?.delivery == .pickedUp, liveWrite: run?.delivery != nil, lastCheckFailed: run?.checkFailedAtMs != nil)
  }

  func canSendAgain(_ relay: QuestionRelay) -> Bool {
    relayRuns[relay.id]?.isSentAgain != true && !sendingAgain.contains(relay.questionID)
  }

  // MARK: - User Actions

  /// Starts answering at once; the run outlives the caller. Returns the new entry's request id.
  @discardableResult
  func ask(_ question: InstantQuestion) -> String? {
    guard !isQuitting else { return nil }
    return start(question, at: pending.endIndex)
  }

  /// A recording whose outcome is unknown is sent again unchanged; anything else runs a new copy
  /// under a new request id, which is returned.
  @discardableResult
  func tryAgainTapped(requestID: String) -> String? {
    guard !isQuitting, let entry = pending[id: requestID] else { return nil }
    switch entry.state {
    case .couldntRecord:
      pending[id: requestID]?.state = .recording
      run(requestID) { attempt in await self.record(requestID, attempt: attempt, isOutcomeUnknown: true) }
      return requestID
    case .couldntAnswer:
      guard let question = questions[requestID], let index = pending.index(id: requestID) else { return nil }
      guard answeringTab(for: question) != nil else {
        pending[id: requestID]?.state = .couldntAnswer(.noChat(folder: question.folder))
        return requestID
      }
      forget(requestID)
      return start(question, at: index)
    case .answering, .recording, .recorded:
      return requestID
    }
  }

  /// An entry leaves once its exchange is in the capture's log, even if an error showed first.
  /// Relays this app run didn't write are taken over: a pickup without a done report is checked
  /// at the chat's next idle, and one never picked up is left for the user to send again. While
  /// the log is still replaying, a later event may already hold the report, so nothing is checked.
  func threadsFolded(
    storeID: String, sessionID: String, folder: String?, isReplaying: Bool, threads: IdentifiedArrayOf<QuestionThread>
  ) {
    replayingSessionID = isReplaying ? sessionID : nil
    let questionIDs = Dictionary(
      threads.flatMap { $0.turns.map { ($0.requestID, $0.questionID) } }, uniquingKeysWith: { first, _ in first })
    for entry in pending where entry.sessionID == sessionID {
      guard let questionID = questionIDs[entry.id] else { continue }
      startRelay(for: entry.id, questionID: questionID)
      forget(entry.id)
    }
    for thread in threads {
      for (index, turn) in thread.turns.enumerated() {
        let earlier = thread.turns[..<index].compactMap { turn in
          turn.answer.map { AskPrompt.Exchange(question: turn.text, answer: $0.text) }
        }
        for relay in turn.relays {
          relayFolded(
            relay, storeID: storeID, sessionID: sessionID, folder: folder, source: thread.source, earlier: earlier,
            request: turn.text, isReplaying: isReplaying)
        }
      }
    }
  }

  /// The daemon may have restarted, so its relay support is asked again and steps it never
  /// recorded are sent again under their original request ids. A Send again recorded only now was
  /// never written, and writing it this late could deliver the change twice, so it is not delivered.
  func daemonConnected(storeID: String) async {
    relaySupport[storeID] = nil
    var retries: [Task<Void, Never>] = []
    for (relayID, run) in relayRuns where run.storeID == storeID && !run.unrecorded.isEmpty {
      relayRuns[relayID]?.unrecorded = []
      for request in run.unrecorded {
        retries.append(track(run.sessionID) {
          guard await self.send(request) else { return }
          if case .sent = request.update { self.notDelivered(request.relayID) } else { self.recorded(request) }
        })
      }
    }
    for retry in retries { await retry.value }
  }

  func checkAgainTapped(relayID: String) async {
    guard !isQuitting, let run = relayRuns[relayID], !run.isDone else { return }
    if case .checking = run.report { return }
    await startCheck(relayID)?.value
  }

  /// Writes the request again under a new relay id, once the daemon has recorded it as sent.
  /// A closed chat hands it to the tab the folder is linked to. One runs per question at a time,
  /// and a relay already sent again can't be sent again.
  func sendAgainTapped(relayID: String) async {
    guard !isQuitting, let run = relayRuns[relayID], !run.isSentAgain, !sendingAgain.contains(run.questionID),
      let tab = chat.tabs[id: run.chatSessionID] ?? run.folder.flatMap(chat.linkedAppTab(forFolder:))
    else { return }
    sendingAgain.insert(run.questionID)
    await track(run.sessionID) {
      defer { self.sendingAgain.remove(run.questionID) }
      await self.sendAgain(run, from: relayID, to: tab.id)
    }.value
  }

  /// Selecting the capture again replays its log, which brings recorded answers back.
  func captureDeselected(_ sessionID: String) {
    if replayingSessionID == sessionID { replayingSessionID = nil }
    for entry in pending where entry.sessionID == sessionID {
      if case .recorded = entry.state { forget(entry.id) }
    }
  }

  func captureDeleted(_ sessionID: String) {
    for entry in pending where entry.sessionID == sessionID { forget(entry.id) }
    for (id, relayTask) in relayTasks where relayTask.sessionID == sessionID {
      relayTask.task.cancel()
      relayTasks[id] = nil
    }
    relayRuns = relayRuns.filter { $0.value.sessionID != sessionID }
  }

  /// Stops every copy and returns once they have all exited.
  func quitConfirmed() async {
    isQuitting = true
    let running = runs.values.map(\.task) + relayTasks.values.map(\.task)
    for id in pending.ids { forget(id) }
    for relayTask in relayTasks.values { relayTask.task.cancel() }
    relayTasks = [:]
    for task in running { await task.value }
  }

  // MARK: - Private Helpers

  private struct Run {
    let attempt: Int
    let task: Task<Void, Never>
  }

  private struct RelayTask {
    let sessionID: String
    let task: Task<Void, Never>
  }

  private func start(_ question: InstantQuestion, at index: Int) -> String? {
    let tab = answeringTab(for: question)
    guard let chatSessionID = tab?.id ?? question.threadChatSessionID.flatMap(UUID.init(uuidString:)) else {
      reportIssue("No chat tab can answer a question in \(question.folder)")
      return nil
    }
    let requestID = uuid().uuidString.lowercased()
    pending.insert(
      PendingAsk(
        id: requestID,
        storeID: question.storeID,
        sessionID: question.sessionID,
        chatSessionID: chatSessionID,
        source: question.source,
        replyToQuestionID: question.replyToQuestionID,
        text: question.text,
        state: tab == nil ? .couldntAnswer(.noChat(folder: question.folder)) : .answering
      ),
      at: index
    )
    questions[requestID] = question
    if let record = tab?.record {
      run(requestID) { attempt in await self.answer(requestID, question: question, tab: record, attempt: attempt) }
    }
    return requestID
  }

  /// The thread's own chat while it is open, otherwise the tab the folder is linked to.
  private func answeringTab(for question: InstantQuestion) -> ChatTabModel? {
    if let id = question.threadChatSessionID.flatMap(UUID.init(uuidString:)), let tab = chat.tabs[id: id] {
      return tab
    }
    return chat.linkedAppTab(forFolder: question.folder)
  }

  private func run(_ requestID: String, _ work: @escaping @MainActor (Int) async -> Void) {
    let attempt = (runs[requestID]?.attempt ?? 0) + 1
    runs[requestID] = Run(attempt: attempt, task: Task { await work(attempt) })
  }

  /// Request ids are fresh per store and capture, so the id and attempt identify the run.
  private func isCurrent(_ requestID: String, _ attempt: Int) -> Bool {
    runs[requestID]?.attempt == attempt && !Task.isCancelled
  }

  private func answer(_ requestID: String, question: InstantQuestion, tab: ChatTabRecord, attempt: Int) async {
    let allowsChangeRequests = await supportsRelays(question)
    let environment: AgentEnvironment
    do {
      environment = try await agentEnvironment.resolve()
    } catch {
      return publish(requestID, attempt, .couldntAnswer(.environment(error)))
    }
    let result: AskForkResult
    do throws(AskForkError) {
      result = try await askFork.run(
        AskForkRequest(
          parentSessionID: tab.id,
          folder: tab.folder,
          environment: environment,
          model: tab.model,
          effort: tab.effort,
          prompt: AskPrompt.answer(
            source: question.source, earlier: question.earlier, words: question.text,
            allowsChangeRequests: allowsChangeRequests),
          kind: .answer(allowsChangeRequests: allowsChangeRequests)
        )
      )
    } catch {
      return publish(requestID, attempt, .couldntAnswer(Self.failure(error)))
    }
    guard isCurrent(requestID, attempt), case .answer(let forkSessionID, let reply, let isChangeRequest) = result
    else { return }
    let relaysRequest =
      allowsChangeRequests && isChangeRequest
      && AskPrompt.relayMessage(source: question.source, earlier: question.earlier, words: question.text) != nil
    pending[id: requestID]?.state = .recording
    recordings[requestID] = QuestionRequest(
      sessionID: question.sessionID,
      requestID: requestID,
      text: question.text,
      context: question.source.context,
      replyToQuestionID: question.replyToQuestionID,
      verb: .recordExchange(
        answerText: reply,
        conversation: ExchangeConversation(parentSessionID: tab.id.uuidString, forkSessionID: forkSessionID),
        relay: relaysRequest
          ? ExchangeRelay(relayID: uuid().uuidString.lowercased(), chatSessionID: tab.id.uuidString.lowercased())
          : nil
      )
    )
    await record(requestID, attempt: attempt, isOutcomeUnknown: false)
  }

  /// An unknown outcome is retried with the identical body. A refusal is final only while every
  /// earlier attempt is known to have failed; otherwise the exchange may already be saved.
  private func record(_ requestID: String, attempt: Int, isOutcomeUnknown: Bool) async {
    guard let request = recordings[requestID] else { return }
    var isOutcomeUnknown = isOutcomeUnknown
    for remaining in (0..<Self.recordingAttempts).reversed() {
      do {
        let acknowledgment = try await questionClient.record(request)
        guard isCurrent(requestID, attempt) else { return }
        startRelay(for: requestID, questionID: acknowledgment.questionID)
        return publish(requestID, attempt, .recorded)
      } catch where QuestionFailure.isOutcomeUnknown(error) {
        isOutcomeUnknown = true
        guard remaining > 0 else { return publish(requestID, attempt, .couldntRecord) }
        guard (try? await clock.sleep(for: Self.recordingRetryDelay)) != nil, isCurrent(requestID, attempt) else {
          return
        }
      } catch {
        return publish(requestID, attempt, isOutcomeUnknown ? .couldntRecord : .couldntAnswer(.notSaved(error)))
      }
    }
  }

  private func publish(_ requestID: String, _ attempt: Int, _ state: PendingAsk.State) {
    guard isCurrent(requestID, attempt) else { return }
    pending[id: requestID]?.state = state
  }

  private func forget(_ requestID: String) {
    runs.removeValue(forKey: requestID)?.task.cancel()
    pending.remove(id: requestID)
    questions[requestID] = nil
    recordings[requestID] = nil
  }

  /// An error leaves the answer stage-1 only for this question; the next one asks again.
  private func supportsRelays(_ question: InstantQuestion) async -> Bool {
    if let isSupported = relaySupport[question.storeID] { return isSupported }
    guard let isSupported = try? await questionClient.supportsRelays(question.sessionID) else { return false }
    relaySupport[question.storeID] = isSupported
    return isSupported
  }

  /// Runs once the exchange carrying the relay is recorded, whether its ack or its event comes first.
  private func startRelay(for requestID: String, questionID: String) {
    guard let question = questions[requestID], let request = recordings[requestID],
      case .recordExchange(_, _, let relay?) = request.verb, relayRuns[relay.relayID] == nil,
      let relayID = UUID(uuidString: relay.relayID), let chatSessionID = UUID(uuidString: relay.chatSessionID)
    else { return }
    relayRuns[relay.relayID] = RelayRun(
      storeID: question.storeID, sessionID: question.sessionID, questionID: questionID, chatSessionID: chatSessionID,
      folder: question.folder, source: question.source, earlier: question.earlier, request: question.text)
    track(question.sessionID) { await self.write(relayID) }
  }

  private func relayFolded(
    _ relay: QuestionRelay, storeID: String, sessionID: String, folder: String?, source: QuestionSource,
    earlier: [AskPrompt.Exchange], request: String, isReplaying: Bool
  ) {
    if relayRuns[relay.id] == nil {
      guard let chatSessionID = UUID(uuidString: relay.chatSessionID) else { return }
      relayRuns[relay.id] = RelayRun(
        storeID: storeID, sessionID: sessionID, questionID: relay.questionID, chatSessionID: chatSessionID,
        folder: folder, source: source, earlier: earlier, request: request, checksAfterReplay: true)
    }
    if relay.pickedUp != nil || relay.report != nil { relayRuns[relay.id]?.delivery = .pickedUp }
    if relay.isDone { relayRuns[relay.id]?.isDone = true }
    guard !isReplaying, let run = relayRuns[relay.id], run.checksAfterReplay, run.delivery == .pickedUp, !run.isDone,
      run.report == .idle, chat.tabs[id: run.chatSessionID]?.isWorking == false
    else { return }
    startCheck(relay.id)
  }

  /// The new run exists before its `sent` step is sent, so a step whose retries run out is kept
  /// for reconnect under the same request id.
  private func sendAgain(_ run: RelayRun, from relayID: String, to tabID: UUID) async {
    let newRelayID = uuid()
    let newKey = newRelayID.uuidString.lowercased()
    relayRuns[newKey] = RelayRun(
      storeID: run.storeID, sessionID: run.sessionID, questionID: run.questionID, chatSessionID: tabID,
      folder: run.folder, source: run.source, earlier: run.earlier, request: run.request)
    let isRecorded = await send(
      QuestionRelayUpdateRequest(
        sessionID: run.sessionID, requestID: uuid().uuidString.lowercased(), questionID: run.questionID,
        relayID: newKey, update: .sent(chatSessionID: tabID.uuidString.lowercased())))
    guard isRecorded else {
      if relayRuns[newKey]?.unrecorded.isEmpty == true { relayRuns[newKey] = nil }
      return
    }
    guard !Task.isCancelled, relayRuns[newKey] != nil else { return }
    relayRuns[relayID]?.isSentAgain = true
    await write(newRelayID)
  }

  private func write(_ relayID: UUID) async {
    let key = relayID.uuidString.lowercased()
    guard let run = relayRuns[key], let tab = chat.tabs[id: run.chatSessionID],
      let text = AskPrompt.relayMessage(source: run.source, earlier: run.earlier, words: run.request)
    else { return notDelivered(key) }
    relayRuns[key]?.delivery = .writing
    do {
      try await tab.relay(AskRelayMessage(relayID: relayID, text: text, label: Self.relayLabel(run.source)))
    } catch {
      return notDelivered(key)
    }
    if relayRuns[key]?.delivery == .writing { relayRuns[key]?.delivery = .waitingForEcho }
  }

  /// Published at once, so the turn end that follows a pickup already sees it.
  private func relayDelivered(_ delivery: RelayDelivery) {
    switch delivery {
    case .pickedUp(let relayID):
      let key = relayID.uuidString.lowercased()
      guard let run = relayRuns[key], run.delivery != .pickedUp else { return }
      relayRuns[key]?.delivery = .pickedUp
      recordUpdate(key, .pickedUp)
    case .exitedUnread(let relayID):
      notDelivered(relayID.uuidString.lowercased())
    }
  }

  private func notDelivered(_ relayID: String) {
    guard let run = relayRuns[relayID], run.delivery != .pickedUp, run.delivery != .exitedUnread else { return }
    relayRuns[relayID]?.delivery = .exitedUnread
    recordUpdate(relayID, .notDelivered)
  }

  /// Only a turn that ends after the pickup can have done the work, so earlier ones start nothing.
  private func tabTurnEnded(_ tabID: UUID) {
    for (relayID, run) in relayRuns where run.chatSessionID == tabID && run.delivery == .pickedUp && !run.isDone {
      switch run.report {
      case .idle where run.sessionID == replayingSessionID: relayRuns[relayID]?.checksAfterReplay = true
      case .idle: startCheck(relayID)
      case .checking: relayRuns[relayID]?.report = .checking(rerun: true)
      }
    }
  }

  @discardableResult
  private func startCheck(_ relayID: String) -> Task<Void, Never>? {
    guard !isQuitting, let run = relayRuns[relayID] else { return nil }
    relayRuns[relayID]?.report = .checking(rerun: false)
    relayRuns[relayID]?.checksAfterReplay = false
    return track(run.sessionID) { await self.check(relayID) }
  }

  /// Asks a copy of the chat whether it made the change, then records its answer. It is done only
  /// once the daemon has recorded a done report; a turn end during the check runs one more.
  private func check(_ relayID: String) async {
    guard let run = relayRuns[relayID] else { return }
    var result: AskForkResult?
    var cause: String?
    if let tab = chat.tabs[id: run.chatSessionID]?.record {
      do {
        let environment = try await agentEnvironment.resolve()
        do throws(AskForkError) {
          result = try await askFork.run(
            AskForkRequest(
              parentSessionID: tab.id,
              folder: tab.folder,
              environment: environment,
              model: tab.model,
              effort: tab.effort,
              prompt: AskPrompt.report(source: run.source, earlier: run.earlier, request: run.request),
              kind: .report
            )
          )
        } catch {
          cause = Self.detail(error)
        }
      } catch {
        cause = AskFailure.sentence(for: error)
      }
    } else {
      cause = "The chat for this change is closed."
    }
    var isRecorded = false
    if !Task.isCancelled, case .report(let reply, let outcome) = result,
      let request = updateRequest(relayID, .reported(outcome, text: reply))
    {
      relayRuns[relayID]?.lastReportRequestID = request.requestID
      isRecorded = await send(request)
      if isRecorded { recorded(request) } else { cause = "The daemon didn't record the check." }
    } else if cause == nil {
      cause = "Claude Code's reply had no report."
    }
    guard !Task.isCancelled, case .checking(let rerun) = relayRuns[relayID]?.report else { return }
    relayRuns[relayID]?.report = .idle
    relayRuns[relayID]?.checkFailedAtMs = isRecorded ? nil : Int64(now.timeIntervalSince1970 * 1000)
    relayRuns[relayID]?.checkFailure = isRecorded ? nil : cause
    if rerun, relayRuns[relayID]?.isDone == false { startCheck(relayID) }
  }

  private func recorded(_ request: QuestionRelayUpdateRequest) {
    guard case .reported(let outcome, _) = request.update else { return }
    if outcome == .done { relayRuns[request.relayID]?.isDone = true }
    if relayRuns[request.relayID]?.lastReportRequestID == request.requestID {
      relayRuns[request.relayID]?.checkFailedAtMs = nil
      relayRuns[request.relayID]?.checkFailure = nil
    }
  }

  /// Each step is recorded on its own, so one that fails never holds back the next.
  private func recordUpdate(_ relayID: String, _ update: RelayUpdate) {
    guard !isQuitting, let request = updateRequest(relayID, update) else { return }
    track(request.sessionID) { await self.send(request) }
  }

  private func updateRequest(_ relayID: String, _ update: RelayUpdate) -> QuestionRelayUpdateRequest? {
    guard let run = relayRuns[relayID] else { return nil }
    return QuestionRelayUpdateRequest(
      sessionID: run.sessionID, requestID: uuid().uuidString.lowercased(), questionID: run.questionID,
      relayID: relayID, update: update)
  }

  /// Anything but a refusal may have been recorded, so it is retried with the identical body and
  /// kept for the next connection once the retries run out. A refusal is dropped.
  @discardableResult
  private func send(_ request: QuestionRelayUpdateRequest) async -> Bool {
    for remaining in (0..<Self.recordingAttempts).reversed() {
      do {
        _ = try await questionClient.updateRelay(request)
        return true
      } catch QuestionError.rejected(let code, _) where code != "STORAGE_UNAVAILABLE" {
        return false
      } catch {
        guard remaining > 0, (try? await clock.sleep(for: Self.recordingRetryDelay)) != nil else {
          relayRuns[request.relayID]?.unrecorded.append(request)
          return false
        }
      }
    }
    return false
  }

  @discardableResult
  private func track(_ sessionID: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
    let id = nextRelayTaskID
    nextRelayTaskID += 1
    let task = Task {
      await work()
      self.relayTasks[id] = nil
    }
    relayTasks[id] = RelayTask(sessionID: sessionID, task: task)
    return task
  }

  private static func relayLabel(_ source: QuestionSource) -> String {
    "From Ask · \(source.context.path):\(source.context.lineStart)-\(source.context.lineEnd)"
  }

  private static func failure(_ error: AskForkError) -> AskFailure {
    switch error {
    case .timedOut: .noReply
    case .unavailable(let detail): AskFailure(kind: .unavailable, detail: detail)
    case .badReply(let detail): AskFailure(kind: .badReply, detail: detail)
    }
  }

  private static func detail(_ error: AskForkError) -> String {
    switch error {
    case .timedOut: "Claude Code didn't answer within 120 seconds."
    case .unavailable(let detail), .badReply(let detail): detail
    }
  }
}
