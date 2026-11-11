import SwiftUI

struct WorkspaceSidebarView: View {
  let model: ChangeStreamPageModel

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: DesignTokens.Sidebar.listGap) {
          ForEach(model.sidebarGroups) { group in
            VStack(alignment: .leading, spacing: DesignTokens.Sidebar.groupGap) {
              groupHeader(group)
              ForEach(group.rows) { session in
                WorkspaceRowView(model: model, session: session)
              }
            }
          }
        }
        .padding(.vertical, DesignTokens.Sidebar.listVerticalPadding)
        .padding(.horizontal, DesignTokens.Sidebar.listHorizontalPadding)
      }
      footer
    }
    .background(DesignTokens.Sidebar.fill)
    .overlay(alignment: .trailing) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(width: 1)
    }
  }

  private var header: some View {
    HStack(spacing: DesignTokens.Sidebar.headerGap) {
      Text(model.sidebarTitleText)
        .font(DesignTokens.Sidebar.titleFont)
        .foregroundStyle(DesignTokens.Sidebar.titleColor)
      if let recordingCountText = model.recordingCountText {
        Text(recordingCountText)
          .font(DesignTokens.Sidebar.recordingCountFont)
          .foregroundStyle(DesignTokens.Sidebar.recordingCountColor)
      }
      Spacer()
    }
    .padding(.leading, DesignTokens.Sidebar.headerLeadingPadding)
    .padding(.trailing, DesignTokens.Sidebar.headerTrailingPadding)
    .frame(height: DesignTokens.Sidebar.headerHeight)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(height: 1)
    }
  }

  private func groupHeader(_ group: SidebarGroup) -> some View {
    HStack(spacing: DesignTokens.Sidebar.groupHeaderGap) {
      IconView(icon: DesignTokens.Sidebar.groupIcon)
      Text(group.name)
        .font(DesignTokens.Sidebar.groupNameFont)
        .foregroundStyle(DesignTokens.Sidebar.groupNameColor)
        .lineLimit(1)
      Spacer()
      if group.newWorkspaceFolder != nil {
        Button { Task { await model.newWorkspaceTapped(in: group) } } label: {
          IconView(icon: DesignTokens.Sidebar.newWorkspaceIcon)
            .padding(DesignTokens.Sidebar.iconButtonPadding)
        }
        .buttonStyle(.plain)
        .help(model.newWorkspaceHelpText)
        .disabled(model.isWorkspaceBusy)
      }
    }
    .padding(.leading, DesignTokens.Sidebar.groupHeaderLeadingPadding)
    .padding(.trailing, DesignTokens.Sidebar.groupHeaderTrailingPadding)
    .frame(height: DesignTokens.Sidebar.groupHeaderHeight)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button { Task { await model.newWorkspaceTapped() } } label: {
        footerLine(icon: DesignTokens.Sidebar.footerIcon, text: model.addRepositoryText)
      }
      .buttonStyle(.plain)
      .disabled(model.isWorkspaceBusy)
      Button { Task { await model.recordFolderTapped() } } label: {
        footerLine(icon: DesignTokens.Sidebar.recordFolderIcon, text: model.recordFolderText)
      }
      .buttonStyle(.plain)
      if let footerMessage = model.footerMessage {
        RecordingMessageView(message: footerMessage)
          .padding(DesignTokens.Sidebar.footerMessageInsets)
      }
    }
    .padding(.vertical, DesignTokens.Sidebar.footerVerticalPadding)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.Sidebar.stroke).frame(height: 1)
    }
  }

  private func footerLine(icon: DesignTokens.Icons.Icon, text: String) -> some View {
    HStack(spacing: DesignTokens.Sidebar.footerGap) {
      IconView(icon: icon)
      Text(text)
        .font(DesignTokens.Sidebar.footerFont)
        .foregroundStyle(DesignTokens.Sidebar.footerColor)
      Spacer()
    }
    .padding(.horizontal, DesignTokens.Sidebar.footerHorizontalPadding)
    .frame(height: DesignTokens.Sidebar.footerLineHeight)
    .contentShape(Rectangle())
  }
}

private struct RecordingMessageView: View {
  let message: RecordingMessage

  var body: some View {
    Text(message.text)
      .font(DesignTokens.Sidebar.messageFont)
      .lineSpacing(DesignTokens.Sidebar.messageLineSpacing)
      .foregroundStyle(DesignTokens.Sidebar.messageColor(isFull: message.isFull))
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)
  }
}

private struct WorkspaceRowView: View {
  let model: ChangeStreamPageModel
  let session: SessionOption
  @FocusState private var focus: Focus?

  private enum Focus { case row, action, archive }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      row
      if let message = model.rowMessage(session) {
        RecordingMessageView(message: message)
          .padding(DesignTokens.Sidebar.rowMessageInsets)
      }
    }
  }

  private var row: some View {
    let isSelected = model.isSelected(session)
    return HStack(spacing: DesignTokens.Sidebar.rowGap) {
      Button { model.sessionSelected(session.id) } label: {
        HStack(spacing: DesignTokens.Sidebar.rowGap) {
          IconView(icon: model.rowIcon(session))
          Text(model.rowName(session))
            .font(DesignTokens.Sidebar.rowNameFont(isBold: model.isBold(session)))
            .foregroundStyle(model.rowNameColor(session))
            .lineLimit(1)
          Spacer()
          if model.isSpinnerShown(session) {
            SpinnerView(spinner: DesignTokens.Sidebar.spinner)
          } else if model.isRecordingDotShown(session) {
            Circle()
              .fill(DesignTokens.Sidebar.recordingDotColor)
              .frame(width: DesignTokens.Sidebar.recordingDotSize, height: DesignTokens.Sidebar.recordingDotSize)
          }
        }
        .padding(.leading, DesignTokens.Sidebar.rowLeadingPadding)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focused($focus, equals: .row)
      .accessibilityActions {
        if model.isRowActionAvailable(session) {
          Button(model.rowActionText(session)) { Task { await model.rowActionTapped(session) } }
        }
        if model.isArchivable(session) {
          Button(model.archiveWorkspaceHelpText) { model.archiveTapped(session) }
        }
      }
      if model.isRowActionShown(session) {
        rowAction(DesignTokens.Sidebar.rowAction(isRecord: model.isPaused(session)))
      }
      if model.isArchiveIconShown(for: session) {
        Button { model.archiveTapped(session) } label: {
          IconView(icon: DesignTokens.Sidebar.archiveIcon)
            .padding(DesignTokens.Sidebar.iconButtonPadding)
        }
        .buttonStyle(.plain)
        .help(model.archiveWorkspaceHelpText)
        .disabled(model.isWorkspaceBusy)
        .focused($focus, equals: .archive)
      }
    }
    .padding(.trailing, DesignTokens.Sidebar.rowTrailingPadding)
    .frame(height: DesignTokens.Sidebar.rowHeight)
    .background {
      if isSelected {
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowRadius).fill(DesignTokens.Sidebar.selectedRowFill)
      } else if model.isHighlighted(session) {
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.rowRadius).fill(DesignTokens.Sidebar.highlightedRowFill)
      }
    }
    .onHover { model.rowHoverChanged(session, isHovering: $0) }
    .onChange(of: focus) { model.rowFocusChanged(session, isFocused: focus != nil) }
    .contextMenu {
      Button(model.renameMenuText, systemImage: "pencil") { model.renameMenuTapped(session) }
        .disabled(!model.isRenameEnabled(session))
        .help(model.renameHelpText(session))
      Button(model.useAgentNameMenuText, systemImage: "arrow.uturn.backward") {
        Task { await model.useAgentNameMenuTapped(session) }
      }
      .disabled(!model.isUseAgentNameEnabled(session))
      if model.isArchivable(session) {
        Divider()
        Button(model.archiveMenuText, systemImage: "archivebox") { model.archiveTapped(session) }
          .disabled(model.isWorkspaceBusy)
      }
    }
  }

  private func rowAction(_ action: DesignTokens.Sidebar.RowAction) -> some View {
    let isWorking = model.isRowActionDisabled(session)
    return Button { Task { await model.rowActionTapped(session) } } label: {
      HStack(spacing: DesignTokens.Sidebar.RowAction.gap) {
        if isWorking {
          SpinnerView(spinner: action.spinner)
        } else {
          IconView(icon: action.icon)
        }
        Text(model.rowActionText(session))
          .font(DesignTokens.Sidebar.RowAction.font)
          .foregroundStyle(action.textColor)
      }
      .padding(.horizontal, DesignTokens.Sidebar.RowAction.horizontalPadding)
      .frame(height: DesignTokens.Sidebar.RowAction.height)
      .background(
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.RowAction.radius).fill(action.fill))
      .overlay(
        RoundedRectangle(cornerRadius: DesignTokens.Sidebar.RowAction.radius)
          .strokeBorder(action.stroke, lineWidth: DesignTokens.Sidebar.RowAction.strokeWidth))
    }
    .buttonStyle(.plain)
    .disabled(isWorking)
    .opacity(DesignTokens.Sidebar.RowAction.opacity(isWorking: isWorking))
    .focused($focus, equals: .action)
  }
}
