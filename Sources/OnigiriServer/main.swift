import Foundation
import Network
import OnigiriCore

// Minimal HTTP/1.1 transport for the native client. One request per connection.
final class HTTPConnection: @unchecked Sendable {
  private enum ChunkedBody {
    case incomplete
    case complete(Data)
    case invalid
    case tooLarge
  }

  let connection: NWConnection
  let harness: Harness
  let codexAgentManager: CodexAgentManager
  let knowledgeToolAuditLog: KnowledgeToolAuditLog
  let decisionLabManager: DecisionLabManager
  let decisionEvaluationManager: DecisionEvaluationManager
  let compatibilityProfileCatalog: CompatibilityProfileCatalog
  let apiToken: String?
  var buffer = Data()
  var finished = false
  var timeout: DispatchWorkItem?
  static let queue = DispatchQueue(label: "onigiri.http")
  static let maxHeaderBytes = 16_384
  static let defaultMaxBodyBytes = 32_768
  static let knowledgeDocumentMaxBodyBytes = 1_500_000
  static let chunkedBodyOverheadBytes = 65_536

  init(
    _ connection: NWConnection, harness: Harness, codexAgentManager: CodexAgentManager,
    knowledgeToolAuditLog: KnowledgeToolAuditLog, decisionLabManager: DecisionLabManager,
    decisionEvaluationManager: DecisionEvaluationManager,
    compatibilityProfileCatalog: CompatibilityProfileCatalog, apiToken: String?
  ) {
    self.connection = connection
    self.harness = harness
    self.codexAgentManager = codexAgentManager
    self.knowledgeToolAuditLog = knowledgeToolAuditLog
    self.decisionLabManager = decisionLabManager
    self.decisionEvaluationManager = decisionEvaluationManager
    self.compatibilityProfileCatalog = compatibilityProfileCatalog
    self.apiToken = apiToken
  }

  func start() {
    connection.start(queue: Self.queue)
    let timeout = DispatchWorkItem { [weak self] in self?.connection.cancel() }
    self.timeout = timeout
    Self.queue.asyncAfter(deadline: .now() + 120, execute: timeout)
    receive()
  }

  func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
      [self] data, _, complete, error in
      if let data { buffer.append(data) }
      guard error == nil else {
        close()
        return
      }
      if buffer.count
        > Self.maxHeaderBytes + Self.knowledgeDocumentMaxBodyBytes + Self.chunkedBodyOverheadBytes
      {
        sendJSON(413, APIError(error: "リクエストが大きすぎます。"))
        return
      }
      if !parse(), !finished {
        if complete { close() } else { receive() }
      }
    }
  }

  func parse() -> Bool {
    guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
      if buffer.count > Self.maxHeaderBytes {
        sendJSON(413, APIError(error: "リクエストヘッダーが大きすぎます。"))
        return true
      }
      return false
    }
    guard let header = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else {
      sendJSON(400, APIError(error: "Invalid HTTP header"))
      return true
    }
    let lines = header.components(separatedBy: "\r\n")
    let route = lines[0].split(separator: " ")
    guard route.count == 3 else {
      sendJSON(400, APIError(error: "Invalid request"))
      return true
    }
    let method = String(route[0])
    let path = String(route[1])
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, headers[String(parts[0]).lowercased()] == nil else {
        sendJSON(400, APIError(error: "Invalid or duplicate header"))
        return true
      }
      headers[String(parts[0]).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
    }
    let maxBodyBytes =
      method == "POST" && (path == "/knowledge/document" || path == "/decision/run"
        || path == "/decision/evaluations/run")
      ? Self.knowledgeDocumentMaxBodyBytes : Self.defaultMaxBodyBytes

    let body: Data
    if let transferEncoding = headers["transfer-encoding"]?.lowercased() {
      guard transferEncoding == "chunked" else {
        sendJSON(400, APIError(error: "Unsupported transfer encoding"))
        return true
      }
      switch decodeChunkedBody(startingAt: boundary.upperBound, maxBodyBytes: maxBodyBytes) {
      case .incomplete:
        return false
      case .complete(let decodedBody):
        body = decodedBody
      case .invalid:
        sendJSON(400, APIError(error: "Invalid chunked body"))
        return true
      case .tooLarge:
        sendBodyTooLarge(method: method, path: path)
        return true
      }
    } else {
      guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
        sendJSON(400, APIError(error: "Invalid body length"))
        return true
      }
      guard length <= maxBodyBytes else {
        sendBodyTooLarge(method: method, path: path)
        return true
      }
      guard buffer.count - boundary.upperBound >= length else { return false }
      body = buffer.subdata(in: boundary.upperBound..<(boundary.upperBound + length))
    }

    finished = true
    guard headers["origin"] == nil else {
      sendJSON(403, APIError(error: "Browser requests are not supported"))
      return true
    }
    if let apiToken,
      headers["authorization"] != "Bearer \(apiToken)"
    {
      sendJSON(401, APIError(error: "有効なBearer tokenが必要です。"))
      return true
    }

    Task {
      if method == "GET", path == "/health" {
        let status = await harness.status()
        sendJSON(200, status)
      } else if method == "GET", path == "/v1/models" {
        await sendCompatibilityModels()
      } else if method == "POST", path == "/v1/chat/completions" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(OpenAIChatCompletionsRequest.self, from: body)
        else {
          sendOpenAIError(400, "JSONのmodelとmessagesが必要です。")
          return
        }
        do {
          let resolved = try await resolveCompatibilityRequest(request)
          if request.stream == true {
            await streamOpenAICompletion(request, resolved: resolved)
          } else {
            await sendOpenAICompletion(request, resolved: resolved)
          }
        } catch {
          sendOpenAIError(statusCode(for: error), error.localizedDescription)
        }
      } else if method == "GET", path == "/providers" {
        let providers = await harness.providerOptions()
        sendJSON(200, providers)
      } else if method == "GET", path == "/models" {
        do {
          let models = try await harness.availableModelIDs()
          sendJSON(200, ModelListResponse(models: models))
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/provider" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(ProviderConfig.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の providerID が必要です。"))
          return
        }
        do {
          let selected = try await harness.configureProvider(request)
          sendJSON(200, selected)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "GET", path == "/codex/status" {
        sendJSON(200, await codexAgentManager.availability())
      } else if method == "GET", path == "/agents/status" {
        sendJSON(200, await codexAgentManager.availabilities())
      } else if method == "GET", (path == "/codex/tasks" || path == "/agents/tasks") {
        sendJSON(200, await codexAgentManager.list())
      } else if method == "POST", (path == "/codex/tasks" || path == "/agents/tasks") {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(CodexTaskRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の prompt と workingDirectory が必要です。"))
          return
        }
        do {
          sendJSON(200, try await codexAgentManager.start(request))
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", (path == "/codex/tasks/cancel" || path == "/agents/tasks/cancel") {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(CodexTaskActionRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の id が必要です。"))
          return
        }
        do {
          sendJSON(200, try await codexAgentManager.cancel(request.id))
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "GET", path == "/decision/providers" {
        sendJSON(200, DecisionProviderCatalog.descriptors)
      } else if method == "POST", path == "/decision/models" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(DecisionModelListRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の provider が必要です。"))
          return
        }
        do {
          sendJSON(200, try await decisionLabManager.models(for: request.provider))
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "GET", path == "/decision/runs" {
        sendJSON(200, await decisionLabManager.list())
      } else if method == "POST", path == "/decision/runs/clear" {
        sendJSON(200, await decisionLabManager.clear())
      } else if method == "POST", path == "/decision/run" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(DecisionExperimentRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "意思決定実験のJSONが正しくありません。"))
          return
        }
        sendJSON(200, await decisionLabManager.run(request))
      } else if method == "GET", path == "/decision/evaluations" {
        sendJSON(200, await decisionEvaluationManager.list())
      } else if method == "POST", path == "/decision/evaluations/clear" {
        sendJSON(200, await decisionEvaluationManager.clear())
      } else if method == "POST", path == "/decision/evaluations/run" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(DecisionEvaluationRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "意思決定評価のJSONが正しくありません。"))
          return
        }
        do {
          let report = try await decisionEvaluationManager.evaluate(request) { experiment in
            await decisionLabManager.run(experiment, persist: false)
          }
          sendJSON(200, report)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "GET", path == "/tools/audit" {
        sendJSON(200, await knowledgeToolAuditLog.list())
      } else if method == "POST", path == "/tools/audit/clear" {
        sendJSON(200, await knowledgeToolAuditLog.clear())
      } else if method == "GET", path == "/tools/knowledge" {
        sendJSON(200, RAGToolCatalog.descriptors)
      } else if method == "POST", path == "/tools/searchKnowledge" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(SearchKnowledgeToolRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の query が必要です。"))
          return
        }
        let startedAt = Date()
        let source = toolSource(from: headers)
        do {
          let response = try await harness.searchKnowledgeTool(request)
          await knowledgeToolAuditLog.append(
            KnowledgeToolAuditEntry(
              source: source, toolName: KnowledgeToolName.searchKnowledge.rawValue,
              access: .readOnly, requestSummary: request.query, success: true,
              durationMilliseconds: elapsedMilliseconds(since: startedAt),
              resultCount: response.matches.count))
          sendJSON(200, response)
        } catch {
          await knowledgeToolAuditLog.append(
            KnowledgeToolAuditEntry(
              source: source, toolName: KnowledgeToolName.searchKnowledge.rawValue,
              access: .readOnly, requestSummary: request.query, success: false,
              durationMilliseconds: elapsedMilliseconds(since: startedAt),
              error: error.localizedDescription))
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/tools/getKnowledgeChunk" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(GetKnowledgeChunkToolRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の chunkID が必要です。"))
          return
        }
        let startedAt = Date()
        let response = await harness.getKnowledgeChunkTool(request)
        await knowledgeToolAuditLog.append(
          KnowledgeToolAuditEntry(
            source: toolSource(from: headers),
            toolName: KnowledgeToolName.getKnowledgeChunk.rawValue, access: .readOnly,
            requestSummary: request.chunkID, success: response.chunk != nil,
            durationMilliseconds: elapsedMilliseconds(since: startedAt),
            resultCount: response.chunk == nil ? 0 : 1,
            error: response.chunk == nil ? "指定されたチャンクが見つかりません。" : nil))
        sendJSON(200, response)
      } else if method == "GET", path == "/knowledge" {
        let status = await harness.knowledgeStatus()
        sendJSON(200, status)
      } else if method == "GET", path == "/knowledge/documents" {
        let documents = await harness.knowledgeDocuments()
        sendJSON(200, documents)
      } else if method == "GET", path == "/knowledge/chunking" {
        let response = await harness.knowledgeChunkingSettings()
        sendJSON(200, response)
      } else if method == "POST", path == "/knowledge/chunking" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(KnowledgeChunkingSettings.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の maxCharacters と overlapCharacters が必要です。"))
          return
        }
        do {
          let response = try await harness.configureKnowledgeChunking(request)
          sendJSON(200, response)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "GET", path.hasPrefix("/knowledge/documents/"), path.hasSuffix("/chunks")
      {
        let parts = path.split(separator: "/")
        guard parts.count == 4, let documentID = UUID(uuidString: String(parts[2])) else {
          sendJSON(400, APIError(error: "資料IDが正しくありません。"))
          return
        }
        let chunks = await harness.knowledgeChunks(for: documentID)
        sendJSON(200, chunks)
      } else if method == "POST", path.hasPrefix("/knowledge/documents/"), path.hasSuffix("/search")
      {
        let parts = path.split(separator: "/")
        guard parts.count == 4, let documentID = UUID(uuidString: String(parts[2])) else {
          sendJSON(400, APIError(error: "資料IDが正しくありません。"))
          return
        }
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(KnowledgeChunkSearchRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の query が必要です。"))
          return
        }
        do {
          let results = try await harness.searchKnowledgeChunks(
            documentID: documentID, query: request.query, settings: request.searchSettings)
          sendJSON(200, results)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/knowledge/document" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(KnowledgeDocumentRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の title と content が必要です。"))
          return
        }
        do {
          let status = try await harness.addKnowledgeDocument(request)
          sendJSON(200, status)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/knowledge/delete" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(KnowledgeDocumentDeleteRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の id が必要です。"))
          return
        }
        do {
          let status = try await harness.deleteKnowledgeDocument(request.id)
          sendJSON(200, status)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/knowledge/search" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(KnowledgeSearchRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の query が必要です。"))
          return
        }
        do {
          let matches = try await harness.searchKnowledge(
            query: request.query, settings: request.searchSettings)
          sendJSON(200, matches)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/evaluation/run" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(RAGEvaluationRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の question、expectedChunkIDs、searchSettings が必要です。"))
          return
        }
        do {
          let result = try await harness.evaluateRAG(request)
          sendJSON(200, result)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/knowledge/embeddings" {
        do {
          let status = try await harness.refreshKnowledgeEmbeddings()
          sendJSON(200, status)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/knowledge/clear" {
        do {
          let status = try await harness.clearKnowledge()
          sendJSON(200, status)
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else if method == "POST", path == "/chat/stream" {
        guard isJSON(headers), let request = try? JSONDecoder().decode(ChatRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の conversationID と message が必要です。"))
          return
        }
        guard (try? Harness.validatedMessage(request.message)) != nil else {
          sendJSON(400, APIError(error: HarnessError.invalidMessage.localizedDescription))
          return
        }
        let status = await harness.status()
        guard status.available else {
          sendJSON(503, APIError(error: status.detail))
          return
        }
        await streamChat(request)
      } else if method == "POST", path == "/chat/cancel" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(ConversationRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の conversationID が必要です。"))
          return
        }
        let cancelled = await harness.cancelGeneration(request.conversationID)
        sendJSON(200, ConversationResponse(cleared: cancelled))
      } else if method == "POST", path == "/conversation/reset" {
        guard isJSON(headers),
          let request = try? JSONDecoder().decode(ConversationRequest.self, from: body)
        else {
          sendJSON(400, APIError(error: "JSON の conversationID が必要です。"))
          return
        }
        do {
          let cleared = try await harness.clearConversation(request.conversationID)
          sendJSON(200, ConversationResponse(cleared: cleared))
        } catch {
          sendJSON(statusCode(for: error), APIError(error: error.localizedDescription))
        }
      } else {
        sendJSON(404, APIError(error: "Not found"))
      }
    }
    return true
  }

  private func isJSON(_ headers: [String: String]) -> Bool {
    headers["content-type"]?.lowercased().hasPrefix("application/json") == true
  }

  private struct ResolvedCompatibilityRequest {
    let conversation: OpenAICompatibilityConversation
    let provider: ProviderConfig?
    let runtime: ChatRuntimeOptions
    let selectedChunkIDs: [String]?
  }

  private func sendCompatibilityModels() async {
    let current = await harness.providerOptions().current
    var identifiers = ["onigiri/current"]
    if let configured = current.modelID, !configured.isEmpty { identifiers.append(configured) }
    if let available = try? await harness.availableModelIDs() { identifiers.append(contentsOf: available) }
    let profiles = await compatibilityProfileCatalog.profiles()
    identifiers.append(contentsOf: profiles.map { "profile/\($0.id.uuidString.lowercased())" })
    var seen: Set<String> = []
    let uniqueIdentifiers = identifiers.filter { seen.insert($0).inserted }
    let models = uniqueIdentifiers.map { OpenAIModelObject(id: $0) }
    sendJSON(200, OpenAIModelList(data: models))
  }

  private func resolveCompatibilityRequest(
    _ request: OpenAIChatCompletionsRequest
  ) async throws -> ResolvedCompatibilityRequest {
    let conversation = try request.conversation()
    var profileID = request.onigiri?.profileID
    var profileName = request.onigiri?.profileName
    if request.model.hasPrefix("profile/") {
      let selector = String(request.model.dropFirst("profile/".count))
      if let id = UUID(uuidString: selector) { profileID = id } else { profileName = selector }
    }
    let profile = try await compatibilityProfileCatalog.resolve(id: profileID, name: profileName)
    let current = await harness.providerOptions().current
    let provider: ProviderConfig?
    var runtime = profile?.runtime ?? .default
    if let profile {
      provider = profile.providerConfig
    } else if request.model == "onigiri/current" || request.model == current.modelID
      || request.model == current.providerID
    {
      provider = nil
    } else {
      let models = (try? await harness.availableModelIDs()) ?? []
      guard models.contains(request.model) else {
        throw OpenAICompatibilityError.modelNotFound(request.model)
      }
      provider = ProviderConfig(
        providerID: current.providerID, baseURL: current.baseURL, modelID: request.model)
    }
    let options = request.onigiri
    let instructions = conversation.systemInstructions.isEmpty
      ? runtime.systemInstructions : conversation.systemInstructions
    runtime = ChatRuntimeOptions(
      systemInstructions: instructions, ragMode: options?.ragMode ?? runtime.ragMode,
      searchSettings: options?.searchSettings ?? runtime.searchSettings,
      contextLimit: options?.contextLimit ?? runtime.contextLimit)
    return ResolvedCompatibilityRequest(
      conversation: conversation, provider: provider, runtime: runtime,
      selectedChunkIDs: options?.selectedChunkIDs)
  }

  private func sendOpenAICompletion(
    _ request: OpenAIChatCompletionsRequest, resolved: ResolvedCompatibilityRequest
  ) async {
    let completionID = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let created = Int(Date().timeIntervalSince1970)
    var content = ""
    var context = OpenAICompatibilityContext(matches: [], ragTrace: nil)
    do {
      try await harness.streamCompatibilityResponse(
        to: resolved.conversation.prompt, conversationID: UUID(),
        history: resolved.conversation.history, selectedChunkIDs: resolved.selectedChunkIDs,
        runtime: resolved.runtime, providerConfig: resolved.provider,
        onContext: { context = $0 }
      ) { content = $0 }
      sendJSON(200, OpenAIChatCompletionResponse(
        id: completionID, created: created, model: request.model, content: content,
        metadata: OpenAICompatibilityMetadata(
          ragMode: resolved.runtime.ragMode, matches: context.matches,
          ragTrace: context.ragTrace)))
    } catch {
      sendOpenAIError(statusCode(for: error), error.localizedDescription)
    }
  }

  private func streamOpenAICompletion(
    _ request: OpenAIChatCompletionsRequest, resolved: ResolvedCompatibilityRequest
  ) async {
    let completionID = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let created = Int(Date().timeIntervalSince1970)
    var previous = ""
    var context = OpenAICompatibilityContext(matches: [], ragTrace: nil)
    do {
      try await beginSSEStream()
      try await sendSSE(OpenAIChatCompletionStreamChunk(
        id: completionID, created: created, model: request.model, role: "assistant"))
      try await harness.streamCompatibilityResponse(
        to: resolved.conversation.prompt, conversationID: UUID(),
        history: resolved.conversation.history, selectedChunkIDs: resolved.selectedChunkIDs,
        runtime: resolved.runtime, providerConfig: resolved.provider,
        onContext: { context = $0 }
      ) { snapshot in
        let delta = snapshot.hasPrefix(previous) ? String(snapshot.dropFirst(previous.count)) : snapshot
        previous = snapshot
        guard !delta.isEmpty else { return }
        try await self.sendSSE(OpenAIChatCompletionStreamChunk(
          id: completionID, created: created, model: request.model, content: delta))
      }
      try await sendSSE(OpenAIChatCompletionStreamChunk(
        id: completionID, created: created, model: request.model, finishReason: "stop",
        metadata: OpenAICompatibilityMetadata(
          ragMode: resolved.runtime.ragMode, matches: context.matches,
          ragTrace: context.ragTrace)))
      try await sendSSEData("[DONE]")
    } catch {
      try? await sendSSE(OpenAIErrorResponse(
        message: error.localizedDescription, type: "server_error"))
      try? await sendSSEData("[DONE]")
    }
    try? await endStream()
  }

  private func beginSSEStream() async throws {
    let header =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    try await sendData(Data(header.utf8))
  }

  private func sendSSE<T: Encodable>(_ value: T) async throws {
    let data = try JSONEncoder().encode(value)
    guard let json = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    try await sendSSEData(json)
  }

  private func sendSSEData(_ payload: String) async throws {
    let event = Data("data: \(payload)\n\n".utf8)
    var chunk = Data(String(event.count, radix: 16).utf8)
    chunk.append(Data("\r\n".utf8))
    chunk.append(event)
    chunk.append(Data("\r\n".utf8))
    try await sendData(chunk)
  }

  private func sendOpenAIError(_ status: Int, _ message: String) {
    sendJSON(status, OpenAIErrorResponse(
      message: message, type: status == 404 ? "invalid_request_error" : "server_error"))
  }

  private func sendBodyTooLarge(method: String, path: String) {
    let message =
      method == "POST" && path == "/knowledge/document"
      ? "資料が大きすぎます。1ファイル20万文字以内にしてください。"
      : "リクエストが大きすぎます。"
    sendJSON(413, APIError(error: message))
  }

  private func decodeChunkedBody(startingAt start: Data.Index, maxBodyBytes: Int) -> ChunkedBody {
    let newline = Data("\r\n".utf8)
    var cursor = start
    var body = Data()

    while true {
      guard let lineRange = buffer.range(of: newline, in: cursor..<buffer.endIndex) else {
        return .incomplete
      }
      guard
        let line = String(data: buffer[cursor..<lineRange.lowerBound], encoding: .ascii),
        let sizeText = line.split(separator: ";", maxSplits: 1).first
      else {
        return .invalid
      }
      let trimmedSize = sizeText.trimmingCharacters(in: .whitespaces)
      guard let size = Int(trimmedSize, radix: 16), size >= 0 else {
        return .invalid
      }
      cursor = lineRange.upperBound

      if size == 0 {
        guard let trailerEnd = buffer.range(of: newline, in: cursor..<buffer.endIndex) else {
          return .incomplete
        }
        guard trailerEnd.lowerBound == cursor else {
          return .invalid
        }
        return .complete(body)
      }

      guard body.count + size <= maxBodyBytes else {
        return .tooLarge
      }
      guard buffer.endIndex >= cursor + size + newline.count else {
        return .incomplete
      }
      let chunkEnd = cursor + size
      guard buffer[chunkEnd..<(chunkEnd + newline.count)].elementsEqual(newline) else {
        return .invalid
      }
      body.append(buffer[cursor..<chunkEnd])
      cursor = chunkEnd + newline.count
    }
  }

  private func streamChat(_ request: ChatRequest) async {
    do {
      try await beginStream()
      try await harness.streamResponse(
        to: request.message, conversationID: request.conversationID, history: request.history,
        selectedChunkIDs: request.selectedChunkIDs, runtime: request.runtime ?? .default,
        onRAGTrace: { trace in
          let data = try JSONEncoder().encode(trace)
          guard let content = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
          }
          try await self.sendChunk(ChatStreamEvent(kind: .ragTrace, content: content))
        }
      ) { content in
        try await self.sendChunk(ChatStreamEvent(kind: .snapshot, content: content))
      }
      try await sendChunk(ChatStreamEvent(kind: .done))
    } catch {
      try? await sendChunk(ChatStreamEvent(kind: .error, content: error.localizedDescription))
    }
    try? await endStream()
  }

  private func beginStream() async throws {
    let header =
      "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
    try await sendData(Data(header.utf8))
  }

  private func sendChunk<T: Encodable>(_ value: T) async throws {
    var payload = try JSONEncoder().encode(value)
    payload.append(0x0A)
    var chunk = Data(String(payload.count, radix: 16).utf8)
    chunk.append(Data("\r\n".utf8))
    chunk.append(payload)
    chunk.append(Data("\r\n".utf8))
    try await sendData(chunk)
  }

  private func endStream() async throws {
    try await sendData(Data("0\r\n\r\n".utf8))
    close()
  }

  private func sendData(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      connection.send(
        content: data,
        completion: .contentProcessed { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: ())
          }
        })
    }
  }

  private func statusCode(for error: Error) -> Int {
    switch error {
    case CodexAgentError.invalidRequest: return 400
    case CodexAgentError.taskNotFound: return 404
    case CodexAgentError.unavailable: return 503
    case DecisionLabError.invalidRequest: return 400
    case DecisionLabError.provider: return 502
    case OpenAICompatibilityError.invalidRequest: return 400
    case OpenAICompatibilityError.modelNotFound, OpenAICompatibilityError.profileNotFound: return 404
    case HarnessError.invalidMessage, HarnessError.invalidSelection: return 400
    case HarnessError.invalidDocument: return 400
    case HarnessError.busy: return 429
    case HarnessError.unavailable: return 503
    default: return 500
    }
  }

  private func toolSource(from headers: [String: String]) -> String {
    headers["x-onigiri-tool-source"] == "mcp" ? "mcp" : "http"
  }

  private func elapsedMilliseconds(since date: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(date) * 1_000))
  }

  func sendJSON<T: Encodable>(_ status: Int, _ value: T) {
    finished = true
    let body = (try? JSONEncoder().encode(value)) ?? Data()
    let reason =
      [
        200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 413: "Content Too Large",
        429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
        503: "Service Unavailable",
      ][status] ?? "Error"
    var response = Data(
      "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\r\n"
        .utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in self.close() })
  }

  func close() {
    timeout?.cancel()
    connection.cancel()
  }
}

let environment = ProcessInfo.processInfo.environment
let requestedHost = environment["ONIGIRI_SERVER_HOST"] ?? "127.0.0.1"
let loopbackHosts = Set(["127.0.0.1", "::1", "localhost"])
let externalEnabled = environment["ONIGIRI_ALLOW_EXTERNAL"] == "1"
let configuredToken = environment["ONIGIRI_API_TOKEN"]?
  .trimmingCharacters(in: .whitespacesAndNewlines)
let apiToken = configuredToken?.isEmpty == false ? configuredToken : nil
if !loopbackHosts.contains(requestedHost), (!externalEnabled || apiToken == nil) {
  fputs(
    "External binding requires ONIGIRI_ALLOW_EXTERNAL=1 and a non-empty ONIGIRI_API_TOKEN.\n",
    stderr)
  exit(1)
}
let storageRootURL = environment["ONIGIRI_DATA_ROOT"].map { URL(fileURLWithPath: $0) }
  ?? OnigiriDataVault.defaultRootURL
do {
  _ = try OnigiriDataVault(rootURL: storageRootURL).prepareStorage()
} catch {
  fputs("Storage preparation failed: \(error.localizedDescription)\n", stderr)
  exit(1)
}
let knowledgeStoreURL =
  environment["ONIGIRI_KNOWLEDGE_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? Harness.defaultKnowledgeStoreURL
let port = UInt16(environment["ONIGIRI_SERVER_PORT"] ?? "") ?? 18080
let harness = Harness(knowledgeStoreURL: knowledgeStoreURL)
let codexTaskStoreURL =
  environment["ONIGIRI_CODEX_TASK_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? CodexAgentManager.defaultStoreURL
let codexAgentManager = CodexAgentManager(storeURL: codexTaskStoreURL)
let knowledgeToolAuditStoreURL =
  environment["ONIGIRI_TOOL_AUDIT_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? KnowledgeToolAuditLog.defaultStoreURL
let knowledgeToolAuditLog = KnowledgeToolAuditLog(storeURL: knowledgeToolAuditStoreURL)
let decisionLabStoreURL =
  environment["ONIGIRI_DECISION_LAB_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? DecisionLabManager.defaultStoreURL
let decisionLabManager = DecisionLabManager(storeURL: decisionLabStoreURL)
let decisionEvaluationStoreURL =
  environment["ONIGIRI_DECISION_EVALUATION_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? DecisionEvaluationManager.defaultStoreURL
let decisionEvaluationManager = DecisionEvaluationManager(storeURL: decisionEvaluationStoreURL)
let compatibilityProfileStoreURL =
  environment["ONIGIRI_PROFILE_STORE_URL"].map { URL(fileURLWithPath: $0) }
  ?? CompatibilityProfileCatalog.defaultStoreURL
let compatibilityProfileCatalog = CompatibilityProfileCatalog(storeURL: compatibilityProfileStoreURL)
let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(
  host: NWEndpoint.Host(requestedHost), port: NWEndpoint.Port(rawValue: port)!)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = {
  HTTPConnection(
    $0, harness: harness, codexAgentManager: codexAgentManager,
    knowledgeToolAuditLog: knowledgeToolAuditLog, decisionLabManager: decisionLabManager,
    decisionEvaluationManager: decisionEvaluationManager,
    compatibilityProfileCatalog: compatibilityProfileCatalog, apiToken: apiToken
  ).start()
}
listener.stateUpdateHandler = { state in
  switch state {
  case .ready: print("OnigiriServer: http://\(requestedHost):\(port)")
  case .failed(let error):
    fputs("Server failed: \(error)\n", stderr)
    exit(1)
  default: break
  }
}
listener.start(queue: HTTPConnection.queue)
dispatchMain()
