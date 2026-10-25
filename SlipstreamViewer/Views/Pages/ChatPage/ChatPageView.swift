import AppKit
import SlipstreamCore
import SwiftUI

struct ChatPageView<Leading: View>: View {
  @Bindable var model: ChatPageModel
  @ViewBuilder let leading: Leading

  var body: some View {
    VStack(spacing: 0) {
      tabStrip
      if let noWorkspaceText = model.noWorkspaceText {
        Text(noWorkspaceText)
          .font(DesignTokens.Chat.Transcript.noWorkspaceFont)
          .foregroundStyle(DesignTokens.Chat.Transcript.noWorkspaceColor)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let tab = model.selectedTab {
        TranscriptView(tab: tab, tryAgainText: model.tryAgainText) {
          Task { await model.tryAgainTapped() }
        }
        .id(tab.id)
      } else {
        Spacer()
      }
      messageBox
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.Chat.fill)
    .overlay(alignment: .leading) {
      Rectangle().fill(DesignTokens.Chat.stroke).frame(width: 1)
    }
  }

  private var tabStrip: some View {
    HStack(spacing: DesignTokens.Chat.TabStrip.gap) {
      leading
      ScrollView(.horizontal) {
        HStack(spacing: DesignTokens.Chat.TabStrip.gap) {
          ForEach(model.visibleTabs) { tab in
            ChatTabView(tab: tab, isSelected: model.isSelected(tab), isHovered: model.isHovered(tab),
              linkIcon: model.linkIcon(for: tab), linkHelpText: model.linkHelpText(for: tab),
              selected: { Task { await model.tabSelected(tab.id) } },
              closed: { Task { await model.closeTabTapped(tab.id) } },
              hovered: { model.tabHovered(tab.id, isHovering: $0) })
            .contextMenu {
              Button { Task { await model.connectTapped(tab.id) } } label: {
                Text(model.connectText)
                if let hint = model.connectHintText(for: tab) { Text(hint) }
              }
              .disabled(!model.isConnectEnabled(tab))
              Button(model.closeTabText) { Task { await model.closeTabTapped(tab.id) } }
            }
          }
          if model.showsNewTabButton {
            Button { Task { await model.newTabTapped() } } label: {
              IconView(icon: DesignTokens.Chat.NewTab.plus)
                .padding(.horizontal, DesignTokens.Chat.NewTab.horizontalPadding)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.newTabAccessibilityLabel)
          }
        }
      }
      .scrollIndicators(.hidden)
      if let outsideChatText = model.outsideChatText {
        HStack(spacing: DesignTokens.Chat.OutsideChat.gap) {
          IconView(icon: DesignTokens.Chat.OutsideChat.icon)
          Text(outsideChatText)
            .font(DesignTokens.Chat.OutsideChat.font)
            .foregroundStyle(DesignTokens.Chat.OutsideChat.color)
            .lineLimit(1)
        }
        .fixedSize()
      }
    }
    .padding(.horizontal, DesignTokens.Chat.TabStrip.horizontalPadding)
    .frame(height: DesignTokens.Chat.TabStrip.height)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.Chat.stroke).frame(height: 1)
    }
  }

  private var messageBox: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField(
        "", text: $model.draft,
        prompt: Text(model.placeholderText)
          .foregroundStyle(DesignTokens.Chat.MessageBox.placeholderColor(isEnabled: model.isMessageBoxEnabled)),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .font(DesignTokens.Chat.MessageBox.font)
      .foregroundStyle(DesignTokens.Chat.MessageBox.color)
      .onSubmit { Task { await model.sendTapped() } }
      .onKeyPress(.return, phases: .down) { press in
        guard press.modifiers.contains(.shift) else { return .ignored }
        NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
        return .handled
      }
      Spacer(minLength: 0)
      HStack {
        Menu {
          ForEach(ChatModelChoice.all, id: \.id) { choice in
            Button(choice.name) { Task { await model.modelSelected(choice.id) } }
          }
          Divider()
          ForEach(ChatEffort.allCases, id: \.self) { effort in
            Button(effort.name) { Task { await model.effortSelected(effort) } }
          }
        } label: {
          HStack(spacing: DesignTokens.Chat.AgentPicker.gap) {
            Text(model.pickerText)
              .font(DesignTokens.Chat.AgentPicker.font)
              .foregroundStyle(DesignTokens.Chat.AgentPicker.color)
            IconView(icon: DesignTokens.Chat.AgentPicker.chevron)
          }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.isPickerEnabled)
        Spacer()
        if model.showsStop {
          Button { Task { await model.stopTapped() } } label: {
            RoundedRectangle(cornerRadius: DesignTokens.Chat.Send.stopSquareRadius)
              .fill(DesignTokens.Chat.Send.stopSquareFill)
              .frame(width: DesignTokens.Chat.Send.stopSquareSize, height: DesignTokens.Chat.Send.stopSquareSize)
              .frame(width: DesignTokens.Chat.Send.size, height: DesignTokens.Chat.Send.size)
              .background(DesignTokens.Chat.Send.stopFill,
                in: RoundedRectangle(cornerRadius: DesignTokens.Chat.Send.radius))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.stopAccessibilityLabel)
        } else {
          Button { Task { await model.sendTapped() } } label: {
            IconView(icon: DesignTokens.Chat.Send.arrow)
              .frame(width: DesignTokens.Chat.Send.size, height: DesignTokens.Chat.Send.size)
              .background(DesignTokens.Chat.Send.fill,
                in: RoundedRectangle(cornerRadius: DesignTokens.Chat.Send.radius))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(model.sendAccessibilityLabel)
        }
      }
    }
    .padding(.top, DesignTokens.Chat.MessageBox.topPadding)
    .padding(.horizontal, DesignTokens.Chat.MessageBox.horizontalPadding)
    .padding(.bottom, DesignTokens.Chat.MessageBox.bottomPadding)
    .frame(height: DesignTokens.Chat.MessageBox.height)
    .background(DesignTokens.Chat.MessageBox.fill,
      in: RoundedRectangle(cornerRadius: DesignTokens.Chat.MessageBox.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Chat.MessageBox.radius)
        .strokeBorder(DesignTokens.Chat.MessageBox.stroke, lineWidth: DesignTokens.Chat.MessageBox.strokeWidth)
    }
    .opacity(DesignTokens.Chat.MessageBox.opacity(isEnabled: model.isMessageBoxEnabled))
    .disabled(!model.isMessageBoxEnabled)
    .padding(.horizontal, DesignTokens.Chat.MessageBox.areaHorizontalPadding)
    .padding(.bottom, DesignTokens.Chat.MessageBox.areaBottomPadding)
  }
}

private struct ChatTabView: View {
  let tab: ChatTabModel
  let isSelected: Bool
  let isHovered: Bool
  let linkIcon: ChatLinkIcon?
  let linkHelpText: String?
  let selected: () -> Void
  let closed: () -> Void
  let hovered: (Bool) -> Void

  var body: some View {
    HStack(spacing: DesignTokens.Chat.Tab.gap) {
      Button(action: selected) {
        HStack(spacing: DesignTokens.Chat.Tab.gap) {
          if tab.showsSpinner {
            SpinnerView(spinner: DesignTokens.Chat.Tab.spinner)
          }
          Text(tab.title)
            .font(DesignTokens.Chat.Tab.titleFont(isBold: tab.isTitleBold))
            .foregroundStyle(DesignTokens.Chat.Tab.titleColor(isSelected: isSelected, isBold: tab.isTitleBold))
            .lineLimit(1)
          if let linkIcon, let linkHelpText {
            IconView(icon: DesignTokens.Chat.Tab.link(linkIcon))
              .help(linkHelpText)
          }
        }
        .padding(.horizontal, DesignTokens.Chat.Tab.horizontalPadding)
        .frame(maxHeight: .infinity)
        .background(DesignTokens.Chat.Tab.fill(isHovered: isHovered),
          in: UnevenRoundedRectangle(topLeadingRadius: DesignTokens.Chat.Tab.hoverRadius,
            topTrailingRadius: DesignTokens.Chat.Tab.hoverRadius))
        .overlay(alignment: .bottom) {
          Rectangle().fill(DesignTokens.Chat.Tab.underline(isSelected: isSelected))
            .frame(height: DesignTokens.Chat.Tab.underlineWidth)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isHovered {
        Button(action: closed) { IconView(icon: DesignTokens.Chat.Tab.close) }
          .buttonStyle(.plain)
          .accessibilityLabel(tab.closeAccessibilityLabel)
      }
    }
    .frame(maxHeight: .infinity)
    .onHover(perform: hovered)
  }
}

private struct TranscriptView: View {
  let tab: ChatTabModel
  let tryAgainText: String
  let tryAgainTapped: () -> Void

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: DesignTokens.Chat.Transcript.gap) {
        ForEach(tab.projection.items) { item in
          itemView(item)
        }
        if let workingText = tab.workingText {
          HStack(spacing: DesignTokens.Chat.WorkingStatus.gap) {
            SpinnerView(spinner: DesignTokens.Chat.WorkingStatus.spinner)
            Text(workingText)
              .font(DesignTokens.Chat.WorkingStatus.font)
              .foregroundStyle(DesignTokens.Chat.WorkingStatus.color)
          }
          .padding(.top, DesignTokens.Chat.WorkingStatus.topPadding)
        }
        if let errorText = tab.errorText {
          errorBox(errorText)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, DesignTokens.Chat.Transcript.topPadding)
      .padding(.horizontal, DesignTokens.Chat.Transcript.horizontalPadding)
      .padding(.bottom, DesignTokens.Chat.Transcript.bottomPadding)
    }
    .defaultScrollAnchor(.bottom)
    .defaultScrollAnchor(.bottom, for: .sizeChanges)
  }

  @ViewBuilder
  private func itemView(_ item: TranscriptItem) -> some View {
    switch item.kind {
    case .userMessage:
      VStack(alignment: .trailing, spacing: DesignTokens.Chat.Transcript.gap) {
        userBubble(item)
        if let status = tab.relayStatus(for: item) {
          HStack(spacing: DesignTokens.Chat.Relay.statusGap) {
            IconView(icon: DesignTokens.Chat.Relay.icon(status))
            Text(tab.relayStatusText(status))
              .foregroundStyle(DesignTokens.Chat.Relay.statusColor(status))
            Text(tab.relayStatusDetail(status))
              .foregroundStyle(DesignTokens.Chat.Relay.detailColor)
          }
          .font(DesignTokens.Chat.Relay.statusFont)
        }
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    case .reply:
      MarkdownText(text: tab.rowText(for: item))
    case .thinking:
      VStack(alignment: .leading, spacing: DesignTokens.Chat.Thinking.gap) {
        Button { tab.itemToggled(item) } label: {
          HStack(spacing: DesignTokens.Chat.Thinking.gap) {
            IconView(icon: DesignTokens.Chat.Thinking.icon)
            Text(tab.thinkingText)
              .font(DesignTokens.Chat.Thinking.labelFont)
              .foregroundStyle(DesignTokens.Chat.Thinking.labelColor)
            IconView(icon: DesignTokens.Chat.Thinking.chevron(isExpanded: tab.isExpanded(item)))
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if tab.isExpanded(item) {
          Text(tab.rowText(for: item))
            .font(DesignTokens.Chat.Thinking.bodyFont)
            .foregroundStyle(DesignTokens.Chat.Thinking.bodyColor)
            .lineSpacing(DesignTokens.Chat.Thinking.bodyLineSpacing)
            .textSelection(.enabled)
        }
      }
    case .toolCall:
      ToolCallView(tab: tab, item: item)
    case .turnFooter:
      HStack(spacing: DesignTokens.Chat.TurnFooter.gap) {
        Text(tab.rowText(for: item))
          .font(DesignTokens.Chat.TurnFooter.font)
          .foregroundStyle(DesignTokens.Chat.TurnFooter.color)
        Button { tab.copyTapped(item) } label: { IconView(icon: DesignTokens.Chat.TurnFooter.copy) }
          .buttonStyle(.plain)
          .accessibilityLabel(tab.copyAccessibilityLabel)
        IconView(icon: DesignTokens.Chat.TurnFooter.more)
      }
    case .gap:
      Text(tab.rowText(for: item))
        .font(DesignTokens.Chat.TurnFooter.font)
        .foregroundStyle(DesignTokens.Chat.TurnFooter.color)
    }
  }

  private func userBubble(_ item: TranscriptItem) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.Relay.gap) {
      if let label = tab.relayLabel(for: item) {
        HStack(spacing: DesignTokens.Chat.Relay.tagGap) {
          IconView(icon: DesignTokens.Chat.Relay.tagIcon)
          Text(label)
            .font(DesignTokens.Chat.Relay.tagFont)
            .foregroundStyle(DesignTokens.Chat.Relay.tagColor)
        }
      }
      Text(tab.rowText(for: item))
        .font(DesignTokens.Chat.Paragraph.font)
        .foregroundStyle(DesignTokens.Chat.Paragraph.color)
        .lineSpacing(DesignTokens.Chat.Paragraph.lineSpacing)
        .textSelection(.enabled)
    }
    .padding(.vertical, DesignTokens.Chat.Bubble.verticalPadding)
    .padding(.horizontal, DesignTokens.Chat.Bubble.horizontalPadding)
    .background(DesignTokens.Chat.Bubble.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Chat.Bubble.radius))
    .opacity(DesignTokens.Chat.Relay.opacity(tab.relayStatus(for: item)))
    .frame(maxWidth: DesignTokens.Chat.Bubble.maxWidth, alignment: .trailing)
  }

  private func errorBox(_ errorText: String) -> some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.StartError.gap) {
      HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Chat.StartError.headerGap) {
        IconView(icon: DesignTokens.Chat.StartError.alert)
        Text(errorText)
          .font(DesignTokens.Chat.StartError.titleFont)
          .foregroundStyle(DesignTokens.Chat.StartError.titleColor)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      Button(action: tryAgainTapped) {
        Text(tryAgainText)
          .font(DesignTokens.Chat.StartError.tryAgainFont)
          .foregroundStyle(DesignTokens.Chat.StartError.tryAgainColor)
          .padding(.vertical, DesignTokens.Chat.StartError.tryAgainVerticalPadding)
          .padding(.horizontal, DesignTokens.Chat.StartError.tryAgainHorizontalPadding)
          .background(DesignTokens.Chat.StartError.tryAgainFill,
            in: RoundedRectangle(cornerRadius: DesignTokens.Chat.StartError.tryAgainRadius))
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, DesignTokens.Chat.StartError.verticalPadding)
    .padding(.horizontal, DesignTokens.Chat.StartError.horizontalPadding)
    .background(DesignTokens.Chat.StartError.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Chat.StartError.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Chat.StartError.radius)
        .strokeBorder(DesignTokens.Chat.StartError.stroke)
    }
  }
}

private struct ToolCallView: View {
  let tab: ChatTabModel
  let item: TranscriptItem
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.ToolCall.gap) {
      Button { tab.itemToggled(item) } label: {
        HStack(spacing: DesignTokens.Chat.ToolCall.gap) {
          if tab.isRunning(item) {
            SpinnerView(spinner: DesignTokens.Chat.ToolCall.spinner)
          } else if let kind = tab.toolKind(for: item) {
            IconView(icon: DesignTokens.Chat.ToolCall.icon(kind))
          }
          Text(DesignTokens.Chat.Paragraph.styled(tab.rowMarkdown(for: item), scale: fontScale))
            .font(DesignTokens.Chat.ToolCall.verbFont)
            .foregroundStyle(DesignTokens.Chat.ToolCall.verbColor)
            .lineLimit(1)
          IconView(icon: DesignTokens.Chat.ToolCall.chevron(isExpanded: tab.isExpanded(item)))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if tab.isExpanded(item), let detail = tab.detailText(for: item) {
        Text(detail)
          .font(DesignTokens.Chat.ToolCall.detailFont)
          .foregroundStyle(DesignTokens.Chat.ToolCall.detailColor)
          .textSelection(.enabled)
      }
    }
  }
}

private struct SpinnerView: View {
  let spinner: DesignTokens.Chat.Spinner
  @State private var isSpinning = false

  var body: some View {
    Circle()
      .trim(from: 0, to: DesignTokens.Chat.Spinner.arc)
      .stroke(spinner.color, style: StrokeStyle(lineWidth: spinner.lineWidth, lineCap: .round))
      .frame(width: spinner.size, height: spinner.size)
      .rotationEffect(.degrees(isSpinning ? 360 : 0))
      .animation(.linear(duration: DesignTokens.Chat.Spinner.secondsPerTurn).repeatForever(autoreverses: false), value: isSpinning)
      .onAppear { isSpinning = true }
  }
}
