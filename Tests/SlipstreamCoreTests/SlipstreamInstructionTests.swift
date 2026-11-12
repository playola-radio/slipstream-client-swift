import SlipstreamCore
import Testing

struct SlipstreamInstructionTests {
  @Test func prefixedPutsTheBlocksBeforeTheMessage() {
    let text = SlipstreamInstruction.prefixed("Fix the bug", with: [.start])

    #expect(text == SlipstreamInstruction.start.block + "\n\nFix the bug")
  }

  @Test func prefixedWithNothingIsTheMessage() {
    #expect(SlipstreamInstruction.prefixed("Fix the bug", with: []) == "Fix the bug")
  }

  @Test func strippedRemovesEveryLeadingBlock() {
    let text = SlipstreamInstruction.prefixed("Fix the bug", with: [.start, .linked])

    #expect(SlipstreamInstruction.stripped(text) == "Fix the bug")
  }

  @Test func strippedKeepsAMessageWithoutABlock() {
    #expect(SlipstreamInstruction.stripped("Fix the bug") == "Fix the bug")
  }

  @Test func strippedKeepsABlockTheUserQuotedMidMessage() {
    let text = "Why did you get\n\n" + SlipstreamInstruction.linked.block

    #expect(SlipstreamInstruction.stripped(text) == text)
  }

  @Test func strippedKeepsAnAlteredBlock() {
    let text = "<slipstream_instruction>\nSomething else\n</slipstream_instruction>\n\nFix the bug"

    #expect(SlipstreamInstruction.stripped(text) == text)
  }

  @Test func wasSentFindsTheBlockInAPrompt() {
    let lines: [AgentLine] = [
      .user(uuid: "u1", timestamp: nil, isPrompt: true, blocks: [.text(SlipstreamInstruction.prefixed("Go", with: [.linked]))])
    ]

    #expect(SlipstreamInstruction.linked.wasSent(in: lines))
    #expect(!SlipstreamInstruction.start.wasSent(in: lines))
  }

  @Test func wasSentFindsTheBlockInAQueuedMessage() {
    let lines: [AgentLine] = [.queuedMessage(uuid: "q1", text: SlipstreamInstruction.prefixed("Go", with: [.linked]))]

    #expect(SlipstreamInstruction.linked.wasSent(in: lines))
  }

  @Test func wasSentIgnoresToolResults() {
    let lines: [AgentLine] = [
      .user(
        uuid: "u1", timestamp: nil, isPrompt: false,
        blocks: [.toolResult(toolUseID: "t1", text: SlipstreamInstruction.prefixed("Go", with: [.linked]), isError: false)])
    ]

    #expect(!SlipstreamInstruction.linked.wasSent(in: lines))
  }

  static let earlierLinkedMessage = """
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

    Fix the bug
    """

  @Test func linkedBlockSaysTheWorkspaceMayAlreadyBeNamed() {
    #expect(
      SlipstreamInstruction.linked.block.contains(
        "If this workspace still needs a name, call slipstream_name_workspace with a concise 2-5 word name for what the work is about."
      ))
  }

  @Test func strippedRemovesTheEarlierLinkedBlock() {
    #expect(SlipstreamInstruction.stripped(Self.earlierLinkedMessage) == "Fix the bug")
  }

  @Test func wasSentFindsTheEarlierLinkedBlock() {
    let lines: [AgentLine] = [.user(uuid: "u1", timestamp: nil, isPrompt: true, blocks: [.text(Self.earlierLinkedMessage)])]

    #expect(SlipstreamInstruction.linked.wasSent(in: lines))
  }
}
