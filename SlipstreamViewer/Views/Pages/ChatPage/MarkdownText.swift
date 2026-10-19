import SwiftUI

/// A reply: prose with inline markdown, and fenced code in Geist Mono.
struct MarkdownText: View {
  let text: String
  @Environment(\.fontScale) private var fontScale

  var body: some View {
    VStack(alignment: .leading, spacing: DesignTokens.Chat.Transcript.gap) {
      ForEach(Array(ChatTabModel.markdownBlocks(text).enumerated()), id: \.offset) { _, block in
        switch block {
        case .prose(let prose):
          Text(Self.styled(prose, scale: fontScale))
            .font(DesignTokens.Chat.Paragraph.font)
            .foregroundStyle(DesignTokens.Chat.Paragraph.color)
            .lineSpacing(DesignTokens.Chat.Paragraph.lineSpacing)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let code):
          ScrollView(.horizontal) {
            Text(code)
              .font(DesignTokens.Chat.CodeBlock.font)
              .foregroundStyle(DesignTokens.Chat.CodeBlock.color)
              .textSelection(.enabled)
              .padding(DesignTokens.Chat.CodeBlock.padding)
          }
          .scrollIndicators(.hidden)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(DesignTokens.Chat.CodeBlock.fill,
            in: RoundedRectangle(cornerRadius: DesignTokens.Chat.CodeBlock.radius))
        }
      }
    }
  }

  /// Inline `code` runs take the code font and colour; the rest keeps the view's font.
  static func styled(_ text: AttributedString, scale: CGFloat) -> AttributedString {
    var text = text
    for run in text.runs where run.inlinePresentationIntent?.contains(.code) == true {
      text[run.range].font = DesignTokens.Chat.Paragraph.inlineCodeFont.font(scale: scale)
      text[run.range].foregroundColor = DesignTokens.Chat.Paragraph.inlineCodeColor
    }
    return text
  }

  static func inline(_ text: String, scale: CGFloat) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    return styled((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text), scale: scale)
  }
}
