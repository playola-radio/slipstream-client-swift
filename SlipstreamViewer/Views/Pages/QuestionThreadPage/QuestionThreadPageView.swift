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
              .background(alignment: .bottom) {
                Color.clear.frame(height: 1).onScrollVisibilityChange(threshold: 1) { isVisible in
                  if isVisible { model.answerDisplayed(answer.seq) }
                }
              }
          }
        } else {
          Text(model.unansweredText(turn))
            .font(DesignTokens.Reply.agentFont)
            .foregroundStyle(DesignTokens.Reply.waitingColor)
        }
        if let progress = model.progress(turn) {
          RelayProgressView(model: model, progress: progress)
        }
      }
      if let pending = model.pendingTurn {
        Text(pending.text)
          .font(DesignTokens.Reply.questionFont)
          .foregroundStyle(DesignTokens.Reply.questionColor)
          .lineSpacing(DesignTokens.Reply.questionLineSpacing)
          .fixedSize(horizontal: false, vertical: true)
        if let reason = model.pendingFailureText {
          VStack(alignment: .leading, spacing: DesignTokens.Reply.progressGap) {
            HStack(spacing: DesignTokens.Reply.progressRowGap) {
              Image("X").resizable()
                .frame(width: DesignTokens.Reply.progressIconSize, height: DesignTokens.Reply.progressIconSize)
                .foregroundStyle(DesignTokens.Reply.failureColor)
              Text(model.couldntAnswerText)
                .font(DesignTokens.Reply.agentFont)
                .foregroundStyle(DesignTokens.Reply.failureColor)
              Text(reason)
                .font(DesignTokens.Reply.agentFont)
                .foregroundStyle(DesignTokens.Reply.failureDetailColor)
            }
            if let detail = model.pendingFailureDetail {
              Text(detail)
                .font(DesignTokens.Reply.agentFont)
                .foregroundStyle(DesignTokens.Reply.failureDetailColor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            }
            Button(action: model.tryAgainTapped) {
              Text(model.tryAgainText)
                .font(DesignTokens.Reply.tryAgainFont)
                .foregroundStyle(DesignTokens.Reply.tryAgainText)
                .padding(.vertical, DesignTokens.Reply.tryAgainVerticalPadding)
                .padding(.horizontal, DesignTokens.Reply.tryAgainHorizontalPadding)
                .background(DesignTokens.Reply.tryAgainFill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.tryAgainRadius))
                .overlay {
                  RoundedRectangle(cornerRadius: DesignTokens.Reply.tryAgainRadius)
                    .strokeBorder(DesignTokens.Reply.tryAgainStroke, lineWidth: DesignTokens.Reply.strokeWidth)
                }
            }
            .padding(DesignTokens.Reply.progressActionsPadding)
          }
          .padding(DesignTokens.Reply.progressPadding)
          .overlay(alignment: .leading) {
            DesignTokens.Reply.progressStroke.frame(width: DesignTokens.Reply.progressStrokeWidth)
          }
        } else {
          HStack(spacing: DesignTokens.Reply.progressRowGap) {
            Image("LoaderCircle").resizable()
              .frame(width: DesignTokens.Reply.progressIconSize, height: DesignTokens.Reply.progressIconSize)
              .foregroundStyle(DesignTokens.Reply.agentColor)
            Text(model.thinkingText)
              .font(DesignTokens.Reply.agentFont)
              .foregroundStyle(DesignTokens.Reply.agentColor)
          }
        }
      }
      ScrollView {
        TextField(model.followUpPlaceholder, text: $model.draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(DesignTokens.Reply.draftFont)
          .foregroundStyle(DesignTokens.Reply.draftColor)
          .lineSpacing(DesignTokens.Reply.draftLineSpacing)
          .disabled(model.isFollowUpDisabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .padding(DesignTokens.Reply.inputPadding)
      .frame(minHeight: DesignTokens.Reply.inputHeight, maxHeight: DesignTokens.Reply.inputMaxHeight, alignment: .topLeading)
      .background(DesignTokens.Reply.inputFill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.inputRadius))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.Reply.inputRadius)
          .strokeBorder(DesignTokens.Reply.inputStroke, lineWidth: DesignTokens.Reply.strokeWidth)
      }
      if let notice = model.uncertaintyNotice {
        Text(notice)
          .font(DesignTokens.Reply.agentFont)
          .foregroundStyle(DesignTokens.Reply.noticeColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: DesignTokens.Reply.actionGap) {
        Text(model.sourceText)
          .font(DesignTokens.Reply.sourceFont)
          .foregroundStyle(DesignTokens.Reply.sourceColor)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        Button { Task { await model.sendReplyTapped() } } label: {
          Text(model.sendText)
            .font(DesignTokens.Reply.sendFont)
            .foregroundStyle(DesignTokens.Reply.sendText)
            .padding(.vertical, DesignTokens.Reply.sendVerticalPadding)
            .padding(.horizontal, DesignTokens.Reply.sendHorizontalPadding)
            .background(DesignTokens.Reply.sendFill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.sendRadius))
        }
        .disabled(!model.canSendReply)
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
    .alert(model.errorTitle, isPresented: $model.isErrorPresented) {
      Button(model.errorDismissText, role: .cancel) {}
    } message: {
      Text(model.errorMessage)
    }
  }
}

private struct RelayProgressView: View {
  let model: QuestionThreadPageModel
  let progress: RelayProgress

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Reply.progressGap) {
      ForEach(progress.lines, id: \.self) { line in
        let icon = DesignTokens.Reply.progressIcon(line.mark)
        HStack(spacing: DesignTokens.Reply.progressRowGap) {
          IconView(icon: icon)
          Text(line.label)
            .font(DesignTokens.Reply.agentFont)
            .foregroundStyle(icon.color)
          Text(line.detail)
            .font(DesignTokens.Reply.agentFont)
            .foregroundStyle(DesignTokens.Reply.progressDetailColor)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      if let failure = progress.failure {
        Text(failure)
          .font(DesignTokens.Reply.agentFont)
          .foregroundStyle(DesignTokens.Reply.failureDetailColor)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let action = progress.action {
        Button {
          Task {
            switch action {
            case .sendAgain: await model.sendAgainTapped(progress)
            case .checkAgain: await model.checkAgainTapped(progress)
            }
          }
        } label: {
          Text(model.actionText(action))
            .font(DesignTokens.Reply.tryAgainFont)
            .foregroundStyle(DesignTokens.Reply.tryAgainText)
            .padding(.vertical, DesignTokens.Reply.tryAgainVerticalPadding)
            .padding(.horizontal, DesignTokens.Reply.tryAgainHorizontalPadding)
            .background(DesignTokens.Reply.tryAgainFill, in: RoundedRectangle(cornerRadius: DesignTokens.Reply.tryAgainRadius))
            .overlay {
              RoundedRectangle(cornerRadius: DesignTokens.Reply.tryAgainRadius)
                .strokeBorder(DesignTokens.Reply.tryAgainStroke, lineWidth: DesignTokens.Reply.strokeWidth)
            }
        }
        .disabled(progress.isActionDisabled)
        .padding(DesignTokens.Reply.progressActionsPadding)
      }
    }
    .padding(DesignTokens.Reply.progressPadding)
    .overlay(alignment: .leading) {
      DesignTokens.Reply.progressStroke.frame(width: DesignTokens.Reply.progressStrokeWidth)
    }
    if let report = progress.report {
      VStack(alignment: .leading, spacing: DesignTokens.Reply.answerGap) {
        Text(report.agentText)
          .font(DesignTokens.Reply.agentFont)
          .foregroundStyle(DesignTokens.Reply.agentColor)
        Text(report.text)
          .font(DesignTokens.Reply.answerFont)
          .foregroundStyle(DesignTokens.Reply.answerColor)
          .lineSpacing(DesignTokens.Reply.answerLineSpacing)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
          .background(alignment: .bottom) {
            Color.clear.frame(height: 1).onScrollVisibilityChange(threshold: 1) { isVisible in
              if isVisible { model.answerDisplayed(report.seq) }
            }
          }
      }
      .id(report.seq)
    }
  }
}
