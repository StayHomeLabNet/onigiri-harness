import Foundation
import Testing

@testable import OnigiriCore

@Test func knowledgeToolAuditPersistsBoundsAndClearsEntries() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-tool-audit-tests-\(UUID().uuidString)")
  let storeURL = directory.appending(path: "audit.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  let log = KnowledgeToolAuditLog(storeURL: storeURL, maximumEntryCount: 2)

  await log.append(
    KnowledgeToolAuditEntry(
      source: "mcp", toolName: "searchKnowledge", access: .readOnly,
      requestSummary: "最初", success: true, durationMilliseconds: 10, resultCount: 1))
  await log.append(
    KnowledgeToolAuditEntry(
      source: "mcp", toolName: "getKnowledgeChunk", access: .readOnly,
      requestSummary: "chunk-1", success: true, durationMilliseconds: 2, resultCount: 1))
  await log.append(
    KnowledgeToolAuditEntry(
      source: "mcp", toolName: "searchKnowledge", access: .readOnly,
      requestSummary: "最新", success: false, durationMilliseconds: 3,
      error: "検索失敗"))

  let entries = await log.list().entries
  #expect(entries.count == 2)
  #expect(entries.first?.requestSummary == "最新")
  #expect(entries.last?.toolName == "getKnowledgeChunk")

  let restored = KnowledgeToolAuditLog(storeURL: storeURL, maximumEntryCount: 2)
  #expect(await restored.list().entries == entries)
  #expect(await restored.clear().entries.isEmpty)
  #expect(await restored.list().entries.isEmpty)
}
