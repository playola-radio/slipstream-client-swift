import CustomDump
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
        blocks: [.toolResult(toolUseID: "t1", text: SlipstreamInstruction.linked.block, isError: false)])
    ]

    #expect(!SlipstreamInstruction.linked.wasSent(in: lines))
  }
}
