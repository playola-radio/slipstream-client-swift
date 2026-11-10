import CryptoKit
import Foundation
import SlipstreamCore

/// Builds a few chats live in a scratch repo, asks each case's question through the same prompt,
/// arguments and output reader the app uses, and checks the replies. Needs a throwaway
/// `CLAUDE_CONFIG_DIR`; it never touches the real one.

struct EvalCase {
  /// The last two are built on first use, after the cases before them, since one edits the repo.
  enum Chat { case finished, unfinishedToolCall, couldntMakeTheChange, madeTheChange }
  /// Stage 1 answers, stage 2 answers that flag change requests, or a report after a relay.
  enum Ask { case stage1, stage2, report }
  enum Check {
    case keepsInternalsHidden, neverSaysInterrupted, pointsToTheChat
    case mentions(String)
    case isChangeRequest(Bool)
    case outcome(ReportOutcome)
  }

  let name: String
  let chat: Chat
  var ask = Ask.stage1
  let earlier: [AskPrompt.Exchange]
  /// The user's message, or for a report the change request that was relayed.
  let words: String
  let checks: [Check]
}

let appSource = """
  def greet(name):
      return "Hello, " + name

  def shout(name):
      return greet(name).upper()

  def whisper(name):
      return greet(name).lower()

  """

let selection = QuestionSource(
  context: QuestionContext(changeSeq: "1", path: "app.py", snapshotSHA256: sha256(Data(appSource.utf8)), lineStart: 4, lineEnd: 5),
  selectedText: "def shout(name):\n    return greet(name).upper()")

let couldntMakeRequest = "Add a docstring to shout."
let madeRequest = "Rename whisper to murmur."

let cases = [
  EvalCase(
    name: "plain question", chat: .finished, earlier: [],
    words: "Why does shout call greet instead of building the string itself?", checks: [.keepsInternalsHidden]),
  EvalCase(
    name: "follow-up uses the thread", chat: .finished,
    earlier: [.init(question: "What does shout return?", answer: "The greeting in upper case, like HELLO, BOB.")],
    words: "And whisper?", checks: [.keepsInternalsHidden, .mentions("lower")]),
  EvalCase(
    name: "change request points to the chat", chat: .finished, earlier: [],
    words: "Rename shout to yell.", checks: [.keepsInternalsHidden, .pointsToTheChat]),
  EvalCase(
    name: "yes after an offer is a change request", chat: .finished,
    earlier: [
      .init(
        question: "Does greet handle an empty name?",
        answer: "No. It would return \"Hello, \". Want me to add a guard for empty names?")
    ],
    words: "yes", checks: [.keepsInternalsHidden, .pointsToTheChat]),
  EvalCase(
    name: "unfinished tool call isn't called interrupted", chat: .unfinishedToolCall, earlier: [],
    words: "Did the tests pass?", checks: [.keepsInternalsHidden, .neverSaysInterrupted]),
  EvalCase(
    name: "stage 2: a question isn't a change request", chat: .finished, ask: .stage2, earlier: [],
    words: "Why does shout call greet instead of building the string itself?",
    checks: [.keepsInternalsHidden, .isChangeRequest(false)]),
  EvalCase(
    name: "stage 2: a change request is flagged", chat: .finished, ask: .stage2, earlier: [],
    words: "Rename shout to yell.", checks: [.keepsInternalsHidden, .isChangeRequest(true)]),
  EvalCase(
    name: "stage 2: yes after an offer is a change request", chat: .finished, ask: .stage2,
    earlier: [
      .init(
        question: "Does greet handle an empty name?",
        answer: "No. It would return \"Hello, \". Want me to add a guard for empty names?")
    ],
    words: "yes", checks: [.keepsInternalsHidden, .isChangeRequest(true)]),
  EvalCase(
    name: "report: a change the chat couldn't make isn't done", chat: .couldntMakeTheChange, ask: .report,
    earlier: [], words: couldntMakeRequest, checks: [.keepsInternalsHidden, .outcome(.notDoneYet)]),
  EvalCase(
    name: "report: a change in the repo is done", chat: .madeTheChange, ask: .report, earlier: [],
    words: madeRequest, checks: [.keepsInternalsHidden, .outcome(.done)]),
]

let environment = ProcessInfo.processInfo.environment
let model = environment["ASK_EVALS_MODEL"] ?? "claude-opus-5-5"
let effort = environment["ASK_EVALS_EFFORT"] ?? "medium"

guard let configPath = environment["CLAUDE_CONFIG_DIR"], !configPath.isEmpty,
  resolved(configPath) != resolved(NSHomeDirectory() + "/.claude")
else { fail("ask-evals needs a throwaway CLAUDE_CONFIG_DIR, never ~/.claude.") }
guard let claude = claudeExecutable() else { fail("claude isn't on PATH; set CLAUDE_PATH.") }

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ask-evals-\(UUID().uuidString.lowercased())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
try Data(appSource.utf8).write(to: scratch.appendingPathComponent("app.py"))
try Data("from app import shout\n\ndef test_shout():\n    assert shout(\"bob\") == \"HELLO, BOB\"\n".utf8)
  .write(to: scratch.appendingPathComponent("test_app.py"))
let testScript = scratch.appendingPathComponent("run_tests.sh")
try Data("#!/bin/sh\npython3 -c 'import time; time.sleep(45)'\npython3 -m pytest -q\n".utf8).write(to: testScript)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: testScript.path)

print("ask-evals · claude \(claudeVersion()) · \(model) · effort \(effort)")

let finished = UUID()
guard chatTurn(.new(finished), "Read app.py and tell me in one sentence what it does.") else { fail("setup: the chat didn't answer.") }
let unfinished = UUID()
guard chatTurn(.new(unfinished), "Read app.py and tell me in one sentence what it does."),
  !chatTurn(.resume(unfinished), "Run ./run_tests.sh in the foreground, not as a background task, and tell me the result.", killAtToolCall: true),
  hasUnfinishedToolCall(transcript(unfinished))
else { fail("setup: couldn't leave a tool call unfinished.") }
print("setup  two chats in a scratch repo; one has an unfinished tool call")
var chats: [EvalCase.Chat: UUID] = [.finished: finished, .unfinishedToolCall: unfinished]

var passed = 0
for evalCase in cases {
  let parent = chats[evalCase.chat] ?? relayChat(evalCase.chat)
  chats[evalCase.chat] = parent
  let before = (transcriptHash(parent), sha256(try Data(contentsOf: scratch.appendingPathComponent("app.py"))))
  let outcome = ask(parent, evalCase)
  let after = (transcriptHash(parent), sha256(try Data(contentsOf: scratch.appendingPathComponent("app.py"))))
  var problems: [String] = []
  if before != after { problems.append("the chat or the repo changed") }
  switch outcome {
  case .success(let result):
    problems += evalCase.checks.compactMap { problem(result, $0) }
    report(evalCase.name, problems, reply: result.reply)
  case .failure(let error):
    report(evalCase.name, problems + ["no reply (\(error))"], reply: nil)
  }
  if problems.isEmpty, case .success = outcome { passed += 1 }
}
print("\(passed)/\(cases.count) passed")
try? FileManager.default.removeItem(at: scratch)
if passed != cases.count { exit(1) }

// MARK: - Checks

func problem(_ result: AskForkResult, _ check: EvalCase.Check) -> String? {
  let reply = result.reply
  switch check {
  case .keepsInternalsHidden:
    // "Copy" is ordinary in answers about code, so only a copy of the chat itself counts.
    let patterns = [
      #"\b(fork(ed|s)?|read[- ]?only|slipstream)\b"#,
      #"\bcop(y|ies)\W+(\w+\W+){0,3}(chat|conversation|session)s?\b"#,
      #"\b(I'm|I am)\s+(just\s+)?an?\s+(\w+\s+)?copy\b"#,
    ]
    return patterns.lazy.compactMap { first($0, in: reply) }.first.map { "mentions \"\($0)\"" }
  case .neverSaysInterrupted:
    return first(#"interrupt\w*"#, in: reply).map { "calls the tool call \"\($0)\"" }
  case .pointsToTheChat:
    if let onIt = first(#"\bon it\b"#, in: reply) { return "says \"\(onIt)\"" }
    return reply.localizedCaseInsensitiveContains("chat") ? nil : "doesn't point to the chat"
  case .mentions(let word):
    return reply.localizedCaseInsensitiveContains(word) ? nil : "doesn't mention \"\(word)\""
  case .isChangeRequest(let expected):
    guard case .answer(_, _, let isChangeRequest) = result, isChangeRequest == expected else {
      return expected ? "isn't flagged as a change request" : "is flagged as a change request"
    }
    return nil
  case .outcome(let expected):
    guard case .report(_, let outcome) = result, outcome == expected else { return "isn't \(expected.rawValue)" }
    return nil
  }
}

extension AskForkResult {
  var reply: String {
    switch self {
    case .answer(_, let reply, _), .report(let reply, _): reply
    }
  }
}

func first(_ pattern: String, in text: String) -> String? {
  guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
  return String(text[range])
}

func report(_ name: String, _ problems: [String], reply: String?) {
  print("\(problems.isEmpty ? "PASS" : "FAIL")  \(name)\(problems.isEmpty ? "" : " — " + problems.joined(separator: "; "))")
  if let reply { print("      " + reply.replacingOccurrences(of: "\n", with: "\n      ")) }
}

// MARK: - Claude

func ask(_ parent: UUID, _ evalCase: EvalCase) -> Result<AskForkResult, AskForkError> {
  let (kind, prompt, schema) =
    switch evalCase.ask {
    case .stage1, .stage2:
      (
        AskForkKind.answer(allowsChangeRequests: evalCase.ask == .stage2),
        AskPrompt.answer(
          source: selection, earlier: evalCase.earlier, words: evalCase.words,
          allowsChangeRequests: evalCase.ask == .stage2),
        AskPrompt.answerSchema(allowsChangeRequests: evalCase.ask == .stage2)
      )
    case .report:
      (
        AskForkKind.report, AskPrompt.report(source: selection, earlier: evalCase.earlier, request: evalCase.words),
        AskPrompt.reportSchema
      )
    }
  let arguments = ClaudeInvocation.forkArguments(parentSessionID: parent, model: model, effort: effort, schema: schema)
  var output = ForkOutput(kind: kind)
  var result: Result<AskForkResult, AskForkError>?
  let status = run(arguments, input: prompt, timeLimit: 120) { line in
    do throws(AskForkError) {
      guard let answer = try output.read(line) else { return false }
      result = .success(answer)
    } catch {
      result = .failure(error)
    }
    return true
  }
  if let result { return result }
  return .failure(status == nil ? .timedOut : .unavailable("Claude Code ended without an answer."))
}

/// A chat that was sent its case's change request the way the app relays it. One may edit files;
/// the other can only read them, so it can't make the change.
func relayChat(_ chat: EvalCase.Chat) -> UUID {
  let canEdit = chat == .madeTheChange
  let request = canEdit ? madeRequest : couldntMakeRequest
  let id = UUID()
  let appFile = scratch.appendingPathComponent("app.py")
  let before = try? Data(contentsOf: appFile)
  guard let message = AskPrompt.relayMessage(source: selection, earlier: [], words: request),
    chatTurn(.new(id), message, allowedTools: canEdit ? "Read,Grep,Glob,Edit" : "Read,Grep,Glob"),
    (try? Data(contentsOf: appFile) != before) == canEdit
  else { fail("setup: the chat \(canEdit ? "didn't make" : "made") the change \"\(request)\".") }
  print("setup  a chat that \(canEdit ? "made" : "couldn't make") the change \"\(request)\"")
  return id
}

/// True when the turn ran to its result; false when it was killed at its first tool call.
func chatTurn(
  _ session: ClaudeSessionStart, _ text: String, allowedTools: String = "Read,Grep,Glob,Bash", killAtToolCall: Bool = false
) -> Bool {
  let sessionArgument =
    switch session {
    case .new(let id): "--session-id=\(id.uuidString.lowercased())"
    case .resume(let id): "--resume=\(id.uuidString.lowercased())"
    }
  var finished = false
  run(
    ["-p", sessionArgument, "--model=\(model)", "--effort=low", "--output-format", "stream-json", "--verbose",
     "--allowedTools", allowedTools],
    input: text, timeLimit: 300
  ) { line in
    guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: line) else { return false }
    if object["type"] == .string("result") {
      finished = object["is_error"] != .bool(true)
      if !finished, case .string(let message)? = object["result"] { FileHandle.standardError.write(Data((message + "\n").utf8)) }
      return true
    }
    guard killAtToolCall, object["type"] == .string("assistant"), line.contains(Data(#""type":"tool_use""#.utf8))
    else { return false }
    // The transcript records the tool call a moment after it streams; killing sooner loses it.
    Thread.sleep(forTimeInterval: 3)
    return true
  }
  return finished
}

/// Feeds `input` on stdin and hands each stdout line to `stop`; the process is killed once `stop`
/// returns true. Returns the exit status, or nil when the time limit killed it.
@discardableResult
func run(_ arguments: [String], input: String, timeLimit: TimeInterval, stop: (Data) -> Bool) -> Int32? {
  let process = Process()
  process.executableURL = claude
  process.arguments = arguments
  process.currentDirectoryURL = scratch
  let stdin = Pipe()
  let stdout = Pipe()
  process.standardInput = stdin
  process.standardOutput = stdout
  process.standardError = FileHandle.standardError
  do { try process.run() } catch { fail("couldn't launch claude: \(error)") }
  stdin.fileHandleForWriting.write(Data(input.utf8))
  try? stdin.fileHandleForWriting.close()
  let deadline = Date().addingTimeInterval(timeLimit)
  let watchdog = DispatchWorkItem { [process] in if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
  DispatchQueue.global().asyncAfter(deadline: .now() + timeLimit, execute: watchdog)
  var framer = JSONLineFramer()
  reading: while true {
    let chunk = stdout.fileHandleForReading.availableData
    if chunk.isEmpty { break }
    for case .line(let line) in framer.append(chunk) where stop(line) {
      kill(process.processIdentifier, SIGKILL)
      break reading
    }
  }
  process.waitUntilExit()
  watchdog.cancel()
  return Date() >= deadline ? nil : process.terminationStatus
}

func transcript(_ id: UUID) -> URL? {
  let projects = URL(fileURLWithPath: configPath).appendingPathComponent("projects")
  let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
  return folders.map { $0.appendingPathComponent("\(id.uuidString.lowercased()).jsonl") }
    .first { FileManager.default.fileExists(atPath: $0.path) }
}

func transcriptHash(_ id: UUID) -> String? {
  transcript(id).flatMap { try? Data(contentsOf: $0) }.map(sha256)
}

func hasUnfinishedToolCall(_ url: URL?) -> Bool {
  guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
  let calls = matches(#""type":"tool_use","id":"([^"]+)""#, in: text)
  let results = Set(matches(#""tool_use_id":"([^"]+)""#, in: text))
  return calls.contains { !results.contains($0) }
}

func matches(_ pattern: String, in text: String) -> [String] {
  let expression = try! NSRegularExpression(pattern: pattern)
  return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
    Range(match.range(at: 1), in: text).map { String(text[$0]) }
  }
}

func claudeExecutable() -> URL? {
  if let path = environment["CLAUDE_PATH"] { return URL(fileURLWithPath: path) }
  return (environment["PATH"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude") }
    .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

func claudeVersion() -> String {
  var version = "unknown"
  let process = Process()
  let stdout = Pipe()
  process.executableURL = claude
  process.arguments = ["--version"]
  process.standardOutput = stdout
  if (try? process.run()) != nil {
    version = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      .split(separator: " ").first.map(String.init) ?? version
    process.waitUntilExit()
  }
  return version
}

// MARK: - Helpers

func resolved(_ path: String) -> String {
  URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
}

func sha256(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(2)
}
