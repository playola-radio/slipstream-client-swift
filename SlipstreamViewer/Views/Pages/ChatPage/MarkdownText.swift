import SwiftUI

/// A reply: headings, lists, quotes, tables and paragraphs with inline markdown, and fenced code in Geist Mono.
struct MarkdownText: View {
  let text: String
  let codeCopyAccessibilityLabel: String
  let codeCopyTapped: (String) -> Void
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.Transcript.gap) {
      ForEach(Array(ChatTabModel.markdownBlocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let prose):
          paragraph(prose)
        case .heading(let level, let heading):
          Text(DesignTokens.Chat.Paragraph.styled(
            heading, base: DesignTokens.Chat.Heading.font(level: level), scale: fontScale))
            .font(DesignTokens.Chat.Heading.font(level: level))
            .foregroundStyle(DesignTokens.Chat.Heading.color)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .list(let items):
          VStack(alignment: .leading, spacing: DesignTokens.Chat.List.itemGap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
              HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Chat.List.markerGap) {
                Text(item.marker)
                  .font(DesignTokens.Chat.Paragraph.font)
                  .foregroundStyle(DesignTokens.Chat.List.markerColor)
                  .frame(minWidth: DesignTokens.Chat.List.markerMinWidth, alignment: .leading)
                paragraph(item.text)
              }
              .padding(.leading, DesignTokens.Chat.List.indent(depth: item.depth))
            }
          }
        case .quote(let quote):
          paragraph(quote, color: DesignTokens.Chat.Quote.color)
            .padding(.leading, DesignTokens.Chat.Quote.leadingPadding)
            .overlay(alignment: .leading) {
              Rectangle()
                .fill(DesignTokens.Chat.Quote.barColor)
                .frame(width: DesignTokens.Chat.Quote.barWidth)
            }
        case .rule:
          Rectangle()
            .fill(DesignTokens.Chat.Rule.color)
            .frame(height: DesignTokens.Chat.Rule.height)
        case .code(let code, let runs):
          CappedHeight(maxHeight: DesignTokens.Chat.CodeBlock.maxHeight) {
            ScrollView([.horizontal, .vertical]) {
              Text(DesignTokens.Syntax.styled(code, runs: runs))
                .font(DesignTokens.Chat.CodeBlock.font)
                .foregroundStyle(DesignTokens.Chat.CodeBlock.color)
                .padding(DesignTokens.Chat.CodeBlock.padding)
                .padding(.top, DesignTokens.Chat.CodeBlock.copyClearance)
            }
            .scrollIndicators(.hidden, axes: .horizontal)
            .defaultScrollAnchor(.topLeading)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DesignTokens.Chat.CodeBlock.fill,
            in: RoundedRectangle(cornerRadius: DesignTokens.Chat.CodeBlock.radius))
          .overlay(alignment: .topTrailing) {
            Button { codeCopyTapped(code) } label: {
              IconView(icon: DesignTokens.Chat.CodeBlock.copy)
                .padding(DesignTokens.Chat.CodeBlock.copyPadding)
                .background(DesignTokens.Chat.CodeBlock.fill,
                  in: RoundedRectangle(cornerRadius: DesignTokens.Chat.CodeBlock.radius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(codeCopyAccessibilityLabel)
          }
        case .table(let table):
          tableBlock(table)
        }
      }
    }
    .textSelection(.enabled)
  }

  private func tableBlock(_ table: ChatTabModel.MarkdownTable) -> some View {
    TableLayout(columns: table.header.count) {
      ForEach(Array(table.header.enumerated()), id: \.offset) { column, header in
        cell(header, font: DesignTokens.Chat.Table.headerFont, alignment: table.alignments[column])
          .background(DesignTokens.Chat.Table.headerFill)
      }
      ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
        ForEach(Array(row.enumerated()), id: \.offset) { column, text in
          cell(text, font: DesignTokens.Chat.Table.font, alignment: table.alignments[column])
            .overlay(alignment: .top) {
              Rectangle()
                .fill(DesignTokens.Chat.Table.gridColor)
                .frame(height: DesignTokens.Chat.Table.gridWidth)
            }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Chat.Table.radius))
    .overlay {
      RoundedRectangle(cornerRadius: DesignTokens.Chat.Table.radius)
        .strokeBorder(DesignTokens.Chat.Table.gridColor, lineWidth: DesignTokens.Chat.Table.gridWidth)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func cell(
    _ text: AttributedString, font: DesignTokens.FontToken, alignment: ChatTabModel.MarkdownTable.Alignment
  ) -> some View {
    Text(DesignTokens.Chat.Paragraph.styled(text, base: font, scale: fontScale))
      .font(font)
      .foregroundStyle(DesignTokens.Chat.Table.color)
      .multilineTextAlignment(DesignTokens.Chat.Table.textAlignment(alignment))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, DesignTokens.Chat.Table.cellHorizontalPadding)
      .padding(.vertical, DesignTokens.Chat.Table.cellVerticalPadding)
      .frame(
        maxWidth: .infinity, maxHeight: .infinity, alignment: DesignTokens.Chat.Table.cellAlignment(alignment))
  }

  private func paragraph(_ text: AttributedString, color: Color = DesignTokens.Chat.Paragraph.color) -> some View {
    Text(DesignTokens.Chat.Paragraph.styled(text, base: DesignTokens.Chat.Paragraph.font, scale: fontScale))
      .font(DesignTokens.Chat.Paragraph.font)
      .foregroundStyle(color)
      .lineSpacing(DesignTokens.Chat.Paragraph.lineSpacing)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Hugs its scroll view's content until `maxHeight`, past which the scroll view scrolls.
private struct CappedHeight: Layout {
  let maxHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: natural.width, height: min(natural.height, maxHeight))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

/// Cells in row order, `columns` to a row, each row as tall as its tallest cell.
private struct TableLayout: Layout {
  let columns: Int

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let widths = columnWidths(available: proposal.width, subviews)
    return CGSize(width: widths.reduce(0, +), height: rowHeights(widths, subviews).reduce(0, +))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let widths = columnWidths(available: bounds.width, subviews)
    var y = bounds.minY
    for (row, height) in rowHeights(widths, subviews).enumerated() {
      var x = bounds.minX
      for column in widths.indices {
        subviews[row * columns + column].place(
          at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[column], height: height))
        x += widths[column]
      }
      y += height
    }
  }

  private func columnWidths(available: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
    var natural = Array(repeating: CGFloat.zero, count: columns)
    for (index, cell) in subviews.enumerated() {
      natural[index % columns] = max(natural[index % columns], cell.sizeThatFits(.unspecified).width)
    }
    guard let available else { return natural }
    return ChatTabModel.MarkdownTable.columnWidths(natural: natural, available: available)
  }

  private func rowHeights(_ widths: [CGFloat], _ subviews: Subviews) -> [CGFloat] {
    stride(from: 0, to: subviews.count, by: columns).map { start in
      widths.indices.map { column in
        subviews[start + column].sizeThatFits(ProposedViewSize(width: widths[column], height: nil)).height
      }.max() ?? 0
    }
  }
}
