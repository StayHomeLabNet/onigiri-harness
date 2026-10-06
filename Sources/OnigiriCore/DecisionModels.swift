import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() { self = .null }
    else if let value = try? container.decode(Bool.self) { self = .bool(value) }
    else if let value = try? container.decode(Double.self) { self = .number(value) }
    else if let value = try? container.decode(String.self) { self = .string(value) }
    else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
    else { self = .object(try container.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

public enum DecisionProviderKind: String, Codable, Sendable, CaseIterable {
  case ollaya
  case typeSafeCompatible
}

public struct DecisionProviderDescriptor: Codable, Sendable, Equatable, Identifiable {
  public var id: DecisionProviderKind { kind }
  public let kind: DecisionProviderKind
  public let name: String
  public let defaultBaseURL: String
  public let supportsLocalModels: Bool

  public init(
    kind: DecisionProviderKind, name: String, defaultBaseURL: String,
    supportsLocalModels: Bool
  ) {
    self.kind = kind
    self.name = name
    self.defaultBaseURL = defaultBaseURL
    self.supportsLocalModels = supportsLocalModels
  }
}

public enum DecisionProviderCatalog {
  public static let descriptors = [
    DecisionProviderDescriptor(
      kind: .ollaya, name: "Ollaya (Local)", defaultBaseURL: "http://127.0.0.1:11435",
      supportsLocalModels: true),
    DecisionProviderDescriptor(
      kind: .typeSafeCompatible, name: "TypeSafe-compatible / Jev",
      defaultBaseURL: "https://api.typesafe.ai", supportsLocalModels: false),
  ]
}

public struct DecisionProviderConfig: Codable, Sendable, Equatable {
  public let kind: DecisionProviderKind
  public let baseURL: String
  public let apiKey: String?

  public init(kind: DecisionProviderKind, baseURL: String, apiKey: String? = nil) {
    self.kind = kind
    self.baseURL = baseURL
    self.apiKey = apiKey
  }

  public var redacted: DecisionProviderConfig {
    DecisionProviderConfig(kind: kind, baseURL: baseURL, apiKey: nil)
  }
}

public struct DecisionModelSummary: Codable, Sendable, Equatable, Identifiable {
  public var id: String { name }
  public let name: String
  public let family: String?
  public let format: String?
  public let parameterSize: String?

  public init(name: String, family: String? = nil, format: String? = nil, parameterSize: String? = nil) {
    self.name = name
    self.family = family
    self.format = format
    self.parameterSize = parameterSize
  }
}

public struct DecisionModelListRequest: Codable, Sendable, Equatable {
  public let provider: DecisionProviderConfig
  public init(provider: DecisionProviderConfig) { self.provider = provider }
}

public struct DecisionModelListResponse: Codable, Sendable, Equatable {
  public let models: [DecisionModelSummary]
  public init(models: [DecisionModelSummary]) { self.models = models }
}

public enum DecisionQuestionType: String, Codable, Sendable, CaseIterable {
  case choice
  case score
  case noul
}

public struct DecisionQuestion: Codable, Sendable, Equatable {
  public let type: DecisionQuestionType
  public let instructions: JSONValue?
  public let criteria: JSONValue?

  public init(type: DecisionQuestionType, instructions: JSONValue? = nil, criteria: JSONValue? = nil) {
    self.type = type
    self.instructions = instructions
    self.criteria = criteria
  }
}

public struct DecisionExperimentRequest: Codable, Sendable, Equatable {
  public let provider: DecisionProviderConfig
  public let model: String
  public let state: JSONValue
  public let questions: [String: DecisionQuestion]

  public init(
    provider: DecisionProviderConfig, model: String, state: JSONValue,
    questions: [String: DecisionQuestion]
  ) {
    self.provider = provider
    self.model = model
    self.state = state
    self.questions = questions
  }

  public var redacted: DecisionExperimentRequest {
    DecisionExperimentRequest(
      provider: provider.redacted, model: model, state: state, questions: questions)
  }
}

public enum DecisionExperimentStatus: String, Codable, Sendable {
  case completed
  case failed
}

public struct DecisionExperimentRecord: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let request: DecisionExperimentRequest
  public let status: DecisionExperimentStatus
  public let response: JSONValue?
  public let respondingModel: String?
  public let durationMilliseconds: Int
  public let error: String?

  public init(
    id: UUID = UUID(), createdAt: Date = Date(), request: DecisionExperimentRequest,
    status: DecisionExperimentStatus, response: JSONValue? = nil,
    respondingModel: String? = nil, durationMilliseconds: Int, error: String? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.request = request.redacted
    self.status = status
    self.response = response
    self.respondingModel = respondingModel
    self.durationMilliseconds = max(0, durationMilliseconds)
    self.error = error
  }
}

public struct DecisionExperimentListResponse: Codable, Sendable, Equatable {
  public let runs: [DecisionExperimentRecord]
  public init(runs: [DecisionExperimentRecord]) { self.runs = runs }
}

public enum DecisionLabError: LocalizedError {
  case invalidRequest(String)
  case provider(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let detail), .provider(let detail): return detail
    }
  }
}

public actor DecisionLabManager {
  public static var defaultStoreURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "decision-lab-runs.json")
  }

  private let storeURL: URL?
  private var runs: [DecisionExperimentRecord]

  public init(storeURL: URL? = DecisionLabManager.defaultStoreURL) {
    self.storeURL = storeURL
    runs = storeURL.flatMap { try? Self.load(from: $0) } ?? []
  }

  public func list() -> DecisionExperimentListResponse {
    DecisionExperimentListResponse(runs: runs.sorted { $0.createdAt > $1.createdAt })
  }

  public func clear() -> DecisionExperimentListResponse {
    runs = []
    save()
    return DecisionExperimentListResponse(runs: [])
  }

  public func models(for config: DecisionProviderConfig) async throws -> DecisionModelListResponse {
    let (url, _) = try Self.endpoint(config: config, path: config.kind == .ollaya ? "api/tags" : "v1/models")
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    Self.authorize(&request, apiKey: config.apiKey)
    let data = try await Self.perform(request)
    let root = try Self.jsonObject(data)
    let rawModels = (root["models"] as? [[String: Any]]) ?? (root["data"] as? [[String: Any]]) ?? []
    let models = rawModels.compactMap { item -> DecisionModelSummary? in
      guard let name = (item["name"] ?? item["id"] ?? item["model"]) as? String else { return nil }
      let details = item["details"] as? [String: Any]
      return DecisionModelSummary(
        name: name, family: details?["family"] as? String,
        format: details?["format"] as? String,
        parameterSize: details?["parameter_size"] as? String)
    }
    return DecisionModelListResponse(models: models)
  }

  public func run(
    _ request: DecisionExperimentRequest, persist: Bool = true
  ) async -> DecisionExperimentRecord {
    let start = Date()
    do {
      try Self.validate(request)
      let path = request.provider.kind == .ollaya ? "api/decide" : "v1/systemone"
      let (url, _) = try Self.endpoint(config: request.provider, path: path)
      var urlRequest = URLRequest(url: url)
      urlRequest.httpMethod = "POST"
      urlRequest.timeoutInterval = 60
      urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
      Self.authorize(&urlRequest, apiKey: request.provider.apiKey)
      let payload = DecisionWireRequest(
        model: request.model, state: request.state, questions: request.questions)
      urlRequest.httpBody = try JSONEncoder().encode(payload)
      let data = try await Self.perform(urlRequest)
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      let root = try Self.jsonObject(data)
      let record = DecisionExperimentRecord(
        request: request, status: .completed, response: value,
        respondingModel: root["model"] as? String,
        durationMilliseconds: Int(Date().timeIntervalSince(start) * 1_000))
      if persist { add(record) }
      return record
    } catch {
      let record = DecisionExperimentRecord(
        request: request, status: .failed,
        durationMilliseconds: Int(Date().timeIntervalSince(start) * 1_000),
        error: error.localizedDescription)
      if persist { add(record) }
      return record
    }
  }

  private func add(_ record: DecisionExperimentRecord) {
    runs.insert(record, at: 0)
    runs = Array(runs.prefix(200))
    save()
  }

  private func save() {
    guard let storeURL else { return }
    do {
      try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(runs).write(to: storeURL, options: .atomic)
    } catch {}
  }

  private static func validate(_ request: DecisionExperimentRequest) throws {
    guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw DecisionLabError.invalidRequest("意思決定モデルを選択してください。")
    }
    guard !request.questions.isEmpty, request.questions.count <= 256 else {
      throw DecisionLabError.invalidRequest("質問は1〜256件で指定してください。")
    }
    for (id, question) in request.questions {
      guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DecisionLabError.invalidRequest("質問IDを入力してください。")
      }
      switch (question.type, question.criteria) {
      case (.choice, .array(let values)) where values.count >= 2: break
      case (.choice, .object(let values)) where values.count >= 2: break
      case (.score, .array(let values)) where (2...10).contains(values.count): break
      case (.noul, nil), (.noul, .object): break
      default:
        throw DecisionLabError.invalidRequest("\(id)の選択肢／評価基準が正しくありません。")
      }
    }
  }

  private static func endpoint(config: DecisionProviderConfig, path: String) throws -> (URL, String) {
    guard let base = URL(string: config.baseURL), let scheme = base.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { throw DecisionLabError.invalidRequest("ProviderのBase URLが正しくありません。") }
    return (base.appending(path: path), scheme)
  }

  private static func authorize(_ request: inout URLRequest, apiKey: String?) {
    guard let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
  }

  private static func perform(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      let root = (try? jsonObject(data)) ?? [:]
      throw DecisionLabError.provider(root["error"] as? String ?? "意思決定Providerへの接続に失敗しました。")
    }
    return data
  }

  private static func jsonObject(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw DecisionLabError.provider("Providerが不正なJSONを返しました。")
    }
    return value
  }

  private static func load(from url: URL) throws -> [DecisionExperimentRecord] {
    try JSONDecoder().decode([DecisionExperimentRecord].self, from: Data(contentsOf: url))
  }
}

private struct DecisionWireRequest: Encodable {
  let model: String
  let state: JSONValue
  let questions: [String: DecisionQuestion]
}
