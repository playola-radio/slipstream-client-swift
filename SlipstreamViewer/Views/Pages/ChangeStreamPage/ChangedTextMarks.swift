/// Which glyphs of a source line get the changed-text tint and removal ticks. A glyph covers
/// the UTF-16 offsets from its own up to the next glyph's, so a change inside a ligature or
/// cluster still marks it. A truncated line marks only the text it shows.
struct ChangedTextMarks: Equatable {
  enum Tick: Equatable {
    case before(Int)
    case after(Int)
  }

  var tinted: Set<Int> = []
  var ticks: [Tick] = []

  init(tinted: Set<Int> = [], ticks: [Tick] = []) {
    self.tinted = tinted
    self.ticks = ticks
  }

  init(glyphOffsets: [Int], text: String, changedRanges: [Range<Int>], removalOffsets: [Int]) {
    guard let lastOffset = glyphOffsets.max() else { return }
    let length = text.utf16.count
    let isTruncated = lastOffset < length - (text.last?.utf16.count ?? 0)
    let starts = Array(Set(glyphOffsets)).sorted()
    var ends: [Int: Int] = [:]
    for (start, end) in zip(starts, starts.dropFirst()) { ends[start] = end }
    ends[lastOffset] = isTruncated ? lastOffset + 1 : length

    var ticked = Set<Int>()
    for (index, offset) in glyphOffsets.enumerated() {
      let covered = offset..<(ends[offset] ?? offset + 1)
      if changedRanges.contains(where: { $0.overlaps(covered) }) { tinted.insert(index) }
      for removal in removalOffsets where covered.contains(removal) && ticked.insert(removal).inserted {
        ticks.append(.before(index))
      }
    }
    if !isTruncated, removalOffsets.contains(length), let index = glyphOffsets.lastIndex(of: lastOffset) {
      ticks.append(.after(index))
    }
  }
}
