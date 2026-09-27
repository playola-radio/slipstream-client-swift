import SlipstreamCore
import SwiftUI

struct ChangeStreamPageView: View {
  @State var model = ChangeStreamPageModel()

  private let bottomID = "feed-bottom"

  var body: some View {
    HStack(spacing: 0) {
      if !model.isFeedHidden {
        feedPane.frame(width: DesignTokens.FeedPane.width)
      }
      fileViewer
    }
    .frame(minWidth: 1000, minHeight: 480)
    .coordinateSpace(name: "question-workspace")
    .onGeometryChange(for: CGSize.self) { $0.size } action: { model.viewportChanged($0) }
    .overlay(alignment: .topLeading) {
      ZStack(alignment: .topLeading) { questionOverlay }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .alert(model.questionDismissTitle, isPresented: $model.isQuestionDismissConfirmationPresented) {
      Button(model.questionDiscardText, role: .destructive) { model.questionDismissed() }
      Button(model.questionKeepText, role: .cancel) {}
    } message: {
      Text(model.questionDismissMessage)
    }
    .preferredColorScheme(.dark)
    .toolbar { toolbar }
    .task { await model.viewAppeared() }
    .onDisappear { model.viewDisappeared() }
  }

  @ViewBuilder
  private var questionOverlay: some View {
    if let reply = model.reply {
      if model.showsReplyConnector {
        Path { path in
          path.move(to: model.replyPlacement.barAnchor)
          path.addLine(to: model.replyPlacement.popoverAnchor)
        }
        .stroke(DesignTokens.Reply.connectorColor, lineWidth: DesignTokens.Reply.connectorWidth)
        .allowsHitTesting(false)
        Circle().fill(DesignTokens.Reply.connectorColor)
          .frame(width: DesignTokens.Reply.connectorDot, height: DesignTokens.Reply.connectorDot)
          .position(model.replyPlacement.barAnchor)
          .allowsHitTesting(false)
      }
      ScrollView {
        QuestionThreadPageView(model: reply, dismiss: { model.replyDismissTapped() })
          .id(reply)
          .frame(width: model.replyWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { model.replyMeasured($0) }
      }
      .scrollIndicators(.hidden)
      .frame(width: model.replyPlacement.popover.width, height: model.replyPlacement.popover.height)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Reply.radius))
      .shadow(color: DesignTokens.Reply.shadow, radius: DesignTokens.Reply.shadowBlur, y: DesignTokens.Reply.shadowY)
      .offset(x: model.replyPlacement.popover.minX, y: model.replyPlacement.popover.minY)
    }
    if let composer = model.askAgent {
      if model.showsSelectionConnector {
        Path { path in
          path.move(to: model.questionPlacement.selectionAnchor)
          path.addLine(to: model.questionPlacement.modalAnchor)
        }
        .stroke(DesignTokens.Ask.contextColor, lineWidth: DesignTokens.Ask.connectorWidth)
        .allowsHitTesting(false)
        Circle().fill(DesignTokens.Ask.contextColor)
          .frame(width: DesignTokens.Ask.connectorDot, height: DesignTokens.Ask.connectorDot)
          .position(model.questionPlacement.selectionAnchor)
          .allowsHitTesting(false)
      }
      ScrollView {
        AskAgentPageView(model: composer, dismiss: { model.questionDismissTapped() },
          submit: { Task { await model.askQuestionTapped(composer) } })
          .id(composer)
          .frame(width: model.composerWidth)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGSize.self) { $0.size } action: { model.composerMeasured($0) }
      }
      .scrollIndicators(.hidden)
      .frame(width: model.questionPlacement.modal.width, height: model.questionPlacement.modal.height)
      .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Ask.radius))
      .shadow(color: DesignTokens.Ask.shadow, radius: DesignTokens.Ask.shadowBlur,
        y: DesignTokens.Ask.shadowY)
      .offset(x: model.questionPlacement.modal.minX, y: model.questionPlacement.modal.minY)
    }
  }

  private var feedPane: some View {
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
    .overlay(alignment: .trailing) {
      Rectangle().fill(DesignTokens.FeedPane.stroke).frame(width: 1)
    }
  }

  private var fileViewer: some View {
    VStack(alignment: .leading, spacing: DesignTokens.FileViewer.gap) {
      HStack {
        if model.isFeedHidden {
          Button(model.showFeedText) { model.showFeedTapped() }
            .buttonStyle(.plain)
            .font(DesignTokens.Fonts.restoreFeed)
            .foregroundStyle(DesignTokens.Colors.restoreFeed)
        }
      }
      .frame(height: DesignTokens.FileViewer.toolbarHeight)
      Text(model.fileViewerPlaceholderText)
        .font(DesignTokens.Fonts.liveStatus)
        .foregroundStyle(DesignTokens.Colors.paneSubtitle)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.FileViewer.paneFill)
        .border(DesignTokens.FileViewer.paneStroke)
    }
    .padding(DesignTokens.FileViewer.padding)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(DesignTokens.FileViewer.fill)
  }

  private var header: some View {
    HStack(spacing: DesignTokens.FeedPane.headerGap) {
      IconView(icon: DesignTokens.Icons.listTree)
      Text(model.paneTitle)
        .font(DesignTokens.Fonts.paneTitle)
        .foregroundStyle(DesignTokens.Colors.paneTitle)
      Text(model.paneSubtitle)
        .font(DesignTokens.Fonts.paneSubtitle(isQuestionSummary: model.isQuestionSummaryShown))
        .foregroundStyle(DesignTokens.Colors.paneSubtitle(isQuestionSummary: model.isQuestionSummaryShown))
      Spacer()
      Button { model.hideFeedTapped() } label: {
        HStack(spacing: DesignTokens.HideFeedButton.gap) {
          IconView(icon: DesignTokens.Icons.hideFeed)
          Text(model.hideFeedText)
            .font(DesignTokens.Fonts.hideFeed)
            .foregroundStyle(DesignTokens.Colors.hideFeed)
        }
        .padding(.vertical, DesignTokens.HideFeedButton.verticalPadding)
        .padding(.horizontal, DesignTokens.HideFeedButton.horizontalPadding)
        .overlay {
          RoundedRectangle(cornerRadius: DesignTokens.HideFeedButton.radius)
            .strokeBorder(DesignTokens.HideFeedButton.stroke)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
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
                  .padding(.top, DesignTokens.Stream.itemGap)
              }
              Color.clear.frame(height: DesignTokens.Stream.groupGap)
            } header: {
              if let heading = section.heading {
                TaskHeadingView(heading: heading, isPinned: model.isHeadingPinned(section))
                  .onGeometryChange(for: Double.self) { geometry in
                    geometry.frame(in: .scrollView).minY
                  } action: { minY in
                    model.headingMoved(section, minY: minY)
                  }
              }
            }
          }
          Color.clear.frame(height: 1).id(bottomID)
        }
      }
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: {
        model.feedViewportChanged($0)
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
      .onAppear {
        proxy.scrollTo(bottomID, anchor: .bottom)
      }
    }
  }

  @ViewBuilder
  private func itemView(_ item: FeedItem) -> some View {
    switch item {
    case .file(let row):
      VStack(spacing: 0) {
        FileCardView(
          row: row,
          model: model,
          openIndicatorText: model.openIndicatorText(for: row),
          content: model.content(for: row),
          emphasis: model.emphasis(for: row),
          isRetryable: model.isCardRetryable(row),
          retryTapped: { Task { await model.cardRetryTapped(row) } }
        )
        .task(id: FeedCardTaskID(feedGeneration: model.feedGeneration, rowID: row.id)) { await model.cardAppeared(row) }
        .onDisappear { model.cardDisappeared(row) }
        ForEach(model.questionBars(for: row)) { bar in
          QuestionBarView(bar: bar) { model.questionBarTapped(bar) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: {
              model.questionBarMoved(bar, frame: $0)
            }
            .onDisappear { model.questionBarDisappeared(bar) }
            .padding(.horizontal, DesignTokens.Card.horizontalInset)
        }
      }
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
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
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
    Image(icon.assetName)
      .resizable()
      .frame(width: icon.size, height: icon.size)
      .foregroundStyle(icon.color)
  }
}

private struct QuestionBarView: View {
  let bar: QuestionBar
  let tapped: () -> Void

  var body: some View {
    Button(action: tapped) {
      HStack(spacing: DesignTokens.ReplyBar.gap) {
        Image("MessageCircle").resizable()
          .frame(width: DesignTokens.ReplyBar.iconSize, height: DesignTokens.ReplyBar.iconSize)
          .foregroundStyle(DesignTokens.ReplyBar.accent(bar.status))
        Text(bar.preview)
          .font(DesignTokens.ReplyBar.previewFont)
          .foregroundStyle(DesignTokens.ReplyBar.previewColor)
          .lineLimit(1)
        Spacer(minLength: 0)
        Text(bar.statusText)
          .font(DesignTokens.ReplyBar.statusFont)
          .foregroundStyle(DesignTokens.ReplyBar.accent(bar.status))
        Image(DesignTokens.ReplyBar.chevron(isOpen: bar.isOpen)).resizable()
          .frame(width: DesignTokens.ReplyBar.chevronSize, height: DesignTokens.ReplyBar.chevronSize)
          .foregroundStyle(DesignTokens.ReplyBar.chevronColor)
      }
      .padding(.horizontal, DesignTokens.ReplyBar.horizontalPadding)
      .frame(height: DesignTokens.ReplyBar.height)
      .background(DesignTokens.ReplyBar.fill(isOpen: bar.isOpen),
        in: RoundedRectangle(cornerRadius: DesignTokens.ReplyBar.radius))
      .overlay {
        RoundedRectangle(cornerRadius: DesignTokens.ReplyBar.radius)
          .strokeBorder(DesignTokens.ReplyBar.stroke(isOpen: bar.isOpen), lineWidth: DesignTokens.ReplyBar.strokeWidth)
      }
      .overlay(alignment: .leading) {
        UnevenRoundedRectangle(topLeadingRadius: DesignTokens.ReplyBar.radius,
          bottomLeadingRadius: DesignTokens.ReplyBar.radius)
          .fill(DesignTokens.ReplyBar.stroke(isOpen: bar.isOpen))
          .frame(width: DesignTokens.ReplyBar.leadingStrokeWidth)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityValue(bar.statusText)
  }
}

private struct TaskHeadingView: View {
  let heading: TaskHeading
  let isPinned: Bool

  var body: some View {
    HStack(spacing: DesignTokens.TaskHeading.gap) {
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
      IconView(icon: DesignTokens.Icons.pin(isPinned: isPinned))
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
  let model: ChangeStreamPageModel
  let openIndicatorText: String?
  let content: CardContent
  let emphasis: CardEmphasis
  let isRetryable: Bool
  let retryTapped: () -> Void

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
      Spacer()
      Text(row.time)
        .font(DesignTokens.Fonts.eventTime)
        .foregroundStyle(DesignTokens.Colors.eventTime)
      if let openIndicatorText {
        Text(openIndicatorText)
          .font(DesignTokens.Fonts.openIndicator)
          .foregroundStyle(DesignTokens.Colors.openIndicator)
      }
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
      HStack(spacing: DesignTokens.Card.headerGap) {
        Text(text)
          .font(DesignTokens.Fonts.liveStatus)
          .foregroundStyle(DesignTokens.Colors.paneSubtitle)
        if isRetryable {
          Button("Retry", action: retryTapped)
            .buttonStyle(.plain)
            .font(DesignTokens.Fonts.jumpToLatest)
            .foregroundStyle(DesignTokens.Colors.jumpToLatest)
        }
      }
      .frame(minHeight: DesignTokens.Card.lineHeight)
    case .code(let blocks):
      VStack(alignment: .leading, spacing: 0) {
        ForEach(blocks) { block in
          CodeBlockView(block: block, row: row, model: model)
        }
      }
    }
  }
}

private struct CodeBlockView: View {
  let block: CodeBlock
  let row: FileChangeRow
  let model: ChangeStreamPageModel
  @State private var sourceGeometry = SourceGeometry()

  var body: some View {
    if let separatorText = block.separatorText {
      gutter {
        Text(separatorText)
          .font(DesignTokens.Fonts.lineNumber)
          .foregroundStyle(DesignTokens.Colors.lineNumber)
      } source: {
        EmptyView()
      }
    }
    VStack(alignment: .leading, spacing: 0) {
      ForEach(block.lines) { line in
        gutter(isChanged: line.isChanged, isVerified: line.isVerified) {
          Text(line.number)
            .font(DesignTokens.Fonts.lineNumber)
            .foregroundStyle(DesignTokens.Colors.lineNumber)
        } source: {
          Text(line.text)
            .font(DesignTokens.Fonts.sourceLine)
            .foregroundStyle(DesignTokens.Colors.sourceLine)
            .lineLimit(1)
            .textRenderer(ChangedTextRenderer(line: line))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .background(alignment: .topLeading) {
      GeometryReader { geometry in
        if let rect = model.highlightRect(row: row, block: block, width: geometry.size.width) {
          Rectangle().fill(DesignTokens.Ask.selectionFill)
            .overlay {
              Rectangle().strokeBorder(DesignTokens.Ask.selectionStroke, lineWidth: DesignTokens.Ask.selectionEdgeWidth)
            }
            .overlay(alignment: .leading) {
              Rectangle().fill(DesignTokens.Ask.selectionStroke).frame(width: DesignTokens.Ask.selectionLeftWidth)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(y: rect.minY)
        }
      }
    }
    .contentShape(Rectangle())
    .overlay {
      SourceDragAdapter(dragged: { startY, endY in
        model.sourceDragged(row: row, block: block, startY: startY, endY: endY, frame: sourceGeometry.frame)
      }, ended: { model.sourceDragEnded() })
    }
    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("question-workspace")) } action: { frame in
      sourceGeometry.frame = frame
      model.sourceBlockMoved(row: row, block: block, frame: frame)
    }
    .onDisappear { model.sourceBlockDisappeared(row: row, block: block) }
    if let truncationText = block.truncationText {
      gutter {
        EmptyView()
      } source: {
        Text(truncationText)
          .font(DesignTokens.Fonts.lineNumber)
          .foregroundStyle(DesignTokens.Colors.lineNumber)
      }
    }
  }

  private func gutter(
    isChanged: Bool = false,
    isVerified: Bool = true,
    @ViewBuilder number: () -> some View,
    @ViewBuilder source: () -> some View
  ) -> some View {
    HStack(spacing: DesignTokens.Card.lineGap) {
      Rectangle()
        .fill(DesignTokens.Card.marker(isChanged: isChanged, isVerified: isVerified))
        .frame(width: DesignTokens.Card.markerWidth)
      number()
        .frame(width: DesignTokens.Card.lineNumberWidth, alignment: .trailing)
      source()
    }
    .frame(height: DesignTokens.Card.lineHeight)
  }
}

/// Draws the tint and removal ticks from glyph positions so the line stays one unsplit
/// `Text` and keeps its ligatures. Offsets are UTF-16, counted from the first glyph.
private struct ChangedTextRenderer: TextRenderer {
  let line: CodeLine

  func draw(layout: Text.Layout, in context: inout GraphicsContext) {
    guard !line.changedRanges.isEmpty || !line.removalOffsets.isEmpty else {
      for row in layout { context.draw(row) }
      return
    }
    let slices = layout.flatMap { $0 }
      .flatMap { run in run.indices.map { (slice: run[$0], isRightToLeft: run.layoutDirection == .rightToLeft) } }
      .filter { !$0.slice.characterIndices.isEmpty }
    guard let start = slices.flatMap(\.slice.characterIndices).min() else {
      for row in layout { context.draw(row) }
      return
    }
    let marks = ChangedTextMarks(
      glyphOffsets: slices.map { $0.slice.characterIndices.map { start.distance(to: $0) }.min() ?? 0 },
      length: line.text.utf16.count, isTruncated: layout.isTruncated,
      changedRanges: line.changedRanges, removalOffsets: line.removalOffsets
    )
    var tint = Path()
    for index in marks.tinted { tint.addRect(slices[index].slice.typographicBounds.rect) }
    var ticks = Path()
    for tick in marks.ticks {
      switch tick {
      case .before(let index): ticks.addRect(self.tick(atLeadingEdge: true, of: slices[index]))
      case .after(let index): ticks.addRect(self.tick(atLeadingEdge: false, of: slices[index]))
      }
    }
    context.fill(tint, with: .color(DesignTokens.Card.changedTextTint))
    for row in layout { context.draw(row) }
    context.fill(ticks, with: .color(DesignTokens.Card.removalTick))
  }

  private func tick(
    atLeadingEdge isLeading: Bool, of glyph: (slice: Text.Layout.RunSlice, isRightToLeft: Bool)
  ) -> CGRect {
    let rect = glyph.slice.typographicBounds.rect
    let x = isLeading == glyph.isRightToLeft ? rect.maxX : rect.minX
    return CGRect(
      x: x - DesignTokens.Card.removalTickWidth / 2, y: rect.minY,
      width: DesignTokens.Card.removalTickWidth, height: rect.height
    )
  }
}

@MainActor
private final class SourceGeometry {
  var frame = CGRect.zero
}
