import Foundation
import Observation
import SlipstreamCore

struct FunctionSourceSelection: Equatable {
  enum Side: Equatable { case before, after }

  let sessionID: String
  let beforeSeq: Seq
  let afterSeq: Seq
  let path: String
  let side: Side
  let sha256: String
  let byteRange: Range<Int>
  let projectionVersion: String
  let languageVersion: String
  let identity: InterfaceIdentity
}

struct FunctionChangeLine: Equatable {
  enum Mark: Equatable { case equal, added, removed, changed, note }
  let mark: Mark
  let text: String
}

struct FunctionChangeNode: Identifiable, Equatable {
  enum Kind: Equatable { case root, directory, file, declaration }
  let id: String
  let parentID: String?
  let kind: Kind
  let title: String
  let statusText: String?
  let lines: [FunctionChangeLine]
  let changedCount: Int
  let unknownCount: Int
  let marker: FunctionChangeLine.Mark?
  let x: CGFloat
  let y: CGFloat
  let width: CGFloat
  let height: CGFloat
}

@MainActor
@Observable
final class FunctionChangesPageModel: ViewModel {
  // MARK: - Initialization

  init(comparison: InterfaceComparison) {
    pages = [comparison]
    super.init()
  }

  // MARK: - Properties

  private(set) var pages: [InterfaceComparison]
  var searchText = ""
  private(set) var showsUnchanged = false
  private(set) var selectedNodeID: String?
  private(set) var sourceSelection: FunctionSourceSelection?
  private(set) var focusedNodeID: String?
  private(set) var focusRequest = 0
  private(set) var zoom: CGFloat = 1
  private(set) var viewportSize = CGSize.zero

  private var firstPage: InterfaceComparison { pages[0] }
  private var lastPage: InterfaceComparison { pages[pages.count - 1] }
  private var allFiles: [InterfaceFileResult] { pages.flatMap(\.files) }

  var detectedChanges: Int { allFiles.reduce(0) { $0 + changes(in: $1).count } }
  var filesNotCompared: Int { allFiles.filter(isNotCompared).count }
  var visibleFileCount: Int { visibleFiles.count }
  var nodes: [FunctionChangeNode] { tree.nodes }
  var canvasSize: CGSize { tree.size }
  var edges: [(CGPoint, CGPoint)] {
    let positions = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    return nodes.compactMap { node in
      guard let parentID = node.parentID, let parent = positions[parentID] else { return nil }
      return (CGPoint(x: parent.x, y: parent.y + parent.height), CGPoint(x: node.x, y: node.y))
    }
  }

  // MARK: - Display Text

  let titleText = "See where the change lives."
  let subtitleText = "Follow recorded function input and output changes in observed files."
  let analysisText = "Shared types, effects and behaviour: not analyzed"
  let scopeText = "Observed files"
  let searchPrompt = "Find loaded file or function"
  let legendText = "Number = changed declarations in loaded files"
  let fixtureText = "FIXTURE DEMO · Recorded example, not a live capture"
  let coverageText =
    "Observed files exclude the store directory, .git and symlinks. Lines show containment; the comparison covers recorded endpoints, not every intermediate edit."

  var boundaryText: String {
    "Recorded at #\(firstPage.beforeSeq.decimal) → Recorded at #\(firstPage.afterSeq.decimal)"
  }

  var summaryText: String {
    let count = detectedChanges
    let noun = count == 1 ? "change" : "changes"
    let coverage = lastPage.page.complete ? "" : " in loaded files"
    let failures = filesNotCompared
    if failures > 0 {
      return
        "\(count) detected \(noun)\(coverage) · \(failures) \(failures == 1 ? "file" : "files") not compared"
    }
    return "\(count) detected \(noun)\(coverage)"
  }

  var noticeText: String {
    var notes: [String] = []
    if case .skipped(let reason) = lastPage.status {
      notes.append("Page skipped: \(reason.rawValue)")
    }
    if !lastPage.page.complete {
      notes.append("More files may exist; counts and search cover loaded data only")
    }
    if firstPage.inventory.baselineCompletedSeq == nil {
      notes.append("Baseline inventory was incomplete")
    }
    if !firstPage.inventory.unknownScopes.isEmpty {
      notes.append(
        "Unknown observed scopes: \(firstPage.inventory.unknownScopes.joined(separator: ", "))")
    }
    if !firstPage.inventory.unknownScopesComplete {
      notes.append("Additional unknown scopes were omitted")
    }
    let gapSequences = Set(pages.flatMap { $0.gaps.map(\.seq.decimal) }).sorted()
    if !gapSequences.isEmpty {
      notes.append(
        "Capture gaps at #\(gapSequences.joined(separator: ", #")); intermediate edits may be missing"
      )
    }
    if pages.contains(where: { !$0.gapsComplete }) {
      notes.append("Additional capture gaps were omitted")
    }
    return notes.joined(separator: " · ")
  }

  var searchNotice: String { "Search covers loaded file paths and function names only" }
  var selectionText: String {
    guard let sourceSelection else {
      return "Select a declaration to inspect its recorded source reference"
    }
    let side = sourceSelection.side == .after ? "After" : "Before"
    return
      "\(side) · \(sourceSelection.path) · SHA-256 \(sourceSelection.sha256) · UTF-8 bytes \(sourceSelection.byteRange.lowerBound)–\(sourceSelection.byteRange.upperBound)"
  }
  var zoomText: String { "\(Int((zoom * 100).rounded()))%" }
  var canSelectBefore: Bool {
    guard let selectedNodeID, let target = declaration(for: selectedNodeID) else { return false }
    return selection(for: target, preferredSide: .before) != nil
  }
  var canSelectAfter: Bool {
    guard let selectedNodeID, let target = declaration(for: selectedNodeID) else { return false }
    return selection(for: target, preferredSide: .after) != nil
  }

  // MARK: - User Actions

  func showUnchangedTapped() { showsUnchanged.toggle() }
  func zoomInTapped() { zoom = min(1.5, zoom + 0.1) }
  func zoomOutTapped() { zoom = max(0.1, zoom - 0.1) }
  func viewportChanged(width: CGFloat, height: CGFloat) {
    viewportSize = CGSize(width: width, height: height)
  }

  func fitTreeTapped() {
    guard canvasSize.width > 0, canvasSize.height > 0, viewportSize.width > 0,
      viewportSize.height > 0
    else { return }
    let widthScale = viewportSize.width / canvasSize.width
    let heightScale = viewportSize.height / canvasSize.height
    zoom = min(1.5, min(widthScale, heightScale))
  }

  func zoomToSelectionTapped() {
    guard let selectedNodeID, nodes.contains(where: { $0.id == selectedNodeID }) else { return }
    zoom = max(1, zoom)
    focusedNodeID = selectedNodeID
    focusRequest += 1
  }

  func declarationTapped(_ id: String) {
    guard let target = declaration(for: id) else { return }
    selectedNodeID = id
    sourceSelection =
      selection(for: target, preferredSide: .after)
      ?? selection(for: target, preferredSide: .before)
  }

  func sourceSideTapped(_ side: FunctionSourceSelection.Side) {
    guard let selectedNodeID, let target = declaration(for: selectedNodeID) else { return }
    if let next = selection(for: target, preferredSide: side) { sourceSelection = next }
  }

  @discardableResult
  func pageReceived(_ page: InterfaceComparison) -> Bool {
    guard !lastPage.page.complete,
      page.sessionID == firstPage.sessionID,
      page.beforeSeq == firstPage.beforeSeq,
      page.afterSeq == firstPage.afterSeq,
      let cursor = lastPage.page.nextAfterPath,
      let firstPath = page.files.first?.path,
      firstPath.utf16.lexicographicallyPrecedes(cursor.utf16) == false,
      firstPath != cursor,
      !page.files.contains(where: { file in allFiles.contains(where: { $0.path == file.path }) })
    else { return false }
    pages.append(page)
    return true
  }

  // MARK: - Private Helpers

  private var visibleFiles: [InterfaceFileResult] {
    allFiles.filter { file in
      guard showsUnchanged || file.status != .identical else { return false }
      guard !searchText.isEmpty else { return true }
      return file.path.localizedCaseInsensitiveContains(searchText)
        || changes(in: file).contains {
          displayName(of: $0).localizedCaseInsensitiveContains(searchText)
        }
    }
  }

  private func isNotCompared(_ file: InterfaceFileResult) -> Bool {
    if case .unsupportedLanguageVersion = file.changes { return true }
    switch file.status {
    case .ready, .identical: return false
    case .incomplete, .unavailable, .unsupported, .skipped: return true
    }
  }

  private func changes(in file: InterfaceFileResult) -> [InterfaceChange] {
    guard file.status == .ready else { return [] }
    switch file.changes {
    case .typescript(let changes), .swift(let changes): return changes
    case .noLanguageModule, .unsupportedLanguageVersion: return []
    }
  }

  private func displayName(of change: InterfaceChange) -> String {
    switch change.kind {
    case .added(let after): after.displayName
    case .removed(let before): before.displayName
    case .signatureChanged(_, let after): after.displayName
    }
  }

  private func declaration(for id: String) -> (InterfaceFileResult, InterfaceChange)? {
    for file in visibleFiles {
      for (index, change) in changes(in: file).enumerated()
      where "declaration:\(file.path):\(index)" == id {
        return (file, change)
      }
    }
    return nil
  }

  private func selection(
    for target: (InterfaceFileResult, InterfaceChange), preferredSide: FunctionSourceSelection.Side
  ) -> FunctionSourceSelection? {
    let (file, change) = target
    let declaration: InterfaceDeclaration
    let record: InterfaceRecord
    switch preferredSide {
    case .before:
      guard case .recorded(let before) = file.before, case .content = before.snapshot else {
        return nil
      }
      record = before
      switch change.kind {
      case .removed(let value), .signatureChanged(let value, _): declaration = value
      case .added: return nil
      }
    case .after:
      guard case .content = file.after.snapshot else { return nil }
      record = file.after
      switch change.kind {
      case .added(let value), .signatureChanged(_, let value): declaration = value
      case .removed: return nil
      }
    }
    guard case .content(let sha256, _) = record.snapshot else { return nil }
    let languageVersion: String
    switch file.changes {
    case .typescript: languageVersion = "typescript.v2"
    case .swift: languageVersion = "swift.v1"
    case .noLanguageModule, .unsupportedLanguageVersion: return nil
    }
    return FunctionSourceSelection(
      sessionID: firstPage.sessionID, beforeSeq: firstPage.beforeSeq, afterSeq: firstPage.afterSeq,
      path: file.path, side: preferredSide, sha256: sha256, byteRange: declaration.byteRange,
      projectionVersion: InterfaceComparison.projectionVersion, languageVersion: languageVersion,
      identity: change.identity
    )
  }

  private struct Tree {
    let nodes: [FunctionChangeNode]
    let size: CGSize
  }
  private struct Draft {
    let id: String
    let parentID: String?
    let kind: FunctionChangeNode.Kind
    let title: String
    let statusText: String?
    let lines: [FunctionChangeLine]
    let marker: FunctionChangeLine.Mark?
    let depth: Int
    let ownChange: Int
    let ownUnknown: Int
  }

  private var tree: Tree {
    let files = visibleFiles
    guard !files.isEmpty else { return Tree(nodes: [], size: CGSize(width: 900, height: 430)) }
    var drafts: [Draft] = [
      Draft(
        id: "root", parentID: nil, kind: .root, title: "Observed files", statusText: nil, lines: [],
        marker: nil, depth: 0, ownChange: 0, ownUnknown: 0)
    ]
    var directoryIDs: Set<String> = []
    let maxDirectoryDepth = files.map { max(0, $0.path.split(separator: "/").count - 1) }.max() ?? 0
    for file in files {
      let parts = file.path.split(separator: "/").map(String.init)
      var parent = "root"
      for (index, part) in parts.dropLast().enumerated() {
        let id = "directory:" + parts[...index].joined(separator: "/")
        if directoryIDs.insert(id).inserted {
          drafts.append(
            Draft(
              id: id, parentID: parent, kind: .directory, title: part, statusText: nil, lines: [],
              marker: nil, depth: index + 1, ownChange: 0, ownUnknown: 0))
        }
        parent = id
      }
      let fileID = "file:\(file.path)"
      let changes = changes(in: file)
      let unknown = isNotCompared(file)
      drafts.append(
        Draft(
          id: fileID, parentID: parent, kind: .file, title: parts.last ?? file.path,
          statusText: fileStatusText(file), lines: [], marker: nil, depth: maxDirectoryDepth + 1,
          ownChange: 0, ownUnknown: unknown ? 1 : 0))
      for (index, change) in changes.enumerated()
      where searchText.isEmpty || file.path.localizedCaseInsensitiveContains(searchText)
        || displayName(of: change).localizedCaseInsensitiveContains(searchText)
      {
        let marker: FunctionChangeLine.Mark =
          switch change.kind {
          case .added: .added
          case .removed: .removed
          case .signatureChanged: .changed
          }
        drafts.append(
          Draft(
            id: "declaration:\(file.path):\(index)", parentID: fileID,
            kind: .declaration, title: displayName(of: change), statusText: nil,
            lines: lines(for: change), marker: marker, depth: maxDirectoryDepth + 2,
            ownChange: 1, ownUnknown: 0))
      }
    }
    let children = Dictionary(
      grouping: drafts.compactMap { draft -> (String, String)? in
        guard let parentID = draft.parentID else { return nil }
        return (parentID, draft.id)
      }, by: { $0.0 }
    ).mapValues { $0.map(\.1) }
    var centers: [String: CGFloat] = [:]
    var nextLeaf: CGFloat = 180
    func center(_ id: String) -> CGFloat {
      if let value = centers[id] { return value }
      let childIDs = children[id] ?? []
      if childIDs.isEmpty {
        let value = nextLeaf
        nextLeaf += 300
        centers[id] = value
        return value
      }
      let values = childIDs.map(center)
      let value = (values.first! + values.last!) / 2
      centers[id] = value
      return value
    }
    _ = center("root")
    var totals: [String: (Int, Int)] = [:]
    func total(_ id: String) -> (Int, Int) {
      if let value = totals[id] { return value }
      let draft = drafts.first { $0.id == id }!
      let descendants = (children[id] ?? []).map(total)
      let result = (
        draft.ownChange + descendants.reduce(0) { $0 + $1.0 },
        draft.ownUnknown + descendants.reduce(0) { $0 + $1.1 }
      )
      totals[id] = result
      return result
    }
    _ = total("root")
    let canvasWidth = max(900, nextLeaf - 120)
    let horizontalOffset = (canvasWidth - (nextLeaf - 120)) / 2
    let nodes = drafts.map { draft in
      let height: CGFloat =
        draft.kind == .declaration ? max(185, CGFloat(draft.lines.count) * 22 + 74) : 58
      let width: CGFloat = draft.kind == .declaration ? 270 : 190
      let count = totals[draft.id] ?? (0, 0)
      return FunctionChangeNode(
        id: draft.id, parentID: draft.parentID, kind: draft.kind,
        title: draft.title, statusText: draft.statusText, lines: draft.lines,
        changedCount: count.0, unknownCount: count.1, marker: draft.marker,
        x: (centers[draft.id] ?? 180) + horizontalOffset, y: CGFloat(draft.depth) * 106 + 30,
        width: width, height: height)
    }
    let bottom = nodes.map { $0.y + $0.height }.max() ?? 350
    return Tree(nodes: nodes, size: CGSize(width: canvasWidth, height: bottom + 80))
  }

  private func fileStatusText(_ file: InterfaceFileResult) -> String? {
    if case .unsupportedLanguageVersion(let language, let version) = file.changes {
      return "Unsupported language version: \(language) \(version)"
    }
    switch file.status {
    case .identical: return "No net change at recorded endpoints"
    case .ready: return changes(in: file).isEmpty ? "No detected interface change" : nil
    case .incomplete(let reason): return "Incomplete: \(reason)"
    case .unavailable(let reason): return "Unavailable: \(reason)"
    case .unsupported(let reason): return "Unsupported: \(reason)"
    case .skipped(let reason): return "Skipped: \(reason)"
    }
  }

  private func lines(for change: InterfaceChange) -> [FunctionChangeLine] {
    var lines: [FunctionChangeLine] = []
    if !change.parameters.isEmpty {
      lines.append(.init(mark: .note, text: "INPUTS"))
      for parameter in change.parameters { lines += deltaLines(parameter, format: parameterText) }
    }
    if let result = change.result {
      lines.append(.init(mark: .note, text: "OUTPUT"))
      lines += deltaLines(result, format: resultText)
    }
    if case .equal(let clause) = change.throwsClause, clause.mode == .notExpressible {
      lines.append(.init(mark: .note, text: "Throws not expressible in TypeScript"))
    } else if case .equal(let clause) = change.throwsClause, clause.mode == .notWritten {
      lines.append(.init(mark: .note, text: "No declared throws"))
    } else {
      lines.append(.init(mark: .note, text: "DECLARED THROWS"))
      lines += deltaLines(change.throwsClause, format: throwsText)
    }
    if case .equal(let header) = change.header, header == InterfaceHeader() {
    } else {
      lines.append(.init(mark: .note, text: "HEADER"))
      lines += deltaLines(change.header, format: headerText)
    }
    return lines
  }

  private func deltaLines<Value>(_ delta: InterfaceDelta<Value>, format: (Value) -> String)
    -> [FunctionChangeLine]
  {
    switch delta {
    case .equal(let value): [.init(mark: .equal, text: format(value))]
    case .added(let value): [.init(mark: .added, text: format(value))]
    case .removed(let value): [.init(mark: .removed, text: format(value))]
    case .changed(let before, let after):
      [
        .init(mark: .removed, text: format(before)),
        .init(mark: .added, text: format(after)),
      ]
    }
  }

  private func parameterText(_ value: InterfaceParameter) -> String {
    let label = value.label.map { "\($0) " } ?? ""
    let modifiers = value.modifiers.isEmpty ? "" : value.modifiers.joined(separator: " ") + " "
    let suffix = value.isOptional ? "?" : ""
    let variadic = value.isVariadic ? "..." : ""
    let defaultValue = value.defaultValue.map { " = \($0)" } ?? ""
    return
      "\(modifiers)\(label)\(variadic)\(value.name)\(suffix): \(typeText(value.type))\(defaultValue)"
  }

  private func typeText(_ value: InterfaceTypeReference) -> String {
    switch value {
    case .written(let text): text
    case .implicit(let text): "\(text) (implicit)"
    case .inferredNotComputed: "type inferred, not computed"
    }
  }

  private func resultText(_ value: InterfaceResult) -> String {
    switch value {
    case .returnType(let type): typeText(type)
    case .initializer(nil): "Initializer"
    case .initializer(.optional): "Failable initializer (?)"
    case .initializer(.implicitlyUnwrapped): "Failable initializer (!)"
    }
  }

  private func throwsText(_ value: InterfaceThrowsClause) -> String {
    switch value.mode {
    case .notExpressible: "Throws not expressible in TypeScript"
    case .notWritten: "No declared throws"
    case .throwing: "throws" + (value.type.map { "(\($0))" } ?? "")
    case .rethrowing: "rethrows"
    }
  }

  private func headerText(_ value: InterfaceHeader) -> String {
    (value.modifiers + value.genericParameters + value.constraints).joined(separator: " · ")
  }
}
