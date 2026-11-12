import SwiftUI

/// A reply: headings, lists, quotes and paragraphs with inline markdown, and fenced code in Geist Mono.
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
        case .code(let code):
          CappedHeight(maxHeight: DesignTokens.Chat.CodeBlock.maxHeight) {
            ScrollView([.horizontal, .vertical]) {
              Text(code)
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
        }
      }
    }
    .textSelection(.enabled)
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
