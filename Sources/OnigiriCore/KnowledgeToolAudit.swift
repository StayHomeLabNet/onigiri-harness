import Foundation

public enum KnowledgeToolAccess: String, Codable, Sendable {
  case readOnly
  case write
}

public struct KnowledgeToolAuditEntry: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let source: String
  public let toolName: String
  public let access: KnowledgeToolAccess
  public let requestSummary: String
  public let success: Bool
  public let durationMilliseconds: Int
  public let resultCount: Int?
  public let error: String?

  public init(
    id: UUID = UUID(), createdAt: Date = Date(), source: String, toolName: String,
    access: KnowledgeToolAccess, requestSummary: String, success: Bool,
    durationMilliseconds: Int, resultCount: Int? = nil, error: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.source = source
    self.toolName = toolName
    self.access = access
    self.requestSummary = String(requestSummary.prefix(500))
    self.success = success
    self.durationMilliseconds = max(0, durationMilliseconds)
    self.resultCount = resultCount
    self.error = error.map { String($0.prefix(1_000)) }
  }
}

public struct KnowledgeToolAuditResponse: Codable, Sendable, Equatable {
  public let entries: [KnowledgeToolAuditEntry]
  public init(entries: [KnowledgeToolAuditEntry]) { self.entries = entries }
}

public actor KnowledgeToolAuditLog {
  public static var defaultStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "knowledge-tool-audit.json")
  }

  private let storeURL: URL?
  private let maximumEntryCount: Int
  private var entries: [KnowledgeToolAuditEntry]

  public init(
    storeURL: URL? = KnowledgeToolAuditLog.defaultStoreURL, maximumEntryCount: Int = 500
  ) {
    self.storeURL = storeURL
    self.maximumEntryCount = max(1, maximumEntryCount)
    entries = storeURL.flatMap { try? Self.load(from: $0) } ?? []
  }

  public func list() -> KnowledgeToolAuditResponse {
    KnowledgeToolAuditResponse(entries: entries.sorted { $0.createdAt > $1.createdAt })
  }

  public func append(_ entry: KnowledgeToolAuditEntry) {
    entries.insert(entry, at: 0)
    if entries.count > maximumEntryCount {
      entries.removeLast(entries.count - maximumEntryCount)
    }
    save()
  }

  public func clear() -> KnowledgeToolAuditResponse {
    entries = []
    save()
    return KnowledgeToolAuditResponse(entries: [])
  }

  private func save() {
    guard let storeURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(entries).write(to: storeURL, options: .atomic)
    } catch {
      // Audit persistence failure must not prevent a read-only knowledge lookup.
    }
  }

  private static func load(from url: URL) throws -> [KnowledgeToolAuditEntry] {
    try JSONDecoder().decode([KnowledgeToolAuditEntry].self, from: Data(contentsOf: url))
  }
}
