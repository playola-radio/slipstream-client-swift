/// Hidden guidance the app puts in front of a chat's message, the way Conductor does. The chat
/// shows the message without it.
public enum SlipstreamInstruction: CaseIterable, Equatable, Sendable {
  /// Before the first message of a new chat. The chat isn't linked yet, so its tools don't work.
  case start
  /// Before the first message a linked chat reads.
  case linked

  public var block: String {
    switch self {
    case .start:
      """
      <slipstream_instruction>
      You are working inside Slipstream, a Mac app that shows the user a live feed of the file changes \
      in this workspace. Slipstream's tools start working after your first reply, once this chat is \
      linked to the workspace.
      </slipstream_instruction>
      """
    case .linked:
      """
      <slipstream_instruction>
      This chat is now linked to Slipstream. Load its tools with ToolSearch \
      ("select:mcp__slipstream__slipstream_name_workspace,mcp__slipstream__slipstream_begin_task,\
      mcp__slipstream__slipstream_answer_question"), then:
      - If you haven't named this workspace yet, call slipstream_name_workspace with a 2-5 word name \
      for what the work is about.
      - Before changing files for a new task, call slipstream_begin_task with a short title.
      Answer any Slipstream setup check it sends you. If a Slipstream tool returns an error, carry on \
      with the work.
      </slipstream_instruction>
      """
    }
  }

  public static func prefixed(_ text: String, with instructions: [SlipstreamInstruction]) -> String {
    instructions.map { $0.block + separator }.joined() + text
  }

  /// Only whole blocks at the very start are removed, so a block quoted later stays.
  public static func stripped(_ text: String) -> String {
    String(leading(text).rest)
  }

  public func wasSent(in lines: [AgentLine]) -> Bool {
    lines.contains { line in
      switch line {
      case .user(_, _, true, let blocks):
        blocks.contains { if case .text(let text) = $0 { leads(text) } else { false } }
      case .queuedMessage(_, let text):
        leads(text)
      default:
        false
      }
    }
  }

  private func leads(_ text: String) -> Bool {
    Self.leading(text).instructions.contains(self)
  }

  private static func leading(_ text: String) -> (instructions: [SlipstreamInstruction], rest: Substring) {
    var instructions: [SlipstreamInstruction] = []
    var rest = Substring(text)
    while let instruction = allCases.first(where: { rest.hasPrefix($0.block + separator) }) {
      instructions.append(instruction)
      rest = rest.dropFirst(instruction.block.count + separator.count)
    }
    return (instructions, rest)
  }

  private static let separator = "\n\n"
}
