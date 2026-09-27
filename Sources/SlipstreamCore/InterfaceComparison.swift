import Foundation

public enum InterfaceDecodingError: Error, Equatable, Sendable {
  case unsupportedProjectionVersion(String)
  case malformed(String)
}

public struct InterfaceComparison: Equatable, Sendable {
  public static let projectionVersion = "interface.v2"

  public enum Status: Equatable, Sendable {
    case ready
    case partial
    case skipped(SkipReason)
  }

  public enum SkipReason: String, Equatable, Sendable, Decodable {
    case overloaded
    case timeout
    case cancelled
    case scanLimit = "scan-limit"
  }

  public var sessionID: String
  public var beforeSeq: Seq
  public var afterSeq: Seq
  public var status: Status
  public var inventory: InterfaceInventory
  public var gaps: [InterfaceGap]
  public var gapsComplete: Bool
  public var files: [InterfaceFileResult]
  public var page: InterfacePage

  public init(
    sessionID: String,
    beforeSeq: Seq,
    afterSeq: Seq,
    status: Status,
    inventory: InterfaceInventory,
    gaps: [InterfaceGap],
    gapsComplete: Bool,
    files: [InterfaceFileResult],
    page: InterfacePage
  ) {
    self.sessionID = sessionID
    self.beforeSeq = beforeSeq
    self.afterSeq = afterSeq
    self.status = status
    self.inventory = inventory
    self.gaps = gaps
    self.gapsComplete = gapsComplete
    self.files = files
    self.page = page
  }

  public static func decode(_ data: Data) throws(InterfaceDecodingError) -> InterfaceComparison {
    do {
      return try JSONDecoder().decode(InterfaceComparison.self, from: data)
    } catch let error as InterfaceDecodingError {
      throw error
    } catch let error as DecodingError {
      throw .malformed(error.summary)
    } catch {
      throw .malformed(String(describing: error))
    }
  }
}

public struct InterfaceInventory: Equatable, Sendable {
  public var baselineCompletedSeq: Seq?
  public var unknownScopes: [String]
  public var unknownScopesComplete: Bool

  public init(baselineCompletedSeq: Seq?, unknownScopes: [String], unknownScopesComplete: Bool) {
    self.baselineCompletedSeq = baselineCompletedSeq
    self.unknownScopes = unknownScopes
    self.unknownScopesComplete = unknownScopesComplete
  }
}

public struct InterfaceGap: Equatable, Sendable {
  public enum Reason: String, Equatable, Sendable, Decodable {
    case coalesced
    case baselineUnreadable = "baseline-unreadable"
    case watcherError = "watcher-error"
    case restart
    case storage
  }

  public var seq: Seq
  public var reason: Reason
  public var scope: CaptureGap.Scope

  public init(seq: Seq, reason: Reason, scope: CaptureGap.Scope) {
    self.seq = seq
    self.reason = reason
    self.scope = scope
  }
}

public struct InterfacePage: Equatable, Sendable {
  public var complete: Bool
  public var nextAfterPath: String?

  public init(complete: Bool, nextAfterPath: String?) {
    self.complete = complete
    self.nextAfterPath = nextAfterPath
  }
}

public enum InterfaceEndpoint: Equatable, Sendable {
  case recorded(InterfaceRecord)
  case unknownBoundary
}

public struct InterfaceRecord: Equatable, Sendable {
  public enum Field: String, Equatable, Sendable, Decodable {
    case snapshot
    case before
    case after
  }

  public enum Observation: String, Equatable, Sendable, Decodable {
    case watcher
    case reconciliation
  }

  public var recordSeq: Seq
  public var field: Field
  public var snapshot: Snapshot
  public var observation: Observation?
  public var gapRef: Seq?

  public init(recordSeq: Seq, field: Field, snapshot: Snapshot, observation: Observation? = nil, gapRef: Seq? = nil) {
    self.recordSeq = recordSeq
    self.field = field
    self.snapshot = snapshot
    self.observation = observation
    self.gapRef = gapRef
  }
}

public enum InterfaceCoverage: Equatable, Sendable {
  case complete
  case absent
  case incomplete(reason: String)
  case unavailable(reason: String)
  case unsupported
  case notEvaluated
}

public struct InterfaceFileResult: Equatable, Sendable {
  public enum Status: Equatable, Sendable {
    case identical
    case ready
    case incomplete(reason: String)
    case unavailable(reason: String)
    case unsupported(reason: String)
    case skipped(reason: String)
  }

  public enum Changes: Equatable, Sendable {
    case typescript([InterfaceChange])
    case swift([InterfaceChange])
    case noLanguageModule
    case unsupportedLanguageVersion(language: String, version: String)
  }

  public var path: String
  public var before: InterfaceEndpoint
  public var after: InterfaceRecord
  public var status: Status
  public var beforeCoverage: InterfaceCoverage
  public var afterCoverage: InterfaceCoverage
  public var changes: Changes

  public init(
    path: String,
    before: InterfaceEndpoint,
    after: InterfaceRecord,
    status: Status,
    beforeCoverage: InterfaceCoverage,
    afterCoverage: InterfaceCoverage,
    changes: Changes
  ) {
    self.path = path
    self.before = before
    self.after = after
    self.status = status
    self.beforeCoverage = beforeCoverage
    self.afterCoverage = afterCoverage
    self.changes = changes
  }
}

public struct InterfaceChange: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case added(after: InterfaceDeclaration)
    case removed(before: InterfaceDeclaration)
    case signatureChanged(before: InterfaceDeclaration, after: InterfaceDeclaration)
  }

  public var kind: Kind
  public var identity: InterfaceIdentity
  public var parameters: [InterfaceDelta<InterfaceParameter>]
  public var result: InterfaceDelta<InterfaceResult>?
  public var throwsClause: InterfaceDelta<InterfaceThrowsClause>
  public var header: InterfaceDelta<InterfaceHeader>

  public init(
    kind: Kind,
    identity: InterfaceIdentity,
    parameters: [InterfaceDelta<InterfaceParameter>],
    result: InterfaceDelta<InterfaceResult>?,
    throwsClause: InterfaceDelta<InterfaceThrowsClause>,
    header: InterfaceDelta<InterfaceHeader>
  ) {
    self.kind = kind
    self.identity = identity
    self.parameters = parameters
    self.result = result
    self.throwsClause = throwsClause
    self.header = header
  }
}

public struct InterfaceIdentity: Equatable, Sendable, Decodable {
  public struct Scope: Equatable, Sendable, Decodable {
    public var kind: String
    public var name: String

    public init(kind: String, name: String) {
      self.kind = kind
      self.name = name
    }
  }

  public var kind: String
  public var scope: [Scope]
  public var name: String
  public var guards: [String]

  public init(kind: String, scope: [Scope], name: String, guards: [String]) {
    self.kind = kind
    self.scope = scope
    self.name = name
    self.guards = guards
  }
}

public struct InterfaceDeclaration: Equatable, Sendable {
  public var displayName: String
  public var byteRange: Range<Int>

  public init(displayName: String, byteRange: Range<Int>) {
    self.displayName = displayName
    self.byteRange = byteRange
  }
}

public enum InterfaceDelta<Value: Equatable & Sendable>: Equatable, Sendable {
  case equal(Value)
  case added(Value)
  case removed(Value)
  case changed(before: Value, after: Value)
}

public struct InterfaceParameter: Equatable, Sendable {
  public enum Binding: String, Equatable, Sendable, Decodable {
    case identifier
    case pattern
    case wildcard
  }

  public var position: Int
  public var label: String?
  public var name: String
  public var binding: Binding
  public var type: InterfaceTypeReference
  public var isOptional: Bool
  public var isVariadic: Bool
  public var defaultValue: String?
  public var modifiers: [String]

  public init(
    position: Int,
    label: String? = nil,
    name: String,
    binding: Binding = .identifier,
    type: InterfaceTypeReference,
    isOptional: Bool = false,
    isVariadic: Bool = false,
    defaultValue: String? = nil,
    modifiers: [String] = []
  ) {
    self.position = position
    self.label = label
    self.name = name
    self.binding = binding
    self.type = type
    self.isOptional = isOptional
    self.isVariadic = isVariadic
    self.defaultValue = defaultValue
    self.modifiers = modifiers
  }
}

public enum InterfaceTypeReference: Equatable, Sendable {
  case written(String)
  case implicit(String)
  case inferredNotComputed
}

public enum InterfaceResult: Equatable, Sendable {
  public enum Failable: String, Equatable, Sendable, Decodable {
    case optional = "?"
    case implicitlyUnwrapped = "!"
  }

  case returnType(InterfaceTypeReference)
  case initializer(failable: Failable?)
}

public struct InterfaceThrowsClause: Equatable, Sendable {
  public enum Mode: String, Equatable, Sendable, Decodable {
    case notExpressible
    case notWritten = "none"
    case throwing = "throws"
    case rethrowing = "rethrows"
  }

  public var mode: Mode
  public var type: String?

  public init(mode: Mode, type: String? = nil) {
    self.mode = mode
    self.type = type
  }
}

public struct InterfaceHeader: Equatable, Sendable {
  public var modifiers: [String]
  public var genericParameters: [String]
  public var constraints: [String]

  public init(modifiers: [String] = [], genericParameters: [String] = [], constraints: [String] = []) {
    self.modifiers = modifiers
    self.genericParameters = genericParameters
    self.constraints = constraints
  }
}

// MARK: - Decoding

extension InterfaceComparison: Decodable {
  private enum CodingKeys: String, CodingKey {
    case projectionVersion = "projection_version"
    case sessionID = "session_id"
    case range, status, inventory, analysis, gaps, files, page
    case fallbackReason = "fallback_reason"
    case gapsComplete = "gaps_complete"
  }

  private enum RangeKeys: String, CodingKey {
    case beforeSeq = "before_seq"
    case afterSeq = "after_seq"
  }

  private enum AnalysisKeys: String, CodingKey, CaseIterable {
    case sharedTypes = "shared_types"
    case effects, behavior
  }

  private enum StatusName: String, Decodable {
    case ready, partial, skipped
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(String.self, forKey: .projectionVersion)
    guard version == Self.projectionVersion else {
      throw InterfaceDecodingError.unsupportedProjectionVersion(version)
    }
    sessionID = try container.decode(String.self, forKey: .sessionID)

    let range = try container.nestedContainer(keyedBy: RangeKeys.self, forKey: .range)
    beforeSeq = try range.decode(Seq.self, forKey: .beforeSeq)
    afterSeq = try range.decode(Seq.self, forKey: .afterSeq)
    guard beforeSeq <= afterSeq else { throw range.corrupt(.afterSeq, "after_seq precedes before_seq") }

    switch (
      try container.decode(StatusName.self, forKey: .status),
      try container.decodeIfContained(SkipReason.self, forKey: .fallbackReason)
    ) {
    case (.ready, nil): status = .ready
    case (.partial, nil): status = .partial
    case (.skipped, let reason?): status = .skipped(reason)
    default: throw container.corrupt(.fallbackReason, "fallback_reason must be present exactly when status is skipped")
    }

    inventory = try container.decode(InterfaceInventory.self, forKey: .inventory)
    let analysis = try container.nestedContainer(keyedBy: AnalysisKeys.self, forKey: .analysis)
    for key in AnalysisKeys.allCases {
      try analysis.decodeConstant("notAnalyzed", forKey: key)
    }
    gaps = try container.decode([InterfaceGap].self, forKey: .gaps)
    gapsComplete = try container.decode(Bool.self, forKey: .gapsComplete)
    files = try container.decode([InterfaceFileResult].self, forKey: .files)
    page = try container.decode(InterfacePage.self, forKey: .page)

    let settled = files.allSatisfy { $0.status == .identical || $0.status == .ready }
    switch status {
    case .ready where !settled:
      throw container.corrupt(.status, "a ready page lists only ready or identical files")
    case .partial where settled:
      throw container.corrupt(.status, "a partial page lists at least one unsettled file")
    case .skipped where !files.isEmpty || page.complete:
      throw container.corrupt(.status, "a skipped page has no files and is not complete")
    default:
      break
    }
  }
}

extension InterfaceInventory: Decodable {
  private enum CodingKeys: String, CodingKey {
    case scope
    case baselineCompletedSeq = "baseline_completed_seq"
    case unknownScopes = "unknown_scopes"
    case unknownScopesComplete = "unknown_scopes_complete"
    case policyExclusions = "policy_exclusions"
  }

  private enum PolicyExclusion: String, Decodable {
    case storeDirectory = "store-directory"
    case git = ".git"
    case symlinks
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try container.decodeConstant("observed", forKey: .scope)
    baselineCompletedSeq = try container.decodeNullable(PositiveSeq.self, forKey: .baselineCompletedSeq)?.seq
    unknownScopes = try container.decode([String].self, forKey: .unknownScopes)
    unknownScopesComplete = try container.decode(Bool.self, forKey: .unknownScopesComplete)
    _ = try container.decode([PolicyExclusion].self, forKey: .policyExclusions)
  }
}

extension InterfaceGap: Decodable {
  private enum CodingKeys: String, CodingKey {
    case seq, reason, scope
  }

  private enum ScopeKeys: String, CodingKey {
    case kind, path
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    seq = try container.decode(PositiveSeq.self, forKey: .seq).seq
    reason = try container.decode(Reason.self, forKey: .reason)
    let scope = try container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
    switch try scope.decode(String.self, forKey: .kind) {
    case "session": self.scope = .session
    case "directory": self.scope = .directory(try scope.decode(String.self, forKey: .path))
    case "path": self.scope = .path(try scope.decode(String.self, forKey: .path))
    default: throw scope.corrupt(.kind, "unknown gap scope kind")
    }
  }
}

extension InterfacePage: Decodable {
  private enum CodingKeys: String, CodingKey {
    case complete
    case nextAfterPath = "next_after_path"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    complete = try container.decode(Bool.self, forKey: .complete)
    nextAfterPath = try container.decodeNullable(String.self, forKey: .nextAfterPath)
    guard !complete || nextAfterPath == nil else {
      throw container.corrupt(.nextAfterPath, "a complete page has no cursor")
    }
  }
}

extension InterfaceEndpoint: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "recorded": self = .recorded(try InterfaceRecord(from: decoder))
    case "unknownBoundary": self = .unknownBoundary
    default: throw container.corrupt(.kind, "unknown endpoint kind")
    }
  }
}

extension InterfaceRecord: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind, field, snapshot, observation
    case recordSeq = "record_seq"
    case gapRef = "gap_ref"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try container.decodeConstant("recorded", forKey: .kind)
    recordSeq = try container.decode(PositiveSeq.self, forKey: .recordSeq).seq
    field = try container.decode(Field.self, forKey: .field)
    snapshot = try container.decode(RecordedSnapshot.self, forKey: .snapshot).snapshot
    observation = try container.decodeIfContained(Observation.self, forKey: .observation)
    gapRef = try container.decodeIfContained(PositiveSeq.self, forKey: .gapRef)?.seq
    guard (field == .snapshot) == (observation == nil) else {
      throw container.corrupt(.observation, "observation must be present exactly for a file.changed record")
    }
    guard gapRef == nil || observation != nil else {
      throw container.corrupt(.gapRef, "gap_ref is only copied from a file.changed record")
    }
  }
}

extension InterfaceCoverage: Decodable {
  private enum CodingKeys: String, CodingKey {
    case state, reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch (
      try container.decode(String.self, forKey: .state),
      try container.decodeIfContained(String.self, forKey: .reason)
    ) {
    case ("complete", nil): self = .complete
    case ("absent", nil): self = .absent
    case ("incomplete", let reason?): self = .incomplete(reason: reason)
    case ("unavailable", let reason?): self = .unavailable(reason: reason)
    case ("unsupported", nil): self = .unsupported
    case ("notEvaluated", nil): self = .notEvaluated
    default: throw container.corrupt(.state, "unknown coverage state, or reason present outside incomplete/unavailable")
    }
  }
}

extension InterfaceFileResult: Decodable {
  private enum CodingKeys: String, CodingKey {
    case path, before, after, language, status, coverage, changes
    case languageVersion = "language_version"
    case fallbackReason = "fallback_reason"
  }

  private enum CoverageKeys: String, CodingKey {
    case before, after
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    path = try container.decode(String.self, forKey: .path)
    before = try container.decode(InterfaceEndpoint.self, forKey: .before)
    after = try container.decode(InterfaceRecord.self, forKey: .after)

    switch (
      try container.decode(String.self, forKey: .status),
      try container.decodeIfContained(String.self, forKey: .fallbackReason)
    ) {
    case ("identical", nil): status = .identical
    case ("ready", nil): status = .ready
    case ("incomplete", let reason?): status = .incomplete(reason: reason)
    case ("unavailable", let reason?): status = .unavailable(reason: reason)
    case ("unsupported", let reason?): status = .unsupported(reason: reason)
    case ("skipped", let reason?): status = .skipped(reason: reason)
    default: throw container.corrupt(.status, "unknown file status, or fallback_reason present for identical/ready")
    }

    let coverage = try container.nestedContainer(keyedBy: CoverageKeys.self, forKey: .coverage)
    beforeCoverage = try coverage.decode(InterfaceCoverage.self, forKey: .before)
    afterCoverage = try coverage.decode(InterfaceCoverage.self, forKey: .after)

    switch (
      try container.decodeNullable(String.self, forKey: .language),
      try container.decodeNullable(String.self, forKey: .languageVersion)
    ) {
    case ("typescript", "typescript.v2"):
      changes = .typescript(try container.decode([InterfaceChange].self, forKey: .changes))
    case ("swift", "swift.v1"):
      changes = .swift(try container.decode([InterfaceChange].self, forKey: .changes))
    case (nil, nil):
      guard try container.decode([InterfaceChange].self, forKey: .changes).isEmpty else {
        throw container.corrupt(.changes, "a path with no language module has no changes")
      }
      changes = .noLanguageModule
    case (let language?, let version?):
      changes = .unsupportedLanguageVersion(language: language, version: version)
    default:
      throw container.corrupt(.languageVersion, "language and language_version must be null together")
    }

    if status != .ready, case .typescript(let rows) = changes, !rows.isEmpty {
      throw container.corrupt(.changes, "only a ready file carries changes")
    }
    if status != .ready, case .swift(let rows) = changes, !rows.isEmpty {
      throw container.corrupt(.changes, "only a ready file carries changes")
    }
  }
}

extension InterfaceChange: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind, identity, before, after, parameters, result, header
    case throwsClause = "throws"
  }

  private enum KindName: String, Decodable {
    case added, removed, signatureChanged
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kindName = try container.decode(KindName.self, forKey: .kind)
    switch (
      kindName,
      try container.decodeNullable(InterfaceDeclaration.self, forKey: .before),
      try container.decodeNullable(InterfaceDeclaration.self, forKey: .after)
    ) {
    case (.added, nil, let after?): kind = .added(after: after)
    case (.removed, let before?, nil): kind = .removed(before: before)
    case (.signatureChanged, let before?, let after?): kind = .signatureChanged(before: before, after: after)
    default: throw container.corrupt(.kind, "\(kindName.rawValue) row has the wrong declaration sides")
    }
    identity = try container.decode(InterfaceIdentity.self, forKey: .identity)
    parameters = try container.decode([InterfaceDelta<InterfaceParameter>].self, forKey: .parameters)
    result = try container.decodeNullable(InterfaceDelta<InterfaceResult>.self, forKey: .result)
    throwsClause = try container.decode(InterfaceDelta<InterfaceThrowsClause>.self, forKey: .throwsClause)
    header = try container.decode(InterfaceDelta<InterfaceHeader>.self, forKey: .header)

    let operations = parameters.map(\.operation) + [result?.operation, throwsClause.operation, header.operation].compactMap { $0 }
    switch kindName {
    case .added where operations.contains { $0 != .added }:
      throw container.corrupt(.kind, "every component of an added row must be added")
    case .removed where operations.contains { $0 != .removed }:
      throw container.corrupt(.kind, "every component of a removed row must be removed")
    case .signatureChanged where operations.allSatisfy { $0 == .equal }:
      throw container.corrupt(.kind, "signatureChanged with every component equal")
    default:
      break
    }
  }
}

extension InterfaceDeclaration: Decodable {
  private enum CodingKeys: String, CodingKey {
    case span
    case displayName = "display_name"
  }

  private enum SpanKeys: String, CodingKey {
    case byteStart = "byte_start"
    case byteEnd = "byte_end"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    displayName = try container.decode(String.self, forKey: .displayName)
    let span = try container.nestedContainer(keyedBy: SpanKeys.self, forKey: .span)
    let start = try span.decode(Int.self, forKey: .byteStart)
    let end = try span.decode(Int.self, forKey: .byteEnd)
    guard 0 <= start, start <= end else { throw span.corrupt(.byteEnd, "span must satisfy 0 <= byte_start <= byte_end") }
    byteRange = start..<end
  }
}

private enum InterfaceOperation: String, Decodable {
  case equal, added, removed, changed
}

extension InterfaceDelta {
  fileprivate var operation: InterfaceOperation {
    switch self {
    case .equal: .equal
    case .added: .added
    case .removed: .removed
    case .changed: .changed
    }
  }
}

extension InterfaceDelta: Decodable where Value: Decodable {
  private enum CodingKeys: String, CodingKey {
    case op, before, after
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let operation = try container.decode(InterfaceOperation.self, forKey: .op)
    switch (
      operation,
      try container.decodeNullable(Value.self, forKey: .before),
      try container.decodeNullable(Value.self, forKey: .after)
    ) {
    case (.equal, let before?, let after?) where before == after: self = .equal(before)
    case (.added, nil, let after?): self = .added(after)
    case (.removed, let before?, nil): self = .removed(before)
    case (.changed, let before?, let after?) where before != after: self = .changed(before: before, after: after)
    default: throw container.corrupt(.op, "\(operation.rawValue) does not fit the delta's sides")
    }
  }
}

extension InterfaceParameter: Decodable {
  private enum CodingKeys: String, CodingKey {
    case position, label, name, binding, type, optional, variadic, modifiers
    case defaultValue = "default"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    position = try container.decode(Int.self, forKey: .position)
    guard position >= 0 else { throw container.corrupt(.position, "position must be non-negative") }
    label = try container.decodeNullable(String.self, forKey: .label)
    name = try container.decode(String.self, forKey: .name)
    binding = try container.decode(Binding.self, forKey: .binding)
    type = try container.decode(InterfaceTypeReference.self, forKey: .type)
    isOptional = try container.decode(Bool.self, forKey: .optional)
    isVariadic = try container.decode(Bool.self, forKey: .variadic)
    defaultValue = try container.decodeNullable(String.self, forKey: .defaultValue)
    modifiers = try container.decode([String].self, forKey: .modifiers)
  }
}

extension InterfaceTypeReference: Decodable {
  private enum CodingKeys: String, CodingKey {
    case state, text, reason
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .state) {
    case "written": self = .written(try container.decode(String.self, forKey: .text))
    case "implicit": self = .implicit(try container.decode(String.self, forKey: .text))
    case "unknown":
      try container.decodeConstant("inferred-not-computed", forKey: .reason)
      self = .inferredNotComputed
    default: throw container.corrupt(.state, "unknown type reference state")
    }
  }
}

extension InterfaceResult: Decodable {
  private enum CodingKeys: String, CodingKey {
    case kind, type, failable
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "return": self = .returnType(try container.decode(InterfaceTypeReference.self, forKey: .type))
    case "initializer": self = .initializer(failable: try container.decodeNullable(Failable.self, forKey: .failable))
    default: throw container.corrupt(.kind, "unknown result kind")
    }
  }
}

extension InterfaceThrowsClause: Decodable {
  private enum CodingKeys: String, CodingKey {
    case mode, type
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(Mode.self, forKey: .mode)
    type = try container.decodeIfContained(String.self, forKey: .type)
  }
}

extension InterfaceHeader: Decodable {
  private enum CodingKeys: String, CodingKey {
    case modifiers, constraints
    case genericParameters = "generic_parameters"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    modifiers = try container.decode([String].self, forKey: .modifiers)
    genericParameters = try container.decode([String].self, forKey: .genericParameters)
    constraints = try container.decode([String].self, forKey: .constraints)
  }
}

private struct PositiveSeq: Decodable {
  let seq: Seq

  init(from decoder: any Decoder) throws {
    seq = try Seq(from: decoder)
    guard seq != .zero else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "seq must be positive"))
    }
  }
}

private struct RecordedSnapshot: Decodable {
  let snapshot: Snapshot

  private enum CodingKeys: String, CodingKey {
    case kind, sha256, size, reason
  }

  private enum UnavailableReason: String, Decodable {
    case oversize, unreadable, unstable
    case ioError = "io-error"
    case baselineUnknown = "baseline-unknown"
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(String.self, forKey: .kind) {
    case "content":
      let sha256 = try container.decode(String.self, forKey: .sha256)
      let size = try container.decode(Int.self, forKey: .size)
      guard sha256.utf8.count == 64, sha256.utf8.allSatisfy(\.isLowercaseHexDigit), size >= 0 else {
        throw container.corrupt(.sha256, "bad content snapshot")
      }
      snapshot = .content(sha256: sha256, size: size)
    case "absent":
      snapshot = .absent
    case "unavailable":
      snapshot = .unavailable(reason: try container.decode(UnavailableReason.self, forKey: .reason).rawValue)
    default:
      throw container.corrupt(.kind, "unknown snapshot kind")
    }
  }
}

extension KeyedDecodingContainer {
  fileprivate func decodeNullable<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
    guard contains(key) else {
      throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "required key may be null but not missing"))
    }
    return try decodeNil(forKey: key) ? nil : decode(type, forKey: key)
  }

  fileprivate func decodeIfContained<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T? {
    contains(key) ? try decode(type, forKey: key) : nil
  }

  fileprivate func decodeConstant(_ value: String, forKey key: Key) throws {
    guard try decode(String.self, forKey: key) == value else { throw corrupt(key, "must be \(value)") }
  }

  fileprivate func corrupt(_ key: Key, _ message: String) -> DecodingError {
    .dataCorruptedError(forKey: key, in: self, debugDescription: message)
  }
}

extension DecodingError {
  fileprivate var summary: String {
    switch self {
    case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
      return Self.describe(context.codingPath, context.debugDescription)
    case .keyNotFound(let key, let context):
      return Self.describe(context.codingPath + [key], "missing key")
    @unknown default:
      return String(describing: self)
    }
  }

  private static func describe(_ path: [any CodingKey], _ message: String) -> String {
    let location = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
    return location.isEmpty ? message : "\(location): \(message)"
  }
}
