import CryptoKit
import Foundation

public enum ManagedLocalModelCatalogSource: String, Codable, Sendable {
  case shipped, huggingFace, localImport
}

public struct ManagedLocalModelCatalogEntry: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let source: ManagedLocalModelCatalogSource
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

  public init(id: String, source: ManagedLocalModelCatalogSource = .shipped, name: String, publisher: String, repository: String, revision: String,
              fileName: String, downloadURL: String, license: String, parameterCount: String,
              quantization: String, downloadBytes: Int64, recommendedMemoryBytes: Int64,
              languages: [String], useCase: String) {
    self.id = id; self.source = source; self.name = name; self.publisher = publisher; self.repository = repository
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

public struct ManagedLocalModelBenchmarkCase: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let language: String
  public let prompt: String
  public init(id: String, language: String, prompt: String) { self.id = id; self.language = language; self.prompt = prompt }
}

public struct ManagedLocalModelBenchmarkResult: Codable, Sendable, Identifiable, Equatable {
  public let id: String
  public let language: String
  public let elapsedMilliseconds: Int
  public let responseCharacters: Int
  public let passed: Bool
  public let error: String?
  public init(id: String, language: String, elapsedMilliseconds: Int, responseCharacters: Int, passed: Bool, error: String? = nil) {
    self.id = id; self.language = language; self.elapsedMilliseconds = elapsedMilliseconds
    self.responseCharacters = responseCharacters; self.passed = passed; self.error = error
  }
}

public enum ManagedLocalModelWorkload: String, Codable, Sendable, CaseIterable, Identifiable {
  case general, grounded, writing, coding
  public var id: String { rawValue }
  public var japaneseTitle: String {
    switch self { case .general: return "日常会話"; case .grounded: return "資料を使う回答"; case .writing: return "文章作成"; case .coding: return "コーディング" }
  }
  public var englishTitle: String {
    switch self { case .general: return "General chat"; case .grounded: return "Grounded answer"; case .writing: return "Writing"; case .coding: return "Coding" }
  }
}

public struct ManagedLocalModelBenchmarkRun: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let modelID: String
  public let workload: ManagedLocalModelWorkload
  public let startedAt: Date
  public let completedAt: Date
  public let runtimeRSSBytes: Int64?
  public let results: [ManagedLocalModelBenchmarkResult]
  public var passed: Bool { results.allSatisfy(\.passed) && !results.isEmpty }
  public init(id: UUID = UUID(), modelID: String, workload: ManagedLocalModelWorkload = .general,
              startedAt: Date, completedAt: Date, runtimeRSSBytes: Int64?, results: [ManagedLocalModelBenchmarkResult]) {
    self.id = id; self.modelID = modelID; self.workload = workload; self.startedAt = startedAt; self.completedAt = completedAt
    self.runtimeRSSBytes = runtimeRSSBytes; self.results = results
  }
  private enum CodingKeys: String, CodingKey { case id, modelID, workload, startedAt, completedAt, runtimeRSSBytes, results }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UUID.self, forKey: .id); modelID = try values.decode(String.self, forKey: .modelID)
    workload = try values.decodeIfPresent(ManagedLocalModelWorkload.self, forKey: .workload) ?? .general
    startedAt = try values.decode(Date.self, forKey: .startedAt); completedAt = try values.decode(Date.self, forKey: .completedAt)
    runtimeRSSBytes = try values.decodeIfPresent(Int64.self, forKey: .runtimeRSSBytes)
    results = try values.decode([ManagedLocalModelBenchmarkResult].self, forKey: .results)
  }
}

public enum ManagedLocalModelAcceptanceSuite {
  public static func cases(for workload: ManagedLocalModelWorkload) -> [ManagedLocalModelBenchmarkCase] {
    switch workload {
    case .general:
      return [
        .init(id: "ja-short", language: "Japanese", prompt: "次の文を一文で要約してください。Onigiri Harness はローカルでAIと資料を扱うmacOSアプリです。"),
        .init(id: "en-short", language: "English", prompt: "Reply in one sentence: What is the purpose of a local AI harness?")
      ]
    case .grounded:
      return [
        .init(id: "ja-grounded", language: "Japanese", prompt: "次の資料だけを根拠に、一文で答えてください。資料: Onigiri HarnessはmacOSで動くローカルAIアプリです。質問: Onigiri HarnessはどのOSで動きますか？"),
        .init(id: "en-grounded", language: "English", prompt: "Use only this source and answer in one sentence. Source: Onigiri Harness runs locally on macOS. Question: Where does it run?")
      ]
    case .writing:
      return [
        .init(id: "ja-writing", language: "Japanese", prompt: "丁寧で短い案内文を二文で書いてください。内容: ローカルモデルのダウンロードが完了しました。"),
        .init(id: "en-writing", language: "English", prompt: "Write a friendly two-sentence notice that a local model download has completed.")
      ]
    case .coding:
      return [
        .init(id: "swift-code", language: "English", prompt: "Write a concise Swift function named isEven that accepts Int and returns Bool. Include only code."),
        .init(id: "explain-code", language: "Japanese", prompt: "Swiftの `let names = [\"A\", \"B\"]` が何を作るか、一文で説明してください。")
      ]
    }
  }
}


public struct ManagedLocalModelComparisonRow: Codable, Sendable, Identifiable, Equatable {
  public let modelID: String
  public let modelName: String
  public let passedCases: Int
  public let totalCases: Int
  public let averageLatencyMilliseconds: Int?
  public let runtimeRSSBytes: Int64?
  public let memoryFits: Bool
  public let score: Int?
  public var id: String { modelID }
  public var passed: Bool { totalCases > 0 && passedCases == totalCases }
  public init(modelID: String, modelName: String, passedCases: Int, totalCases: Int,
              averageLatencyMilliseconds: Int?, runtimeRSSBytes: Int64?, memoryFits: Bool, score: Int?) {
    self.modelID = modelID; self.modelName = modelName; self.passedCases = passedCases; self.totalCases = totalCases
    self.averageLatencyMilliseconds = averageLatencyMilliseconds; self.runtimeRSSBytes = runtimeRSSBytes
    self.memoryFits = memoryFits; self.score = score
  }
}

public struct ManagedLocalModelComparisonReport: Codable, Sendable, Equatable {
  public let rows: [ManagedLocalModelComparisonRow]
  public let recommendedGeneralModelID: String?
  public let recommendedLowMemoryModelID: String?
  public init(rows: [ManagedLocalModelComparisonRow], recommendedGeneralModelID: String?, recommendedLowMemoryModelID: String?) {
    self.rows = rows; self.recommendedGeneralModelID = recommendedGeneralModelID
    self.recommendedLowMemoryModelID = recommendedLowMemoryModelID
  }
}

public enum ManagedLocalModelComparison {
  public static func make(catalog: [ManagedLocalModelCatalogEntry], benchmarks: [ManagedLocalModelBenchmarkRun], totalMemoryBytes: Int64) -> ManagedLocalModelComparisonReport {
    let latestRuns = Dictionary(grouping: benchmarks, by: \.modelID).compactMapValues { $0.max(by: { $0.completedAt < $1.completedAt }) }
    let rows = catalog.compactMap { entry -> ManagedLocalModelComparisonRow? in
      guard let run = latestRuns[entry.id] else { return nil }
      let total = run.results.count
      let passed = run.results.filter(\.passed).count
      let latency = total > 0 ? run.results.map(\.elapsedMilliseconds).reduce(0, +) / total : nil
      let fits = entry.recommendedMemoryBytes <= totalMemoryBytes
      let score = latency.map { value in
        let reliability = total == 0 ? 0 : (passed * 100 / total)
        return reliability + (fits ? 25 : -100) - min(60, value / 100)
      }
      return ManagedLocalModelComparisonRow(modelID: entry.id, modelName: entry.name, passedCases: passed,
                                             totalCases: total, averageLatencyMilliseconds: latency,
                                             runtimeRSSBytes: run.runtimeRSSBytes, memoryFits: fits, score: score)
    }.sorted { ($0.score ?? Int.min) > ($1.score ?? Int.min) }
    let accepted = rows.filter { $0.passed && $0.memoryFits }
    let general = accepted.max { ($0.score ?? Int.min) < ($1.score ?? Int.min) }?.modelID
    let lowMemory = accepted.min { lhs, rhs in
      (catalog.first { $0.id == lhs.modelID }?.recommendedMemoryBytes ?? .max)
        < (catalog.first { $0.id == rhs.modelID }?.recommendedMemoryBytes ?? .max)
    }?.modelID
    return .init(rows: rows, recommendedGeneralModelID: general, recommendedLowMemoryModelID: lowMemory)
  }
}

public struct ManagedLocalModelsResponse: Codable, Sendable {
  public let catalog: [ManagedLocalModelCatalogEntry]
  public let records: [ManagedLocalModelRecord]
  public let runtimePath: String
  public let runtimeAvailable: Bool
  public let totalMemoryBytes: Int64
  public let loadedModelID: String?
  public let benchmarks: [ManagedLocalModelBenchmarkRun]
  public let comparisons: [String: ManagedLocalModelComparisonReport]

  public init(catalog: [ManagedLocalModelCatalogEntry], records: [ManagedLocalModelRecord], runtimePath: String,
              runtimeAvailable: Bool, totalMemoryBytes: Int64, loadedModelID: String?, benchmarks: [ManagedLocalModelBenchmarkRun] = [],
              comparisons: [String: ManagedLocalModelComparisonReport]? = nil) {
    self.catalog = catalog; self.records = records; self.runtimePath = runtimePath
    self.runtimeAvailable = runtimeAvailable; self.totalMemoryBytes = totalMemoryBytes; self.loadedModelID = loadedModelID
    self.benchmarks = benchmarks
    self.comparisons = comparisons ?? Dictionary(uniqueKeysWithValues: ManagedLocalModelWorkload.allCases.map { workload in
      (workload.rawValue, ManagedLocalModelComparison.make(catalog: catalog, benchmarks: benchmarks.filter { $0.workload == workload }, totalMemoryBytes: totalMemoryBytes))
    })
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
public struct ManagedLocalModelBenchmarkRequest: Codable, Sendable {
  public let id: String
  public let workload: ManagedLocalModelWorkload
  public init(id: String, workload: ManagedLocalModelWorkload = .general) { self.id = id; self.workload = workload }
}

public struct CustomHuggingFaceModelRequest: Codable, Sendable {
  public let name: String
  public let repository: String
  public let revision: String
  public let fileName: String
  public let license: String
  public let parameterCount: String
  public let quantization: String
  public let recommendedMemoryBytes: Int64
  public let languages: [String]
  public let useCase: String
  public init(name: String, repository: String, revision: String, fileName: String, license: String = "Unknown", parameterCount: String = "Unknown", quantization: String = "GGUF", recommendedMemoryBytes: Int64 = 0, languages: [String] = [], useCase: String = "Custom Hugging Face GGUF") {
    self.name = name; self.repository = repository; self.revision = revision; self.fileName = fileName
    self.license = license; self.parameterCount = parameterCount; self.quantization = quantization
    self.recommendedMemoryBytes = recommendedMemoryBytes; self.languages = languages; self.useCase = useCase
  }
  private enum CodingKeys: String, CodingKey { case name, repository, revision, fileName, license, parameterCount, quantization, recommendedMemoryBytes, languages, useCase }
  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    name = try values.decode(String.self, forKey: .name)
    repository = try values.decode(String.self, forKey: .repository)
    revision = try values.decode(String.self, forKey: .revision)
    fileName = try values.decode(String.self, forKey: .fileName)
    license = try values.decodeIfPresent(String.self, forKey: .license) ?? "Unknown"
    parameterCount = try values.decodeIfPresent(String.self, forKey: .parameterCount) ?? "Unknown"
    quantization = try values.decodeIfPresent(String.self, forKey: .quantization) ?? "GGUF"
    recommendedMemoryBytes = try values.decodeIfPresent(Int64.self, forKey: .recommendedMemoryBytes) ?? 0
    languages = try values.decodeIfPresent([String].self, forKey: .languages) ?? []
    useCase = try values.decodeIfPresent(String.self, forKey: .useCase) ?? "Custom Hugging Face GGUF"
  }
}

public struct LocalModelImportRequest: Codable, Sendable {
  public let filePath: String
  public let name: String?
  public init(filePath: String, name: String? = nil) { self.filePath = filePath; self.name = name }
}

public enum ManagedLocalModelError: LocalizedError {
  case catalogEntryNotFound
  case notDownloaded
  case runtimeUnavailable(String)
  case modelIsDownloading
  case unsafeDownloadURL
  case invalidRuntime
  case noPartialDownload
  case modelNotLoaded
  case invalidCustomCatalogEntry
  case invalidLocalModelFile

  public var errorDescription: String? {
    switch self {
    case .catalogEntryNotFound: return "選択したローカルモデルが見つかりません。"
    case .notDownloaded: return "モデルを先にダウンロードしてください。"
    case .runtimeUnavailable(let path): return "llama-server が見つかりません。設定した実行ファイルを確認してください: \(path)"
    case .modelIsDownloading: return "モデルをダウンロード中です。完了してからロードしてください。"
    case .unsafeDownloadURL: return "許可されていないモデル取得先です。"
    case .invalidRuntime: return "llama-server の実行ファイルを指定してください。"
    case .noPartialDownload: return "再開できる未完了ダウンロードがありません。"
    case .modelNotLoaded: return "受入テストを実行するには、対象モデルをロードしてください。"
    case .invalidCustomCatalogEntry: return "Hugging Faceのリポジトリ、固定コミット、GGUFファイル名を確認してください。"
    case .invalidLocalModelFile: return "有効なGGUFファイルを選択してください。"
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
  private let benchmarksURL: URL
  private let customCatalogURL: URL
  private var customCatalog: [ManagedLocalModelCatalogEntry] = []
  private var records: [String: ManagedLocalModelRecord] = [:]
  private var benchmarks: [ManagedLocalModelBenchmarkRun] = []
  private var runtimePath: String
  private var loadedModelID: String?
  private var runtimeProcess: Process?
  private var downloadTasks: [String: Task<Void, Never>] = [:]

  public init(rootURL: URL = OnigiriDataVault.defaultRootURL.appending(path: "local-models", directoryHint: .isDirectory),
              environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.rootURL = rootURL
    self.modelsURL = rootURL.appending(path: "models", directoryHint: .isDirectory)
    self.stateURL = rootURL.appending(path: "state.json")
    self.benchmarksURL = rootURL.appending(path: "benchmarks.json")
    self.customCatalogURL = rootURL.appending(path: "catalog.json")
    self.runtimePath = environment["ONIGIRI_LLAMA_SERVER_PATH"] ?? "/opt/homebrew/bin/llama-server"
    try? FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
    if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(SavedState.self, from: data) {
      self.records = Dictionary(uniqueKeysWithValues: saved.records.map { ($0.id, $0) })
      self.runtimePath = saved.runtimePath
    }
    if let data = try? Data(contentsOf: benchmarksURL), let saved = try? JSONDecoder().decode([ManagedLocalModelBenchmarkRun].self, from: data) {
      self.benchmarks = Array(saved.prefix(20))
    }
    if let data = try? Data(contentsOf: customCatalogURL), let saved = try? JSONDecoder().decode([ManagedLocalModelCatalogEntry].self, from: data) {
      self.customCatalog = saved.filter { $0.source != .shipped }
    }
  }

  deinit { runtimeProcess?.terminate() }

  public func snapshot() -> ManagedLocalModelsResponse {
    let catalog = allCatalogEntries
    return ManagedLocalModelsResponse(
      catalog: catalog,
      records: catalog.map { records[$0.id] ?? ManagedLocalModelRecord(id: $0.id) },
      runtimePath: runtimePath, runtimeAvailable: FileManager.default.isExecutableFile(atPath: runtimePath),
      totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory), loadedModelID: loadedModelID,
      benchmarks: benchmarks.sorted { $0.completedAt > $1.completedAt },
      comparisons: Dictionary(uniqueKeysWithValues: ManagedLocalModelWorkload.allCases.map { workload in
        (workload.rawValue, ManagedLocalModelComparison.make(catalog: catalog,
          benchmarks: benchmarks.filter { $0.workload == workload }, totalMemoryBytes: Int64(ProcessInfo.processInfo.physicalMemory)))
      }))
  }

  private var allCatalogEntries: [ManagedLocalModelCatalogEntry] { ManagedLocalModelCatalog.entries + customCatalog }

  private func entry(id: String) -> ManagedLocalModelCatalogEntry? {
    allCatalogEntries.first { $0.id == id }
  }

  public func setRuntimePath(_ path: String) throws -> ManagedLocalModelsResponse {
    let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw ManagedLocalModelError.invalidRuntime }
    runtimePath = normalized
    try persist()
    return snapshot()
  }

  public func addHuggingFaceModel(_ request: CustomHuggingFaceModelRequest) throws -> ManagedLocalModelsResponse {
    let repository = request.repository.trimmingCharacters(in: .whitespacesAndNewlines)
    let revision = request.revision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let fileName = request.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let validRepository = repository.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    let validRevision = revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil
    guard validRepository, validRevision, !fileName.contains("/"), fileName.lowercased().hasSuffix(".gguf") else {
      throw ManagedLocalModelError.invalidCustomCatalogEntry
    }
    let canonical = "\(repository)@\(revision)/\(fileName)"
    let id = "hf-" + SHA256.hash(data: Data(canonical.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    guard !allCatalogEntries.contains(where: { $0.id == id }) else { return snapshot() }
    let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
    let entry = ManagedLocalModelCatalogEntry(
      id: id, source: .huggingFace, name: name.isEmpty ? fileName : name, publisher: repository.split(separator: "/").first.map(String.init) ?? "Hugging Face",
      repository: repository, revision: revision, fileName: fileName,
      downloadURL: "https://huggingface.co/\(repository)/resolve/\(revision)/\(fileName)",
      license: nonEmpty(request.license, fallback: "Unknown"),
      parameterCount: nonEmpty(request.parameterCount, fallback: "Unknown"),
      quantization: nonEmpty(request.quantization, fallback: "GGUF"),
      downloadBytes: 0, recommendedMemoryBytes: max(0, request.recommendedMemoryBytes),
      languages: request.languages, useCase: nonEmpty(request.useCase, fallback: "Custom Hugging Face GGUF"))
    customCatalog.append(entry)
    try persistCustomCatalog()
    return snapshot()
  }

  public func importLocalModel(_ request: LocalModelImportRequest) throws -> ManagedLocalModelsResponse {
    let source = URL(fileURLWithPath: request.filePath).standardizedFileURL
    guard source.pathExtension.lowercased() == "gguf", FileManager.default.isReadableFile(atPath: source.path), isGGUF(source) else {
      throw ManagedLocalModelError.invalidLocalModelFile
    }
    let id = "local-" + UUID().uuidString.lowercased()
    let safeName = "\(id).gguf"
    let destination = modelsURL.appending(path: safeName)
    try FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: destination)
    let bytes = fileSize(at: destination)
    let requestedName = request.name?.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = requestedName?.isEmpty == false ? requestedName! : source.deletingPathExtension().lastPathComponent
    let entry = ManagedLocalModelCatalogEntry(
      id: id, source: .localImport, name: name, publisher: "Local import", repository: "", revision: "local",
      fileName: source.lastPathComponent, downloadURL: "", license: "Verify source license", parameterCount: "Unknown",
      quantization: "GGUF", downloadBytes: bytes, recommendedMemoryBytes: 0, languages: [], useCase: "Imported local GGUF")
    customCatalog.append(entry)
    records[id] = ManagedLocalModelRecord(id: id, state: .downloaded, localFileName: safeName, downloadedBytes: bytes,
                                           sha256: try sha256(of: destination), sourceRevision: "local", expectedBytes: bytes, updatedAt: Date())
    try persistCustomCatalog(); try persist()
    return snapshot()
  }

  public func download(id: String) throws -> ManagedLocalModelsResponse {
    guard let entry = entry(id: id) else {
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
    guard let entry = entry(id: id) else {
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
    guard entry(id: id) != nil else {
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

  public func benchmark(id: String, workload: ManagedLocalModelWorkload = .general) async throws -> ManagedLocalModelBenchmarkRun {
    guard loadedModelID == id, runtimeProcess?.isRunning == true else { throw ManagedLocalModelError.modelNotLoaded }
    let startedAt = Date()
    let modelID = try await runtimeModelID()
    var results: [ManagedLocalModelBenchmarkResult] = []
    for testCase in ManagedLocalModelAcceptanceSuite.cases(for: workload) {
      let caseStartedAt = Date()
      do {
        let response = try await complete(prompt: testCase.prompt, modelID: modelID)
        let elapsed = Int(Date().timeIntervalSince(caseStartedAt) * 1_000)
        let passed = !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && elapsed <= 120_000
        results.append(.init(id: testCase.id, language: testCase.language, elapsedMilliseconds: elapsed,
                             responseCharacters: response.count, passed: passed,
                             error: passed ? nil : "応答が空か、120秒を超えました。"))
      } catch {
        results.append(.init(id: testCase.id, language: testCase.language,
                             elapsedMilliseconds: Int(Date().timeIntervalSince(caseStartedAt) * 1_000),
                             responseCharacters: 0, passed: false, error: error.localizedDescription))
      }
    }
    let run = ManagedLocalModelBenchmarkRun(modelID: id, workload: workload, startedAt: startedAt, completedAt: Date(),
                                             runtimeRSSBytes: runtimeRSSBytes(), results: results)
    benchmarks.insert(run, at: 0)
    benchmarks = Array(benchmarks.prefix(20))
    try persistBenchmarks()
    return run
  }

  public func unload() throws -> ManagedLocalModelsResponse {
    runtimeProcess?.terminate(); runtimeProcess = nil
    if let loadedModelID, records[loadedModelID]?.state == .loaded { records[loadedModelID]?.state = .downloaded }
    loadedModelID = nil
    try persist()
    return snapshot()
  }

  public func delete(id: String) throws -> ManagedLocalModelsResponse {
    guard let entry = entry(id: id) else {
      throw ManagedLocalModelError.catalogEntryNotFound
    }
    if loadedModelID == id { _ = try unload() }
    downloadTasks[id]?.cancel(); downloadTasks[id] = nil
    if let name = records[id]?.localFileName {
      try? FileManager.default.removeItem(at: modelsURL.appending(path: name))
    }
    try? FileManager.default.removeItem(at: partialURL(for: entry))
    records[id] = ManagedLocalModelRecord(id: id, state: .notDownloaded, updatedAt: Date())
    if entry.source != .shipped {
      customCatalog.removeAll { $0.id == id }
      records.removeValue(forKey: id)
      try persistCustomCatalog()
    }
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

  private func runtimeModelID() async throws -> String {
    let url = URL(string: "http://127.0.0.1:\(Self.runtimePort)/v1/models")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
          let model = try JSONDecoder().decode(LocalRuntimeModelList.self, from: data).data.first?.id else {
      throw HarnessError.unavailable("llama-serverからモデル一覧を取得できませんでした。")
    }
    return model
  }

  private func complete(prompt: String, modelID: String) async throws -> String {
    let url = URL(string: "http://127.0.0.1:\(Self.runtimePort)/v1/chat/completions")!
    var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 125
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(LocalBenchmarkRequest(model: modelID, messages: [.init(role: "user", content: prompt)]))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw HarnessError.unavailable("llama-serverの受入ケース実行に失敗しました。")
    }
    return try JSONDecoder().decode(LocalBenchmarkResponse.self, from: data).choices.first?.message.content ?? ""
  }

  private func runtimeRSSBytes() -> Int64? {
    guard let process = runtimeProcess else { return nil }
    let output = Pipe(); let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-o", "rss=", "-p", String(process.processIdentifier)]
    task.standardOutput = output
    guard (try? task.run()) != nil else { return nil }
    task.waitUntilExit()
    let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.flatMap(Int64.init).map { $0 * 1_024 }
  }

  private func persistBenchmarks() throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(benchmarks).write(to: benchmarksURL, options: [.atomic])
  }

  private struct LocalRuntimeModelList: Decodable { let data: [LocalRuntimeModel] }
  private struct LocalRuntimeModel: Decodable { let id: String }
  private struct LocalBenchmarkRequest: Encodable {
    let model: String; let messages: [LocalBenchmarkMessage]; let stream = false; let max_tokens = 96; let temperature = 0.0
  }
  private struct LocalBenchmarkMessage: Codable { let role: String; let content: String }
  private struct LocalBenchmarkResponse: Decodable { let choices: [LocalBenchmarkChoice] }
  private struct LocalBenchmarkChoice: Decodable { let message: LocalBenchmarkMessage }

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

  private func nonEmpty(_ value: String, fallback: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? fallback : trimmed
  }

  private func isGGUF(_ url: URL) -> Bool {
    guard fileSize(at: url) > 1_024, let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    return (try? handle.read(upToCount: 4)).flatMap { String(data: $0, encoding: .utf8) } == "GGUF"
  }

  private func persistCustomCatalog() throws {
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try JSONEncoder().encode(customCatalog).write(to: customCatalogURL, options: [.atomic])
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
