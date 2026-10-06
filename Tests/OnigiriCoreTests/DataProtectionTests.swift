import Foundation
import Testing

@testable import OnigiriCore

private func temporaryVaultRoot() -> URL {
  FileManager.default.temporaryDirectory
    .appending(path: "onigiri-vault-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Test func storageMigrationCreatesSafetyCopyBeforeWritingMetadata() throws {
  let root = temporaryVaultRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let legacy = root.appending(path: "conversations.json")
  try Data(#"[{"title":"legacy"}]"#.utf8).write(to: legacy)

  let report = try OnigiriDataVault(rootURL: root).prepareStorage()

  #expect(report.migrated)
  #expect(report.formatVersion == OnigiriDataVault.currentFormatVersion)
  let copied = try #require(report.safetyCopyURL?.appending(path: "conversations.json"))
  #expect(FileManager.default.fileExists(atPath: copied.path))
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "storage-metadata.json").path))
}

@Test func backupRoundTripRestoresAllManagedJSONFiles() throws {
  let root = temporaryVaultRoot()
  let backup = root.deletingLastPathComponent()
    .appending(path: "onigiri-backup-\(UUID().uuidString).json")
  defer {
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.removeItem(at: backup)
  }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let knowledge = root.appending(path: "knowledge.json")
  let profiles = root.appending(path: "product-profiles.json")
  try Data(#"{"documents":["original"]}"#.utf8).write(to: knowledge)
  try Data(#"{"formatVersion":1,"profiles":[]}"#.utf8).write(to: profiles)
  let vault = OnigiriDataVault(rootURL: root)

  let created = try vault.createBackup(at: backup)
  try Data(#"{"documents":["changed"]}"#.utf8).write(to: knowledge, options: .atomic)
  try FileManager.default.removeItem(at: profiles)
  let restored = try vault.restoreBackup(from: backup)

  #expect(created.fileCount == restored.fileCount)
  #expect(String(decoding: try Data(contentsOf: knowledge), as: UTF8.self).contains("original"))
  #expect(FileManager.default.fileExists(atPath: profiles.path))
  #expect(vault.corruptJSONFiles().isEmpty)
}

@Test func backupRestoreRejectsInvalidDocumentsWithoutChangingCurrentData() throws {
  let root = temporaryVaultRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let current = root.appending(path: "conversations.json")
  try Data("[]".utf8).write(to: current)
  let invalid = root.appending(path: "invalid-backup.txt")
  try Data("{}".utf8).write(to: invalid)
  let vault = OnigiriDataVault(rootURL: root)

  #expect(throws: DataProtectionError.self) {
    try vault.restoreBackup(from: invalid)
  }
  #expect(String(decoding: try Data(contentsOf: current), as: UTF8.self) == "[]")
}

@Test func storageDiagnosticsReportsMalformedJSON() throws {
  let root = temporaryVaultRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try Data("not-json".utf8).write(to: root.appending(path: "broken.json"))
  #expect(OnigiriDataVault(rootURL: root).corruptJSONFiles() == ["broken.json"])
}

@Test func corruptStorageMetadataIsPreservedAndRecreated() throws {
  let root = temporaryVaultRoot()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let metadata = root.appending(path: "storage-metadata.json")
  try Data("broken".utf8).write(to: metadata)

  let report = try OnigiriDataVault(rootURL: root).prepareStorage()

  #expect(report.migrated)
  #expect((try FileManager.default.contentsOfDirectory(
    at: root.appending(path: "recovery"), includingPropertiesForKeys: nil))
    .contains { $0.lastPathComponent.hasPrefix("storage-metadata.json.") })
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
  #expect(object["formatVersion"] as? Int == OnigiriDataVault.currentFormatVersion)
}
