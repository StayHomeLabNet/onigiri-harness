import Foundation

public struct OpenAICompatibleMessage: Codable, Sendable, Equatable {
  public enum Role: String, Codable, Sendable { case system, user, assistant }
  public let role: Role
  public let content: String

  public init(role: Role, content: String) {
    self.role = role
    self.content = content
  }
}

public struct OpenAICompatibilityOptions: Codable, Sendable, Equatable {
  public let profileID: UUID?
  public let profileName: String?
  public let ragMode: RAGMode?
  public let searchSettings: KnowledgeSearchSettings?
  public let contextLimit: Int?
  public let selectedChunkIDs: [String]?

  public init(
    profileID: UUID? = nil, profileName: String? = nil, ragMode: RAGMode? = nil,
    searchSettings: KnowledgeSearchSettings? = nil, contextLimit: Int? = nil,
    selectedChunkIDs: [String]? = nil
  ) {
    self.profileID = profileID
    self.profileName = profileName
    self.ragMode = ragMode
    self.searchSettings = searchSettings
    self.contextLimit = contextLimit
    self.selectedChunkIDs = selectedChunkIDs
  }
}

public struct OpenAIChatCompletionsRequest: Codable, Sendable, Equatable {
  public let model: String
  public let messages: [OpenAICompatibleMessage]
  public let stream: Bool?
  public let user: String?
  public let onigiri: OpenAICompatibilityOptions?

  public init(
    model: String, messages: [OpenAICompatibleMessage], stream: Bool? = nil,
    user: String? = nil, onigiri: OpenAICompatibilityOptions? = nil
  ) {
    self.model = model
    self.messages = messages
    self.stream = stream
    self.user = user
    self.onigiri = onigiri
  }

  public func conversation() throws -> OpenAICompatibilityConversation {
    guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let lastUserIndex = messages.lastIndex(where: { $0.role == .user })
    else { throw OpenAICompatibilityError.invalidRequest("modelとuserメッセージが必要です。") }
    let prompt = try Harness.validatedMessage(messages[lastUserIndex].content)
    let history = messages[..<lastUserIndex].compactMap { message -> ChatHistoryMessage? in
      switch message.role {
      case .user: return ChatHistoryMessage(role: .user, content: message.content)
      case .assistant: return ChatHistoryMessage(role: .assistant, content: message.content)
      case .system: return nil
      }
    }
    let systemInstructions = messages.prefix(lastUserIndex + 1)
      .filter { $0.role == .system }.map(\.content)
      .joined(separator: "\n\n")
    return OpenAICompatibilityConversation(
      prompt: prompt, history: history,
      systemInstructions: systemInstructions.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}

public struct OpenAICompatibilityConversation: Sendable, Equatable {
  public let prompt: String
  public let history: [ChatHistoryMessage]
  public let systemInstructions: String
}

public struct CompatibilityProductProfile: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let providerID: String
  public let baseURL: String
  public let modelID: String
  public let systemInstructions: String
  public let ragMode: RAGMode
  public let searchSettings: KnowledgeSearchSettings
  public let contextLimit: Int

  public var providerConfig: ProviderConfig {
    ProviderConfig(
      providerID: providerID, baseURL: baseURL.nilIfEmpty, modelID: modelID.nilIfEmpty)
  }

  public var runtime: ChatRuntimeOptions {
    ChatRuntimeOptions(
      systemInstructions: systemInstructions, ragMode: ragMode,
      searchSettings: searchSettings, contextLimit: contextLimit)
  }
}

public struct CompatibilityProductProfileStore: Codable, Sendable, Equatable {
  public let formatVersion: Int
  public let defaultProfileID: UUID
  public let profiles: [CompatibilityProductProfile]
}

public struct OpenAIModelObject: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let object: String
  public let created: Int
  public let ownedBy: String

  enum CodingKeys: String, CodingKey {
    case id, object, created
    case ownedBy = "owned_by"
  }

  public init(id: String, created: Int = 0, ownedBy: String = "onigiri-harness") {
    self.id = id
    self.object = "model"
    self.created = created
    self.ownedBy = ownedBy
  }
}

public struct OpenAIModelList: Codable, Sendable, Equatable {
  public let object: String
  public let data: [OpenAIModelObject]
  public init(data: [OpenAIModelObject]) { object = "list"; self.data = data }
}

public struct OpenAICompatibilityCitation: Codable, Sendable, Equatable {
  public let index: Int
  public let chunkID: String
  public let documentID: UUID
  public let title: String
  public let chunkIndex: Int

  enum CodingKeys: String, CodingKey {
    case index, title
    case chunkID = "chunk_id"
    case documentID = "document_id"
    case chunkIndex = "chunk_index"
  }

  public init(_ match: KnowledgeChunkMatch) {
    index = match.citationIndex
    chunkID = match.id
    documentID = match.documentID
    title = match.title
    chunkIndex = match.chunkIndex
  }
}

public struct OpenAICompatibilityMetadata: Codable, Sendable, Equatable {
  public let ragMode: RAGMode
  public let citations: [OpenAICompatibilityCitation]
  public let ragTrace: AgenticRAGTrace?

  enum CodingKeys: String, CodingKey {
    case citations
    case ragMode = "rag_mode"
    case ragTrace = "rag_trace"
  }

  public init(ragMode: RAGMode, matches: [KnowledgeChunkMatch], ragTrace: AgenticRAGTrace?) {
    self.ragMode = ragMode
    citations = matches.map(OpenAICompatibilityCitation.init)
    self.ragTrace = ragTrace
  }
}

public struct OpenAICompatibilityContext: Sendable, Equatable {
  public let matches: [KnowledgeChunkMatch]
  public let ragTrace: AgenticRAGTrace?

  public init(matches: [KnowledgeChunkMatch], ragTrace: AgenticRAGTrace?) {
    self.matches = matches
    self.ragTrace = ragTrace
  }
}

public actor CompatibilityProfileCatalog {
  public static var defaultStoreURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "product-profiles.json")
  }

  private let storeURL: URL
  public init(storeURL: URL = CompatibilityProfileCatalog.defaultStoreURL) { self.storeURL = storeURL }

  public func store() -> CompatibilityProductProfileStore? {
    guard let data = try? Data(contentsOf: storeURL) else { return nil }
    return try? JSONDecoder().decode(CompatibilityProductProfileStore.self, from: data)
  }

  public func profiles() -> [CompatibilityProductProfile] { store()?.profiles ?? [] }

  public func resolve(id: UUID?, name: String?) throws -> CompatibilityProductProfile? {
    guard id != nil || !(name ?? "").isEmpty else { return nil }
    let profiles = profiles()
    if let id, let profile = profiles.first(where: { $0.id == id }) { return profile }
    if let name, let profile = profiles.first(where: {
      $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }) { return profile }
    throw OpenAICompatibilityError.profileNotFound(id?.uuidString ?? name ?? "")
  }
}

public struct OpenAIChatCompletionResponse: Codable, Sendable, Equatable {
  public struct Choice: Codable, Sendable, Equatable {
    public let index: Int
    public let message: OpenAICompatibleMessage
    public let finishReason: String
    enum CodingKeys: String, CodingKey { case index, message; case finishReason = "finish_reason" }
  }

  public let id: String
  public let object: String
  public let created: Int
  public let model: String
  public let choices: [Choice]
  public let onigiri: OpenAICompatibilityMetadata

  public init(
    id: String, created: Int, model: String, content: String,
    metadata: OpenAICompatibilityMetadata
  ) {
    self.id = id
    self.object = "chat.completion"
    self.created = created
    self.model = model
    choices = [Choice(
      index: 0, message: OpenAICompatibleMessage(role: .assistant, content: content),
      finishReason: "stop")]
    onigiri = metadata
  }
}

public struct OpenAIChatCompletionStreamChunk: Codable, Sendable, Equatable {
  public struct Delta: Codable, Sendable, Equatable {
    public let role: String?
    public let content: String?
    public init(role: String? = nil, content: String? = nil) { self.role = role; self.content = content }
  }
  public struct Choice: Codable, Sendable, Equatable {
    public let index: Int
    public let delta: Delta
    public let finishReason: String?
    enum CodingKeys: String, CodingKey { case index, delta; case finishReason = "finish_reason" }
  }
  public let id: String
  public let object: String
  public let created: Int
  public let model: String
  public let choices: [Choice]
  public let onigiri: OpenAICompatibilityMetadata?

  public init(
    id: String, created: Int, model: String, role: String? = nil, content: String? = nil,
    finishReason: String? = nil, metadata: OpenAICompatibilityMetadata? = nil
  ) {
    self.id = id; self.object = "chat.completion.chunk"; self.created = created; self.model = model
    choices = [Choice(
      index: 0, delta: Delta(role: role, content: content), finishReason: finishReason)]
    onigiri = metadata
  }
}

public struct OpenAIErrorResponse: Codable, Sendable, Equatable {
  public struct Detail: Codable, Sendable, Equatable {
    public let message: String
    public let type: String
    public let param: String?
    public let code: String?
  }
  public let error: Detail

  public init(message: String, type: String = "invalid_request_error", param: String? = nil, code: String? = nil) {
    error = Detail(message: message, type: type, param: param, code: code)
  }
}

public enum OpenAICompatibilityError: LocalizedError {
  case invalidRequest(String)
  case modelNotFound(String)
  case profileNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRequest(let detail): return detail
    case .modelNotFound(let model): return "モデル「\(model)」が見つかりません。"
    case .profileNotFound(let profile): return "Profile「\(profile)」が見つかりません。"
    }
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
