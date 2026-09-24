import SlipstreamCore
import SwiftUI

struct ChangeStreamPageView: View {
  @State var model = ChangeStreamPageModel()

  private let bottomID = "feed-bottom"

  var body: some View {
    VStack(spacing: 0) {
      header
      if let emptyStateText = model.emptyStateText {
        Text(emptyStateText)
          .font(DesignTokens.Fonts.liveStatus)
          .foregroundStyle(DesignTokens.Colors.paneSubtitle)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        feed
      }
      footer
    }
    .background(DesignTokens.FeedPane.fill)
    .frame(minWidth: 520, minHeight: 480)
    .toolbar { toolbar }
    .task { await model.viewAppeared() }
    .onDisappear { model.viewDisappeared() }
  }

  private var header: some View {
    HStack(spacing: DesignTokens.FeedPane.headerGap) {
      IconView(icon: DesignTokens.Icons.listTree)
      Text(model.paneTitle)
        .font(DesignTokens.Fonts.paneTitle)
        .foregroundStyle(DesignTokens.Colors.paneTitle)
      Text(model.paneSubtitle)
        .font(DesignTokens.Fonts.paneSubtitle)
        .foregroundStyle(DesignTokens.Colors.paneSubtitle)
      Spacer()
    }
    .padding(.horizontal, DesignTokens.FeedPane.horizontalPadding)
    .frame(height: DesignTokens.FeedPane.headerHeight)
  }

  private var feed: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
          ForEach(model.sections) { section in
            Section {
              ForEach(section.items) { item in
                itemView(item)
                  .padding(.top, model.topGap(for: item, in: section))
              }
              Color.clear.frame(height: DesignTokens.Stream.groupGap)
            } header: {
              if let heading = section.heading {
                TaskHeadingView(heading: heading)
              }
            }
          }
          Color.clear.frame(height: 1).id(bottomID)
        }
      }
      .onScrollPhaseChange { _, phase in model.scrollPhaseChanged(phase) }
      .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
        ScrollMetrics(contentHeight: geometry.contentSize.height, visibleMaxY: geometry.visibleRect.maxY)
      } action: { _, metrics in
        model.scrollGeometryChanged(contentHeight: metrics.contentHeight, visibleMaxY: metrics.visibleMaxY)
      }
      .onChange(of: model.scrollToLatestRequest) {
        proxy.scrollTo(bottomID, anchor: .bottom)
      }
    }
  }

  @ViewBuilder
  private func itemView(_ item: FeedItem) -> some View {
    switch item {
    case .file(let row):
      FileCardView(
        row: row,
        subtitle: model.subtitle(for: row),
        content: model.content(for: row),
        emphasis: model.emphasis(for: row)
      )
      .task(id: row.id) { await model.cardAppeared(row) }
      .onDisappear { model.cardDisappeared(row) }
    case .marker(let marker):
      Text(marker.text)
        .font(DesignTokens.Fonts.eventTime)
        .foregroundStyle(DesignTokens.Colors.eventTime)
        .lineLimit(1)
        .padding(.horizontal, DesignTokens.Card.horizontalInset)
    }
  }

  private var footer: some View {
    HStack(spacing: DesignTokens.Footer.gap) {
      IconView(icon: DesignTokens.Icons.activity)
      Text(model.footerText)
        .font(DesignTokens.Fonts.liveStatus)
        .foregroundStyle(model.footerColor)
        .lineLimit(1)
      if model.isRetryVisible {
        Button(model.retryButtonText) { model.retryTapped() }
          .buttonStyle(.plain)
          .font(DesignTokens.Fonts.jumpToLatest)
          .foregroundStyle(DesignTokens.Colors.jumpToLatest)
      }
      Spacer()
      Button(model.jumpToLatestText) { model.jumpToLatestTapped() }
        .buttonStyle(.plain)
        .font(DesignTokens.Fonts.jumpToLatest)
        .foregroundStyle(DesignTokens.Colors.jumpToLatest)
    }
    .padding(.vertical, DesignTokens.Footer.verticalPadding)
    .padding(.horizontal, DesignTokens.Footer.horizontalPadding)
    .overlay(alignment: .top) {
      Rectangle().fill(DesignTokens.Footer.stroke).frame(height: 1)
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItem(placement: .navigation) {
      Menu(model.sessionPickerTitle) {
        ForEach(model.sessions) { session in
          Button(session.label) { model.sessionSelected(session.id) }
        }
      }
      .disabled(model.isSessionPickerDisabled)
    }
    ToolbarItem {
      Button(model.refreshButtonText, systemImage: "arrow.clockwise") {
        Task { await model.refreshTapped() }
      }
    }
  }
}

private struct ScrollMetrics: Equatable {
  var contentHeight: Double
  var visibleMaxY: Double
}

private struct IconView: View {
  let icon: DesignTokens.Icons.Icon

  var body: some View {
    Image(systemName: icon.systemName)
      .font(.system(size: icon.size))
      .foregroundStyle(icon.color)
  }
}

private struct TaskHeadingView: View {
  let heading: TaskHeading

  var body: some View {
    HStack(spacing: 16) {
      Text(heading.number)
        .font(DesignTokens.Fonts.taskBadge)
        .foregroundStyle(DesignTokens.Colors.taskBadge)
        .padding(.vertical, DesignTokens.Badge.verticalPadding)
        .padding(.horizontal, DesignTokens.Badge.horizontalPadding)
        .background(DesignTokens.Badge.fill, in: RoundedRectangle(cornerRadius: DesignTokens.Badge.radius))
      Text(heading.title)
        .font(DesignTokens.Fonts.taskTitle)
        .foregroundStyle(DesignTokens.Colors.taskTitle)
        .lineLimit(1)
      Spacer()
      IconView(icon: DesignTokens.Icons.pinPinned)
    }
    .padding(.vertical, DesignTokens.TaskHeading.verticalPadding)
    .padding(.horizontal, DesignTokens.TaskHeading.horizontalPadding)
    .background(DesignTokens.TaskHeading.fill)
    .overlay(alignment: .bottom) {
      Rectangle().fill(DesignTokens.TaskHeading.stroke).frame(height: 1)
    }
  }
}

private struct FileCardView: View {
  let row: FileChangeRow
  let subtitle: String?
  let content: CardContent
  let emphasis: CardEmphasis

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      Rectangle().fill(DesignTokens.Card.headerStroke).frame(height: 1)
      contentView
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, DesignTokens.Card.codeTopPadding)
        .padding(.horizontal, DesignTokens.Card.codeSidePadding)
        .padding(.bottom, DesignTokens.Card.codeBottomPadding)
        .background(DesignTokens.Card.codeFill(emphasis))
    }
    .background(DesignTokens.Card.fill)
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Card.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Card.radius).strokeBorder(DesignTokens.Card.stroke(emphasis))
    }
    .padding(.horizontal, DesignTokens.Card.horizontalInset)
  }

  private var header: some View {
    HStack(spacing: DesignTokens.Card.headerGap) {
      IconView(icon: DesignTokens.Icons.fileText)
      Text(row.path)
        .font(DesignTokens.Fonts.filePath)
        .foregroundStyle(DesignTokens.Colors.filePath(emphasis))
        .lineLimit(1)
        .truncationMode(.head)
      if let subtitle {
        Text(subtitle)
          .font(DesignTokens.Fonts.eventTime)
          .foregroundStyle(DesignTokens.Colors.paneSubtitle)
      }
      Spacer()
      Text(row.time)
        .font(DesignTokens.Fonts.eventTime)
        .foregroundStyle(DesignTokens.Colors.eventTime)
    }
    .padding(.vertical, DesignTokens.Card.headerVerticalPadding)
    .padding(.horizontal, DesignTokens.Card.headerHorizontalPadding)
    .background(DesignTokens.Card.headerFill(emphasis))
  }

  @ViewBuilder
  private var contentView: some View {
    switch content {
    case .loading:
      ProgressView().controlSize(.small).frame(height: DesignTokens.Card.lineHeight)
    case .note(let text):
      Text(text)
        .font(DesignTokens.Fonts.liveStatus)
        .foregroundStyle(DesignTokens.Colors.paneSubtitle)
        .frame(minHeight: DesignTokens.Card.lineHeight)
    case .code(_, let blocks):
      VStack(alignment: .leading, spacing: 0) {
        ForEach(blocks) { block in
          CodeBlockView(block: block)
        }
      }
    }
  }
}

private struct CodeBlockView: View {
  let block: CodeBlock

  var body: some View {
    if let separatorText = block.separatorText {
      gutterText(separatorText)
    }
    ForEach(block.lines) { line in
      HStack(spacing: 0) {
        Rectangle()
          .fill(DesignTokens.Card.marker(isChanged: line.isChanged))
          .frame(width: DesignTokens.Card.markerWidth)
        Text(line.number)
          .font(DesignTokens.Fonts.lineNumber)
          .foregroundStyle(DesignTokens.Colors.lineNumber)
          .frame(width: DesignTokens.Card.lineNumberWidth, alignment: .trailing)
          .padding(.trailing, DesignTokens.Card.lineGap)
        Text(line.text)
          .font(DesignTokens.Fonts.sourceLine)
          .foregroundStyle(DesignTokens.Colors.sourceLine)
          .lineLimit(1)
      }
      .frame(height: DesignTokens.Card.lineHeight)
    }
    if let truncationText = block.truncationText {
      gutterText(truncationText)
    }
  }

  private func gutterText(_ text: String) -> some View {
    Text(text)
      .font(DesignTokens.Fonts.lineNumber)
      .foregroundStyle(DesignTokens.Colors.lineNumber)
      .padding(.leading, DesignTokens.Card.markerWidth + DesignTokens.Card.lineNumberWidth + DesignTokens.Card.lineGap)
      .frame(height: DesignTokens.Card.lineHeight)
  }
}
