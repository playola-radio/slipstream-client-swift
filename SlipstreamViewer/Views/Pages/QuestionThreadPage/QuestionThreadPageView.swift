import SlipstreamCore
import SwiftUI

struct QuestionThreadPageView: View {
  @Bindable var model: QuestionThreadPageModel
  var dismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Reply.gap) {
      HStack(spacing: DesignTokens.Reply.gap) {
        Text(model.title).font(DesignTokens.Reply.titleFont).foregroundStyle(DesignTokens.Reply.titleColor)
        Spacer()
        Button(action: dismiss) {
          Image("X").resizable().frame(width: DesignTokens.Reply.iconSize, height: DesignTokens.Reply.iconSize)
            .foregroundStyle(DesignTokens.Reply.closeColor)
        }
        .accessibilityLabel(model.closeText)
      }
      ForEach(model.thread.turns, id: \.questionID) { turn in
        Text(turn.text)
          .font(DesignTokens.Reply.questionFont)
          .foregroundStyle(DesignTokens.Reply.questionColor)
          .lineSpacing(DesignTokens.Reply.questionLineSpacing)
          .fixedSize(horizontal: false, vertical: true)
        if let answer = turn.answer {
          VStack(alignment: .leading, spacing: DesignTokens.Reply.answerGap) {
            Text(model.agentText(answer))
              .font(DesignTokens.Reply.agentFont)
              .foregroundStyle(DesignTokens.Reply.agentColor)
            Text(model.answerText(answer))
              .font(DesignTokens.Reply.answerFont)
              .foregroundStyle(DesignTokens.Reply.answerColor)
              .lineSpacing(DesignTokens.Reply.answerLineSpacing)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .background(alignment: .top) {
                Color.clear.frame(height: 1).onScrollVisibilityChange(threshold: 0.01) { isVisible in
                  if isVisible { model.answerDisplayed(answer.seq) }
                }
              }
          }
        } else {
          Text(model.waitingText)
            .font(DesignTokens.Reply.agentFont)
            .foregroundStyle(DesignTokens.Reply.waitingColor)
        }
      }
      TextField(model.followUpPlaceholder, text: $model.draft, axis: .vertical)
        .textFieldStyle(.plain)
        .font(DesignTokens.Reply.draftFont)
        .foregroundStyle(DesignTokens.Reply.draftColor)
        .lineSpacing(DesignTokens.Reply.draftLineSpacing)
        .disabled(model.isFollowUpDisabled)
        .padding(DesignTokens.Reply.inputPadding)
        .frame(height: DesignTokens.Reply.inputHeight, alignment: .topLeading)
        .background(DesignTokens.Reply.inputFill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.inputRadius))
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.Reply.inputRadius)
            .strokeBorder(DesignTokens.Reply.inputStroke, lineWidth: DesignTokens.Reply.strokeWidth)
        }
      HStack(spacing: DesignTokens.Reply.actionGap) {
        Text(model.sourceText)
          .font(DesignTokens.Reply.sourceFont)
          .foregroundStyle(DesignTokens.Reply.sourceColor)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
      }
    }
    .buttonStyle(.plain)
    .padding(DesignTokens.Reply.padding)
    .background(DesignTokens.Reply.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Reply.radius)
        .strokeBorder(DesignTokens.Reply.stroke, lineWidth: DesignTokens.Reply.strokeWidth)
    }
    .onExitCommand(perform: dismiss)
  }
}
