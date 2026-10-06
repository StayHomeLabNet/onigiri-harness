import CryptoKit
import Foundation
import Security

public struct StoragePreparationReport: Sendable, Equatable {
  public let formatVersion: Int
  public let migrated: Bool
  public let safetyCopyURL: URL?
  public let corruptFiles: [String]
}

public struct OnigiriBackupSummary: Sendable, Equatable {
  public let createdAt: Date
  public let fileCount: Int
  public let totalBytes: Int
}

public enum DataProtectionError: LocalizedError {
  case futureStorageVersion(Int)
  case invalidBackup(String)
  case checksumMismatch(String)
  case keychain(OSStatus)

  public var errorDescription: String? {
    switch self {
    case .futureStorageVersion(let version):
      return "このデータは新しい保存形式（version \(version)）で作成されています。"
    case .invalidBackup(let detail): return "バックアップを読み込めません: \(detail)"
    case .checksumMismatch(let name): return "バックアップ内の\(name)が破損しています。"
    case .keychain(let status): return "Keychain操作に失敗しました（\(status)）。"
    }
  }
}

public struct OnigiriDataVault: Sendable {
  public static let currentFormatVersion = 1

  public static var defaultRootURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
  }

  private struct StorageMetadata: Codable {
    let formatVersion: Int
    let migratedAt: Date
  }

  private struct BackupFile: Codable {
    let name: String
    let byteCount: Int
    let sha256: String
    let data: Data
  }

  private struct BackupEnvelope: Codable {
    let product: String
    let formatVersion: Int
    let createdAt: Date
    let files: [BackupFile]
  }

  public let rootURL: URL

  public init(rootURL: URL = OnigiriDataVault.defaultRootURL) { self.rootURL = rootURL }

  public func prepareStorage() throws -> StoragePreparationReport {
    let manager = FileManager.default
    try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let metadataURL = rootURL.appending(path: "storage-metadata.json")
    if manager.fileExists(atPath: metadataURL.path) {
      do {
        let metadata = try JSONDecoder().decode(
          StorageMetadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.formatVersion <= Self.currentFormatVersion else {
          throw DataProtectionError.futureStorageVersion(metadata.formatVersion)
        }
        return StoragePreparationReport(
          formatVersion: metadata.formatVersion, migrated: false, safetyCopyURL: nil,
          corruptFiles: corruptJSONFiles())
      } catch let error as DataProtectionError {
        throw error
      } catch {
        _ = try preserveCorruptFile(at: metadataURL)
        try manager.removeItem(at: metadataURL)
      }
    }

    let files = managedFiles().filter { $0.lastPathComponent != metadataURL.lastPathComponent }
    var safetyCopyURL: URL?
    if !files.isEmpty {
      let destination = rootURL.appending(path: "migration-backups", directoryHint: .isDirectory)
        .appending(path: Self.timestamp(), directoryHint: .isDirectory)
      try manager.createDirectory(at: destination, withIntermediateDirectories: true)
      for file in files {
        try manager.copyItem(at: file, to: destination.appending(path: file.lastPathComponent))
      }
      safetyCopyURL = destination
    }
    let metadata = StorageMetadata(formatVersion: Self.currentFormatVersion, migratedAt: Date())
    try secureWrite(try JSONEncoder().encode(metadata), to: metadataURL)
    return StoragePreparationReport(
      formatVersion: Self.currentFormatVersion, migrated: true, safetyCopyURL: safetyCopyURL,
      corruptFiles: corruptJSONFiles())
  }

  @discardableResult
  public func createBackup(at destination: URL) throws -> OnigiriBackupSummary {
    _ = try prepareStorage()
    let files = try managedFiles().map { url -> BackupFile in
      let data = try Data(contentsOf: url)
      return BackupFile(
        name: url.lastPathComponent, byteCount: data.count,
        sha256: Self.digest(data), data: data)
    }
    let envelope = BackupEnvelope(
      product: "Onigiri Harness", formatVersion: Self.currentFormatVersion,
      createdAt: Date(), files: files)
    try secureWrite(try JSONEncoder().encode(envelope), to: destination)
    return OnigiriBackupSummary(
      createdAt: envelope.createdAt, fileCount: files.count,
      totalBytes: files.reduce(0) { $0 + $1.byteCount })
  }

  @discardableResult
  public func restoreBackup(from source: URL) throws -> OnigiriBackupSummary {
    let envelope: BackupEnvelope
    do {
      envelope = try JSONDecoder().decode(BackupEnvelope.self, from: Data(contentsOf: source))
    } catch {
      throw DataProtectionError.invalidBackup(error.localizedDescription)
    }
    guard envelope.product == "Onigiri Harness", envelope.formatVersion <= Self.currentFormatVersion,
      !envelope.files.isEmpty, envelope.files.count <= 200
    else { throw DataProtectionError.invalidBackup("形式またはversionが正しくありません。") }
    var seen = Set<String>()
    var totalBytes = 0
    for file in envelope.files {
      guard Self.isSafeFileName(file.name), seen.insert(file.name).inserted,
        file.byteCount == file.data.count, file.byteCount <= 50_000_000
      else { throw DataProtectionError.invalidBackup("ファイル一覧が正しくありません。") }
      totalBytes += file.byteCount
      guard totalBytes <= 200_000_000 else {
        throw DataProtectionError.invalidBackup("バックアップが大きすぎます。")
      }
      guard Self.digest(file.data) == file.sha256 else {
        throw DataProtectionError.checksumMismatch(file.name)
      }
      guard (try? JSONSerialization.jsonObject(with: file.data)) != nil else {
        throw DataProtectionError.invalidBackup("\(file.name)は有効なJSONではありません。")
      }
    }

    let manager = FileManager.default
    try manager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let rollback = rootURL.appending(path: "restore-rollbacks", directoryHint: .isDirectory)
      .appending(path: Self.timestamp(), directoryHint: .isDirectory)
    try manager.createDirectory(at: rollback, withIntermediateDirectories: true)
    let currentFiles = managedFiles()
    for file in currentFiles {
      try manager.copyItem(at: file, to: rollback.appending(path: file.lastPathComponent))
    }
    do {
      for file in currentFiles { try manager.removeItem(at: file) }
      for file in envelope.files {
        try secureWrite(file.data, to: rootURL.appending(path: file.name))
      }
    } catch {
      for file in managedFiles() { try? manager.removeItem(at: file) }
      for file in (try? manager.contentsOfDirectory(
        at: rollback, includingPropertiesForKeys: nil)) ?? []
      {
        try? manager.copyItem(at: file, to: rootURL.appending(path: file.lastPathComponent))
      }
      throw error
    }
    return OnigiriBackupSummary(
      createdAt: envelope.createdAt, fileCount: envelope.files.count, totalBytes: totalBytes)
  }

  public func corruptJSONFiles() -> [String] {
    managedFiles().compactMap { url in
      guard let data = try? Data(contentsOf: url),
        (try? JSONSerialization.jsonObject(with: data)) != nil
      else { return url.lastPathComponent }
      return nil
    }.sorted()
  }

  @discardableResult
  public func preserveCorruptFile(at url: URL) throws -> URL? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let recovery = rootURL.appending(path: "recovery", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
    let destination = recovery.appending(
      path: "\(url.lastPathComponent).\(Self.timestamp()).corrupt")
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }

  private func managedFiles() -> [URL] {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
    let urls = (try? FileManager.default.contentsOfDirectory(
      at: rootURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])) ?? []
    return urls.filter { url in
      guard url.pathExtension.lowercased() == "json",
        let values = try? url.resourceValues(forKeys: keys)
      else { return false }
      return values.isRegularFile == true && values.isSymbolicLink != true
    }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func secureWrite(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: [.atomic, .completeFileProtection])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func isSafeFileName(_ name: String) -> Bool {
    !name.isEmpty && name == URL(fileURLWithPath: name).lastPathComponent
      && !name.contains("/") && !name.contains("\\") && name.hasSuffix(".json")
  }

  private static func timestamp() -> String {
    ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
  }
}

public struct KeychainSecretStore: Sendable {
  public let service: String

  public init(service: String = "com.onigiri-harness.secrets") { self.service = service }

  public func read(account: String) throws -> String? {
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8)
    else { throw DataProtectionError.keychain(status) }
    return value
  }

  public func save(_ value: String, account: String) throws {
    let data = Data(value.utf8)
    let query = baseQuery(account: account)
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess {
      let updated = SecItemUpdate(
        query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
      guard updated == errSecSuccess else { throw DataProtectionError.keychain(updated) }
    } else if status == errSecItemNotFound {
      var item = query
      item[kSecValueData as String] = data
      item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      let added = SecItemAdd(item as CFDictionary, nil)
      guard added == errSecSuccess else { throw DataProtectionError.keychain(added) }
    } else {
      throw DataProtectionError.keychain(status)
    }
  }

  public func delete(account: String) throws {
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw DataProtectionError.keychain(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
