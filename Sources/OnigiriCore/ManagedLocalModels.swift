import CryptoKit
import Foundation

public struct ManagedLocalModelCatalogEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let name: String
  public let publisher: String
  public let repository: String
  public let revision: String
  public let fileName: String
  public let downloadURL: String
  public let license: String
  public let parameterCount: String
  public let quantization: String
  public let downloadBytes: Int64
  public let recommendedMemoryBytes: Int64
  public let languages: [String]
  public let useCase: String

  public init(id: String, name: String, publisher: String, repository: String, revision: String,
              fileName: String, downloadURL: String, license: String, parameterCount: String,
              quantization: String, downloadBytes: Int64, recommendedMemoryBytes: Int64,
              languages: [String], useCase: String) {
    self.id = id; self.name = name; self.publisher = publisher; self.repository = repository
    self.revision = revision; self.fileName = fileName; self.downloadURL = downloadURL
    self.license = license; self.parameterCount = parameterCount; self.quantization = quantization
    self.downloadBytes = downloadBytes; self.recommendedMemoryBytes = recommendedMemoryBytes
    self.languages = languages; self.useCase = useCase
  }
}

public enum ManagedLocalModelCatalog {
  // The first shipped catalog stays small so its source, license and memory needs are reviewable.
  // The selected Hub revision is recorded with the catalog entry; a completed download also records SHA-256 locally.
  public static let entries: [ManagedLocalModelCatalogEntry] = [
    .init(
      id: "qwen2.5-1.5b-instruct-q4-k-m", name: "Qwen2.5 1.5B Instruct", publisher: "Qwen",
      repository: "Qwen/Qwen2.5-1.5B-Instruct-GGUF", revision: "91cad51170dc346986eccefdc2dd33a9da36ead9",
      fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
      downloadURL: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf",
      license: "Apache-2.0", parameterCount: "1.5B", quantization: "Q4_K_M",
      downloadBytes: 1_100_000_000, recommendedMemoryBytes: 3_000_000_000,
      languages: ["Japanese", "English", "Multilingual"], useCase: "軽量な日常会話・文章作成"),
    .init(
      id: "qwen2.5-7b-instruct-q4-k-m", name: "Qwen2.5 7B Instruct", publisher: "Qwen",
      repository: "Qwen/Qwen2.5-7B-Instruct-GGUF", revision: "bb5d59e06d9551d752d08b292a50eb208b07ab1f",
      fileName: "qwen2.5-7b-instruct-q3_k_m.gguf",
      downloadURL: "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/bb5d59e06d9551d752d08b292a50eb208b07ab1f/qwen2.5-7b-instruct-q3_k_m.gguf",
      license: "Apache-2.0", parameterCount: "7B", quantization: "Q3_K_M",
      downloadBytes: 3_300_000_000, recommendedMemoryBytes: 7_000_000_000,
      languages: ["Japanese", "English", "Multilingual"], useCase: "品質を優先する日常会話・RAG"),
  ]
}

public enum ManagedLocalModelState: String, Codable, Sendable {
  case notDownloaded, downloading, downloaded, loaded, failed
}

public struct ManagedLocalModelRecord: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public var state: ManagedLocalModelState
  public var localFileName: String?
  public var downloadedBytes: Int64
  public var sha256: String?
  public var sourceRevision: String?
  public var remoteETag: String?
  public var expectedBytes: Int64?
  public var error: String?
  public var updatedAt: Date

  public init(id: String, state: ManagedLocalModelState = .notDownloaded, localFileName: String? = nil,
              downloadedBytes: Int64 = 0, sha256: String? = nil, sourceRevision: String? = nil,
              remoteETag: String? = nil, expectedBytes: Int64? = nil, error: String? = nil,
              updatedAt: Date = Date()) {
    self.id = id; self.state = state; self.localFileName = localFileName
    self.downloadedBytes = downloadedBytes; self.sha256 = sha256; self.sourceRevision = sourceRevision
    self.remoteETag = remoteETag; self.expectedBytes = expectedBytes; self.error = error; self.updatedAt = updatedAt
  }

  private enum CodingKeys: String, CodingKey { case id, state, localFileName, downloadedBytes, sha256, sourceRevision, remoteETag, expectedBytes, error, updatedAt }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(String.self, forKey: .id)
    state = try values.decode(ManagedLocalModelState.self, forKey: .state)
    localFileName = try values.decodeIfPresent(String.self, forKey: .localFileName)
    downloadedBytes = try values.decodeIfPresent(Int64.self, forKey: .downloadedBytes) ?? 0
    sha256 = try values.decodeIfPresent(String.self, forKey: .sha256)
    sourceRevision = try values.decodeIfPresent(String.self, forKey: .sourceRevision)
    remoteETag = try values.decodeIfPresent(String.self, forKey: .remoteETag)
    expectedBytes = try values.decodeIfPresent(Int64.self, forKey: .expectedBytes)
    error = try values.decodeIfPresent(String.self, forKey: .error)
    updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
  }
}

public struct ManagedLocalModelsResponse: Codable, Sendable {
  public let catalog: [ManagedLocalModelCatalogEntry]
  public let records: [ManagedLocalModelRecord]
  public let runtimePath: String
  public let runtimeAvailable: Bool
  public let totalMemoryBytes: Int64
  public let loadedModelID: String?

  public init(catalog: [ManagedLocalModelCatalogEntry], records: [ManagedLocalModelRecord], runtimePath: String,
              runtimeAvailable: Bool, totalMemoryBytes: Int64, loadedModelID: String?) {
    self.catalog = catalog; self.records = records; self.runtimePath = runtimePath
    self.runtimeAvailable = runtimeAvailable; self.totalMemoryBytes = totalMemoryBytes; self.loadedModelID = loadedModelID
  }
}

public struct ManagedLocalModelActionRequest: Codable, Sendable {
  public let id: String
  public init(id: String) { self.id = id }
}
public struct ManagedLocalModelRuntimeRequest: Codable, Sendable {
  public let runtimePath: String
  public init(runtimePath: String) { self.runtimePath = runtimePath }
}
public struct ManagedLocalModelRecoveryRequest: Codable, Sendable {
  public let id: String
  public init(id: String) { self.id = id }
}

public enum ManagedLocalModelError: LocalizedError {
  case catalogEntryNotFound
  case notDownloaded
  case runtimeUnavailable(String)
  case modelIsDownloading
  case unsafeDownloadURL
  case invalidRuntime
  case noPartialDownload

  public var errorDescription: String? {
    switch self {
    case .catalogEntryNotFound: return "選択したローカルモデルが見つかりません。"
    case .notDownloaded: return "モデルを先にダウンロードしてください。"
    case .runtimeUnavailable(let path): return "llama-server が見つかりません。設定した実行ファイルを確認してください: \(path)"
    case .modelIsDownloading: return "モデルをダウンロード中です。完了してからロードしてください。"
    case .unsafeDownloadURL: return "許可されていないモデル取得先です。"
    case .invalidRuntime: return "llama-server の実行ファイルを指定してください。"
    case .noPartialDownload: return "再開できる未完了ダウンロードがありません。"
    }
  }
}

public actor ManagedLocalModelManager {
  public static let runtimePort: UInt16 = 18181
  public static let runtimeBaseURL = "http://127.0.0.1:18181/v1"

  private struct SavedState: Codable { var records: [ManagedLocalModelRecord]; var runtimePath: String }
  private let rootURL: URL
  private let modelsURL: URL
  private let stateURL: URL
  private var records: [String: ManagedLocalModelRecord] = [:]
  private var runtimePath: String
  private var loadedModelID: String?
  private var runtimeProcess: Process?
  private var downloadTasks: [String: Task<Void, Never>] = [:]

  public init(rootURL: URL = OnigiriDataVault.defaultRootURL.appending(path: "local-models", directoryHint: .isDirectory),
              environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.rootURL = rootURL
    self.modelsURL = rootURL.appending(path: "models", directoryHint: .isDirectory)
    self.stateURL = rootURL.appending(path: "state.json")
    self.runtimePath = environment["ONIGIRI_LLAMA_SERVER_PATH"] ?? "/opt/homebrew/bin/llama-server"
    try? FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
      self.records = Dictionary(uniqueKeysWithValues: saved.records.map { ($0.id, $0) })
      self.runtimePath = saved.runtimePath
    }
  }

  deinit { runtimeProcess?.terminate() }

  public func snapshot() -> ManagedLocalModelsResponse {
    ManagedLocalModelsResponse(
      catalog: ManagedLocalModelCatalog.entries,
      records: ManagedLocalModelCatalog.entries.map { records[$0.id] ?? ManagedLocalModelRecord(id: $0.id) },
      runtimePath: runtimePath, runtimeAvailable: FileManager.default.isExecutableFile(atPath: runtimePath),
      totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory), loadedModelID: loadedModelID)
  }

  public func setRuntimePath(_ path: String) throws -> ManagedLocalModelsResponse {
    let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ManagedLocalModelError.invalidRuntime }
    runtimePath = normalized
    try persist()
    return snapshot()
  }

  public func download(id: String) throws -> ManagedLocalModelsResponse {
    guard let entry = ManagedLocalModelCatalog.entries.first(where: { $0.id == id }) else {
      throw ManagedLocalModelError.catalogEntryNotFound
    }
    guard URL(string: entry.downloadURL)?.host == "huggingface.co", entry.downloadURL.contains("/resolve/") else {
      throw ManagedLocalModelError.unsafeDownloadURL
    }
    if records[id]?.state == .downloading { return snapshot() }
    let partialBytes = fileSize(at: partialURL(for: entry))
    let previous = records[id]
    records[id] = ManagedLocalModelRecord(
      id: id, state: .downloading, downloadedBytes: partialBytes, sha256: previous?.sha256,
      sourceRevision: entry.revision, remoteETag: previous?.remoteETag,
      expectedBytes: previous?.expectedBytes ?? entry.downloadBytes, updatedAt: Date())
    try persist()
    let task = Task { await self.performDownload(entry) }
    downloadTasks[id] = task
    return snapshot()
  }

  public func cancelDownload(id: String) throws -> ManagedLocalModelsResponse {
    guard let entry = ManagedLocalModelCatalog.entries.first(where: { $0.id == id }) else {
      throw ManagedLocalModelError.catalogEntryNotFound
    }
    guard records[id]?.state == .downloading else { return snapshot() }
    downloadTasks[id]?.cancel(); downloadTasks[id] = nil
    let bytes = fileSize(at: partialURL(for: entry))
    records[id]?.state = .failed
    records[id]?.downloadedBytes = bytes
    records[id]?.error = "ダウンロードを停止しました。再開できます。"
    records[id]?.updatedAt = Date()
    try persist()
    return snapshot()
  }

  public func load(id: String) async throws -> ProviderConfig {
    guard ManagedLocalModelCatalog.entries.contains(where: { $0.id == id }) else {
      throw ManagedLocalModelError.catalogEntryNotFound
    }
    guard let record = records[id], record.state != .downloading else {
      throw ManagedLocalModelError.modelIsDownloading
    }
    guard record.state == .downloaded || record.state == .loaded,
          let name = record.localFileName,
          FileManager.default.fileExists(atPath: modelsURL.appending(path: name).path)
    else { throw ManagedLocalModelError.notDownloaded }
    guard FileManager.default.isExecutableFile(atPath: runtimePath) else {
      throw ManagedLocalModelError.runtimeUnavailable(runtimePath)
    }
    runtimeProcess?.terminate()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: runtimePath)
    process.arguments = ["--model", modelsURL.appending(path: name).path, "--host", "127.0.0.1", "--port", String(Self.runtimePort)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    runtimeProcess = process
    do {
      try await waitForRuntimeReady()
    } catch {
      process.terminate(); runtimeProcess = nil
      throw error
    }
    for key in records.keys where key != id {
      if records[key]?.state == .loaded { records[key]?.state = .downloaded }
    }
    records[id]?.state = .loaded
    records[id]?.updatedAt = Date()
    loadedModelID = id
    try persist()
    return ProviderConfig(providerID: "onigiri-local", baseURL: Self.runtimeBaseURL)
  }

  public func unload() throws -> ManagedLocalModelsResponse {
    runtimeProcess?.terminate(); runtimeProcess = nil
    if let loadedModelID, records[loadedModelID]?.state == .loaded { records[loadedModelID]?.state = .downloaded }
    loadedModelID = nil
    try persist()
    return snapshot()
  }

  public func delete(id: String) throws -> ManagedLocalModelsResponse {
    guard let entry = ManagedLocalModelCatalog.entries.first(where: { $0.id == id }) else {
      throw ManagedLocalModelError.catalogEntryNotFound
    }
    if loadedModelID == id { _ = try unload() }
    downloadTasks[id]?.cancel(); downloadTasks[id] = nil
    if let name = records[id]?.localFileName {
      try? FileManager.default.removeItem(at: modelsURL.appending(path: name))
    }
    try? FileManager.default.removeItem(at: partialURL(for: entry))
    records[id] = ManagedLocalModelRecord(id: id, state: .notDownloaded, updatedAt: Date())
    try persist()
    return snapshot()
  }

  private func performDownload(_ entry: ManagedLocalModelCatalogEntry) async {
    defer { downloadTasks[entry.id] = nil }
    do {
      guard let url = URL(string: entry.downloadURL) else { throw ManagedLocalModelError.unsafeDownloadURL }
      let partial = partialURL(for: entry)
      let existingBytes = fileSize(at: partial)
      var request = URLRequest(url: url)
      request.timeoutInterval = 90
      if existingBytes > 0 { request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range") }
      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 || http.statusCode == 206 else {
        throw URLError(.badServerResponse)
      }
      let resumes = http.statusCode == 206 && existingBytes > 0
      let expected = max(0, http.expectedContentLength) + (resumes ? existingBytes : 0)
      if !resumes { try? FileManager.default.removeItem(at: partial) }
      FileManager.default.createFile(atPath: partial.path, contents: nil)
      let handle = try FileHandle(forWritingTo: partial)
      defer { try? handle.close() }
      if resumes { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
      var received = resumes ? existingBytes : 0
      var lastPersisted = received
      var buffer: [UInt8] = []
      buffer.reserveCapacity(65_536)
      for try await byte in bytes {
        try Task.checkCancellation()
        buffer.append(byte)
        received += 1
        if buffer.count == 65_536 {
          try handle.write(contentsOf: Data(buffer))
          buffer.removeAll(keepingCapacity: true)
        }
        if received - lastPersisted >= 2_000_000 {
          records[entry.id]?.downloadedBytes = received
          records[entry.id]?.expectedBytes = expected > 0 ? expected : entry.downloadBytes
          records[entry.id]?.remoteETag = http.value(forHTTPHeaderField: "ETag")
          records[entry.id]?.updatedAt = Date()
          try persist()
          lastPersisted = received
        }
      }
      if !buffer.isEmpty { try handle.write(contentsOf: Data(buffer)) }
      let safeName = "\(entry.id).gguf"
      let destination = modelsURL.appending(path: safeName)
      let byteCount = fileSize(at: partial)
      let header = try Data(contentsOf: partial, options: [.mappedIfSafe]).prefix(4)
      guard byteCount > 1_024, String(data: header, encoding: .utf8) == "GGUF" else {
        throw URLError(.cannotDecodeContentData)
      }
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: partial, to: destination)
      records[entry.id] = ManagedLocalModelRecord(
        id: entry.id, state: .downloaded, localFileName: safeName, downloadedBytes: byteCount,
        sha256: try sha256(of: destination), sourceRevision: entry.revision,
        remoteETag: http.value(forHTTPHeaderField: "ETag"), expectedBytes: expected > 0 ? expected : byteCount,
        updatedAt: Date())
      try persist()
    } catch is CancellationError {
      // cancelDownload records the recoverable state before cancelling the task.
    } catch {
      let partialBytes = fileSize(at: partialURL(for: entry))
      let previous = records[entry.id]
      records[entry.id] = ManagedLocalModelRecord(
        id: entry.id, state: .failed, downloadedBytes: partialBytes, sha256: previous?.sha256,
        sourceRevision: entry.revision, remoteETag: previous?.remoteETag,
        expectedBytes: previous?.expectedBytes ?? entry.downloadBytes, error: error.localizedDescription,
        updatedAt: Date())
      try? persist()
    }
  }

  private func partialURL(for entry: ManagedLocalModelCatalogEntry) -> URL {
    modelsURL.appending(path: "\(entry.id).part")
  }

  private func fileSize(at url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
  }

  private func waitForRuntimeReady() async throws {
    guard let url = URL(string: "http://127.0.0.1:\(Self.runtimePort)/v1/models") else { return }
    for _ in 0..<20 {
      var request = URLRequest(url: url); request.timeoutInterval = 1
      if let (_, response) = try? await URLSession.shared.data(for: request),
         let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw HarnessError.unavailable("llama-server の起動を確認できませんでした。モデル形式または実行環境を確認してください。")
  }

  private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
      let data = try handle.read(upToCount: 1_048_576) ?? Data()
      if data.isEmpty { break }
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private func persist() throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let state = SavedState(records: Array(records.values), runtimePath: runtimePath)
    try JSONEncoder().encode(state).write(to: stateURL, options: [.atomic])
  }
}
