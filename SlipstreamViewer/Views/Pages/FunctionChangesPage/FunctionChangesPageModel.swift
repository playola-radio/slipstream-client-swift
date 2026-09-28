import Foundation
import Observation
import SlipstreamCore
import SwiftUI

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

enum FunctionChangesDisplayMode: String, CaseIterable, Equatable {
  case map = "Map"
  case tree = "Tree"
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

struct FunctionMapGroup: Identifiable, Equatable {
  let id: String
  let directory: String
  let files: [FunctionMapFile]
  let changedCount: Int
  let unknownCount: Int

  var summaryText: String {
    let changes =
      changedCount == 1 ? "1 changed declaration" : "\(changedCount) changed declarations"
    if unknownCount == 0 { return changes }
    let unknown = unknownCount == 1 ? "1 file not compared" : "\(unknownCount) files not compared"
    if changedCount == 0 { return "\(unknown) · changes unknown" }
    return "\(changes) · \(unknown)"
  }
}

struct FunctionMapFile: Identifiable, Equatable {
  let id: String
  let path: String
  let name: String
  let changedCount: Int
  let isUnknown: Bool
  let rows: [FunctionMapRow]

  var summaryText: String {
    if isUnknown { return "Not compared" }
    return changedCount == 1 ? "1 changed declaration" : "\(changedCount) changed declarations"
  }
}

struct FunctionMapRow: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let label: String
  let marker: FunctionChangeLine.Mark?
  let inputLines: [FunctionChangeLine]
  let outputLines: [FunctionChangeLine]
  let headerLines: [FunctionChangeLine]
  let statusText: String?
}

struct FunctionMapStat: Equatable {
  let value: String
  let label: String
}

@MainActor
@Observable
final class FunctionChangesPageModel: ViewModel {
  // MARK: - Initialization

  init(
    comparison: InterfaceComparison,
    provenanceLabel: String? = "FIXTURE DEMO · Recorded example, not a live capture"
  ) {
    self.comparison = comparison
    self.provenanceLabel = provenanceLabel
    super.init()
  }

  // MARK: - Properties

  let comparison: InterfaceComparison
  let provenanceLabel: String?
  private(set) var displayMode: FunctionChangesDisplayMode = .map
  var modeSelection: FunctionChangesDisplayMode {
    get { displayMode }
    set { displayModeSelected(newValue) }
  }
  var searchText = "" { didSet { clearSelectionIfHidden() } }
  private(set) var showsUnchanged = false
  private(set) var selectedNodeID: String?
  private(set) var sourceSelection: FunctionSourceSelection?
  var scrollPosition = ScrollPosition()
  private(set) var zoom: CGFloat = 1
  private(set) var viewportSize = CGSize.zero

  private var hasDuplicatePaths: Bool {
    Set(comparison.files.map(\.path)).count != comparison.files.count
  }

  var detectedChanges: Int { comparison.files.reduce(0) { $0 + changes(in: $1).count } }
  var filesNotCompared: Int { comparison.files.filter(isNotCompared).count }
  var mapStats: [FunctionMapStat] {
    guard !hasDuplicatePaths, !comparison.files.isEmpty else { return [] }
    if case .skipped = comparison.status { return [] }
    let suffix =
      comparison.page.complete && filesNotCompared == 0
      ? "in observed files" : "in loaded files"
    let filesWithChanges = comparison.files.filter { !changes(in: $0).isEmpty }.count
    if filesNotCompared > 0 && detectedChanges == 0 {
      return [
        .init(value: "?", label: "changes unknown \(suffix)"),
        .init(value: "\(filesNotCompared)", label: "files not compared \(suffix)"),
      ]
    }
    return [
      .init(value: "\(detectedChanges)", label: "changed declarations \(suffix)"),
      .init(value: "\(filesWithChanges)", label: "files with changes \(suffix)"),
      .init(value: "\(filesNotCompared)", label: "files not compared \(suffix)"),
    ]
  }
  var nodes: [FunctionChangeNode] { tree.nodes }
  var mapGroups: [FunctionMapGroup] {
    var order: [String] = []
    var filesByDirectory: [String: [FunctionMapFile]] = [:]
    for file in visibleFiles {
      let parts = file.path.split(separator: "/").map(String.init)
      let directory = parts.dropLast().isEmpty ? "/" : parts.dropLast().joined(separator: "/")
      if filesByDirectory[directory] == nil {
        order.append(directory)
        filesByDirectory[directory] = []
      }
      let changes = changes(in: file)
      let isSwift: Bool
      if case .swift = file.changes { isSwift = true } else { isSwift = false }
      var rows = changes.enumerated().compactMap { index, change -> FunctionMapRow? in
        guard matchesSearch(change, in: file) else { return nil }
        let marker: FunctionChangeLine.Mark =
          switch change.kind {
          case .added: .added
          case .removed: .removed
          case .signatureChanged: .changed
          }
        return FunctionMapRow(
          id: "declaration:\(file.path):\(index)", title: displayName(of: change),
          subtitle: mapSubtitle(for: change), label: mapLabel(for: change), marker: marker,
          inputLines: parameterLines(for: change, isSwift: isSwift),
          outputLines: resultLines(for: change) + throwsLines(for: change),
          headerLines: headerLines(for: change), statusText: nil)
      }
      if rows.isEmpty {
        rows = [
          FunctionMapRow(
            id: "status:\(file.path)", title: parts.last ?? file.path, subtitle: "", label: "",
            marker: nil, inputLines: [], outputLines: [], headerLines: [],
            statusText: fileStatusText(file) ?? "No detected interface change")
        ]
      }
      filesByDirectory[directory, default: []].append(
        FunctionMapFile(
          id: "map-file:\(file.path)", path: file.path, name: parts.last ?? file.path,
          changedCount: rows.filter { $0.marker != nil }.count, isUnknown: isNotCompared(file),
          rows: rows))
    }
    return order.map { directory in
      let files = filesByDirectory[directory] ?? []
      return FunctionMapGroup(
        id: "map-directory:\(directory)", directory: directory, files: files,
        changedCount: files.reduce(0) { $0 + $1.changedCount },
        unknownCount: files.filter(\.isUnknown).count)
    }
  }
  var canvasSize: CGSize { tree.size }
  var edges: [(CGPoint, CGPoint)] {
    let currentNodes = nodes
    let positions = Dictionary(uniqueKeysWithValues: currentNodes.map { ($0.id, $0) })
    return currentNodes.compactMap { node in
      guard let parentID = node.parentID, let parent = positions[parentID] else { return nil }
      return (CGPoint(x: parent.x, y: parent.y + parent.height), CGPoint(x: node.x, y: node.y))
    }
  }

  // MARK: - Display Text

  var titleText: String {
    showsMap ? "A map of changing contracts." : "See where the change lives."
  }
  var subtitleText: String {
    showsMap
      ? "Follow recorded function inputs and outputs through observed files."
      : "Follow recorded function input and output changes in observed files."
  }
  let analysisText = "Shared types, effects and behavior: not analyzed"
  let scopeText = "Observed files"
  let searchPrompt = "Find loaded file or function"
  let legendText = "Number = changed declarations in loaded files"
  let screenLabel = "FUNCTION CHANGES"
  let beforeButtonText = "Before"
  let afterButtonText = "After"
  let coverageText =
    "Observed files exclude the store directory, .git and symlinks. Lines show containment; the comparison covers recorded endpoints, not every intermediate edit."
  let zoomHintText = "Zoom out for branch counts. Zoom in to read inline contracts."
  let modePickerText = "View"
  let mapCodeTreeHeading = "CODE TREE"
  let mapInputsHeading = "INPUTS"
  let mapFunctionHeading = "FUNCTION"
  let mapOutputsHeading = "OUTPUTS"
  let mapEffectsHeading = "POSSIBLE EFFECTS · NOT ANALYZED"
  let mapModeLabel = "CONTRACT MAP"
  let mapArrowText = "→"
  let mapEmptyCellText = "—"

  var boundaryText: String {
    "Recorded at #\(comparison.beforeSeq.decimal) → Recorded at #\(comparison.afterSeq.decimal)"
  }

  var summaryText: String {
    if hasDuplicatePaths { return "Comparison unavailable: duplicate file path" }
    if case .skipped = comparison.status { return "Comparison skipped · changes unknown" }
    let count = detectedChanges
    let noun = count == 1 ? "change" : "changes"
    let coverage = comparison.page.complete ? "" : " in loaded files"
    let failures = filesNotCompared
    if count == 0, failures > 0 {
      let failedNoun = failures == 1 ? "file" : "files"
      let known =
        comparison.files.count > failures
        ? "No changes detected in compared files" : "Changes unknown"
      return "\(known) · \(failures) \(failedNoun) not compared"
    }
    if count == 0, !comparison.page.complete {
      return "No changes detected in loaded files · more files may exist"
    }
    if failures > 0 {
      return
        "\(count) detected \(noun)\(coverage) · \(failures) \(failures == 1 ? "file" : "files") not compared"
    }
    return "\(count) detected \(noun)\(coverage)"
  }

  var noticeText: String {
    var notes: [String] = []
    if case .skipped(let reason) = comparison.status {
      notes.append("Page skipped: \(reason.rawValue)")
    }
    if !comparison.page.complete {
      notes.append("More files may exist; counts and search cover loaded data only")
    }
    if comparison.inventory.baselineCompletedSeq == nil {
      notes.append("Baseline inventory was incomplete")
    }
    if !comparison.inventory.unknownScopes.isEmpty {
      let scopes = comparison.inventory.unknownScopes
      let shown = scopes.prefix(3).joined(separator: ", ")
      let remainder = scopes.count > 3 ? " and \(scopes.count - 3) more" : ""
      notes.append("Unknown observed scopes: \(shown)\(remainder)")
    }
    if !comparison.inventory.unknownScopesComplete {
      notes.append("Additional unknown scopes were omitted")
    }
    let gapSequences = comparison.gaps.prefix(3).map(\.seq.decimal)
    if !gapSequences.isEmpty {
      notes.append(
        "Capture gaps at #\(gapSequences.joined(separator: ", #")); intermediate edits may be missing"
      )
    }
    if !comparison.gapsComplete || comparison.gaps.count > 3 {
      notes.append("Additional capture gaps were omitted")
    }
    return notes.joined(separator: " · ")
  }

  var emptyStateText: String {
    if hasDuplicatePaths { return "Comparison unavailable: duplicate file path" }
    if case .skipped(let reason) = comparison.status {
      return "Page not compared: \(reason.rawValue)"
    }
    if comparison.files.isEmpty { return "No files listed at the recorded endpoints" }
    if searchText.isEmpty, canShowUnchanged, !showsUnchanged, visibleFiles.isEmpty {
      return "Identical endpoint files are hidden · Show unchanged branches to view them"
    }
    if visibleFiles.isEmpty { return "No loaded files match this view" }
    return ""
  }
  var canShowUnchanged: Bool { comparison.files.contains { $0.status == .identical } }
  var showUnchangedText: String {
    showsUnchanged ? "Hide unchanged branches" : "Show unchanged branches"
  }
  var selectionText: String {
    guard let sourceSelection else {
      return "Select a declaration to inspect its recorded source reference"
    }
    let side = sourceSelection.side == .after ? "After" : "Before"
    return
      "\(side) · \(sourceSelection.path) · SHA-256 \(sourceSelection.sha256) · UTF-8 bytes \(sourceSelection.byteRange.lowerBound)–\(sourceSelection.byteRange.upperBound)"
  }
  var zoomText: String { "\(Int((zoom * 100).rounded()))%" }
  var showsMap: Bool { displayMode == .map }
  var showsTreeControls: Bool { displayMode == .tree }
  var showsInlineContracts: Bool { zoom >= 0.7 }
  var canSelectBefore: Bool {
    guard let selectedNodeID, let target = declaration(for: selectedNodeID) else { return false }
    return selection(for: target, preferredSide: .before) != nil
  }
  var canSelectAfter: Bool {
    guard let selectedNodeID, let target = declaration(for: selectedNodeID) else { return false }
    return selection(for: target, preferredSide: .after) != nil
  }
  var canZoomToSelection: Bool {
    guard let selectedNodeID else { return false }
    return nodes.contains { $0.id == selectedNodeID }
  }
  var selectionScrollPoint: CGPoint? {
    guard let selectedNodeID,
      let node = nodes.first(where: { $0.id == selectedNodeID }),
      viewportSize.width > 0, viewportSize.height > 0
    else { return nil }
    return CGPoint(
      x: max(0, node.x * zoom - viewportSize.width / 2),
      y: max(0, (node.y + node.height / 2) * zoom - viewportSize.height / 2)
    )
  }

  // MARK: - User Actions

  func displayModeSelected(_ mode: FunctionChangesDisplayMode) { displayMode = mode }

  func showUnchangedTapped() {
    guard canShowUnchanged else { return }
    showsUnchanged.toggle()
    clearSelectionIfHidden()
  }
  func zoomInTapped() { zoom = min(1.5, zoom + 0.1) }
  func zoomOutTapped() { zoom = min(zoom, max(0.1, zoom * 0.8)) }
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
    guard canZoomToSelection else { return }
    zoom = max(1, zoom)
    if let point = selectionScrollPoint { scrollPosition.scrollTo(point: point) }
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

  // MARK: - Private Helpers

  private var visibleFiles: [InterfaceFileResult] {
    guard !hasDuplicatePaths else { return [] }
    return comparison.files.filter { file in
      guard showsUnchanged || file.status != .identical else { return false }
      guard !searchText.isEmpty else { return true }
      return file.path.localizedCaseInsensitiveContains(searchText)
        || changes(in: file).contains {
          displayName(of: $0).localizedCaseInsensitiveContains(searchText)
        }
    }
  }

  private func clearSelectionIfHidden() {
    guard let selectedNodeID, declaration(for: selectedNodeID) == nil else { return }
    self.selectedNodeID = nil
    sourceSelection = nil
  }

  private func isNotCompared(_ file: InterfaceFileResult) -> Bool {
    if file.status == .identical { return false }
    switch file.changes {
    case .noLanguageModule, .unsupportedLanguageVersion: return true
    case .typescript, .swift: break
    }
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
      where "declaration:\(file.path):\(index)" == id && matchesSearch(change, in: file) {
        return (file, change)
      }
    }
    return nil
  }

  private func matchesSearch(_ change: InterfaceChange, in file: InterfaceFileResult) -> Bool {
    searchText.isEmpty || file.path.localizedCaseInsensitiveContains(searchText)
      || displayName(of: change).localizedCaseInsensitiveContains(searchText)
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
    guard case .content(let sha256, let size) = record.snapshot,
      declaration.byteRange.upperBound <= size
    else { return nil }
    guard let languageVersion = file.changes.languageVersion else { return nil }
    return FunctionSourceSelection(
      sessionID: comparison.sessionID, beforeSeq: comparison.beforeSeq,
      afterSeq: comparison.afterSeq,
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
      let isSwift: Bool
      if case .swift = file.changes { isSwift = true } else { isSwift = false }
      drafts.append(
        Draft(
          id: fileID, parentID: parent, kind: .file, title: parts.last ?? file.path,
          statusText: fileStatusText(file), lines: [], marker: nil, depth: maxDirectoryDepth + 1,
          ownChange: 0, ownUnknown: unknown ? 1 : 0))
      for (index, change) in changes.enumerated() where matchesSearch(change, in: file) {
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
            lines: showsInlineContracts ? lines(for: change, isSwift: isSwift) : [],
            marker: marker, depth: maxDirectoryDepth + 2,
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
    let draftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    var totals: [String: (Int, Int)] = [:]
    func total(_ id: String) -> (Int, Int) {
      if let value = totals[id] { return value }
      let draft = draftsByID[id]!
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
      let height: CGFloat
      if draft.kind == .declaration {
        height = draft.lines.isEmpty ? 58 : max(185, min(350, CGFloat(draft.lines.count) * 22 + 74))
      } else if draft.kind == .file, draft.statusText != nil {
        height = 82
      } else {
        height = 58
      }
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
    switch file.status {
    case .identical: return "No net change at recorded endpoints"
    case .ready:
      if case .unsupportedLanguageVersion(let language, let version) = file.changes {
        return "Unsupported language version: \(language) \(version)"
      }
      if case .noLanguageModule = file.changes { return "Unsupported language" }
      return changes(in: file).isEmpty ? "No detected interface change" : nil
    case .incomplete(let reason): return "Incomplete: \(reason)"
    case .unavailable(let reason): return "Unavailable: \(reason)"
    case .unsupported(let reason): return "Unsupported: \(reason)"
    case .skipped(let reason): return "Skipped: \(reason)"
    }
  }

  private func lines(for change: InterfaceChange, isSwift: Bool) -> [FunctionChangeLine] {
    var lines: [FunctionChangeLine] = []
    if !change.parameters.isEmpty {
      lines.append(.init(mark: .note, text: "INPUTS"))
      lines += parameterLines(for: change, isSwift: isSwift)
    }
    if change.result != nil {
      lines.append(.init(mark: .note, text: "OUTPUT"))
      lines += resultLines(for: change)
    }
    if hasNoDeclaredThrows(change.throwsClause) {
      lines += throwsLines(for: change)
    } else {
      lines.append(.init(mark: .note, text: "DECLARED THROWS"))
      lines += throwsLines(for: change)
    }
    let headerRows = headerLines(for: change)
    if !headerRows.isEmpty {
      lines.append(.init(mark: .note, text: "HEADER"))
      lines += headerRows
    }
    return lines
  }

  private func parameterLines(for change: InterfaceChange, isSwift: Bool)
    -> [FunctionChangeLine]
  {
    change.parameters.flatMap { deltaLines($0) { parameterText($0, isSwift: isSwift) } }
  }

  private func resultLines(for change: InterfaceChange) -> [FunctionChangeLine] {
    guard let result = change.result else { return [] }
    return deltaLines(result, format: resultText)
  }

  private func throwsLines(for change: InterfaceChange) -> [FunctionChangeLine] {
    let rows = deltaLines(change.throwsClause, format: throwsText)
    if hasNoDeclaredThrows(change.throwsClause) {
      return rows.last.map { [.init(mark: .note, text: $0.text)] } ?? []
    }
    return rows
  }

  private func headerLines(for change: InterfaceChange) -> [FunctionChangeLine] {
    deltaLines(change.header, format: headerText).filter { !$0.text.isEmpty }
  }

  private func mapLabel(for change: InterfaceChange) -> String {
    switch change.kind {
    case .added: return "Added"
    case .removed: return "Removed"
    case .signatureChanged:
      var parts: [String] = []
      if change.parameters.contains(where: { isChanged($0) }) { parts.append("Inputs") }
      if let result = change.result, isChanged(result) { parts.append("Output") }
      if isChanged(change.throwsClause) { parts.append("Throws") }
      if isChanged(change.header) { parts.append("Header") }
      return parts.joined(separator: " + ") + " changed"
    }
  }

  private func mapSubtitle(for change: InterfaceChange) -> String {
    let header: InterfaceHeader =
      switch change.header {
      case .equal(let value), .added(let value), .removed(let value): value
      case .changed(_, let after): after
      }

    return
      ([change.identity.kind]
      + change.identity.guards.map { "#if \($0)" }
      + header.modifiers).joined(separator: " · ")
  }

  private func isChanged<Value>(_ delta: InterfaceDelta<Value>) -> Bool {
    if case .equal = delta { return false }
    return true
  }

  private func hasNoDeclaredThrows(_ delta: InterfaceDelta<InterfaceThrowsClause>) -> Bool {
    func isAbsent(_ clause: InterfaceThrowsClause) -> Bool {
      clause.mode == .notExpressible || clause.mode == .notWritten
    }
    switch delta {
    case .equal(let clause), .added(let clause), .removed(let clause): return isAbsent(clause)
    case .changed(let before, let after): return isAbsent(before) && isAbsent(after)
    }
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

  private func parameterText(_ value: InterfaceParameter, isSwift: Bool) -> String {
    let label = value.label.map { "\($0) " } ?? ""
    let modifiers = value.modifiers.isEmpty ? "" : value.modifiers.joined(separator: " ") + " "
    let suffix = value.isOptional ? "?" : ""
    let prefix = value.isVariadic && !isSwift ? "..." : ""
    let typeSuffix = value.isVariadic && isSwift ? "..." : ""
    let defaultValue = value.defaultValue.map { " = \($0)" } ?? ""
    return
      "\(modifiers)\(label)\(prefix)\(value.name)\(suffix): \(typeText(value.type))\(typeSuffix)\(defaultValue)"
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
