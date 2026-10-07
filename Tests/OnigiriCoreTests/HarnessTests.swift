import Foundation
import Testing

@testable import OnigiriCore

private final class TestRecorder: @unchecked Sendable {
  var messages: [String] = []
  var sessionCount = 0
  var instructions: [String] = []
  var contextLimits: [Int] = []
}

private struct TestProvider: ModelProvider {
  let available: Bool
  let snapshots: [String]
  let recorder: TestRecorder?
  let embedding: (@Sendable (String) -> [Double]?)?

  init(
    available: Bool, snapshots: [String], recorder: TestRecorder? = nil,
    embedding: (@Sendable (String) -> [Double]?)? = nil
  ) {
    self.available = available
    self.snapshots = snapshots
    self.recorder = recorder
    self.embedding = embedding
  }

  var id: String { "test-provider" }
  var name: String { "Test Provider" }
  var configuration: ProviderConfig { ProviderConfig(providerID: id) }

  func status() async -> ServiceStatus {
    ServiceStatus(
      available: available,
      detail: available ? "ready" : "offline",
      providerID: id,
      providerName: name
    )
  }

  func makeSession(instructions: String) async throws -> any ModelConversationSession {
    recorder?.sessionCount += 1
    recorder?.instructions.append(instructions)
    return TestSession(snapshots: snapshots, recorder: recorder)
  }

  func makeSession(instructions: String, contextLimit: Int) async throws
    -> any ModelConversationSession
  {
    recorder?.sessionCount += 1
    recorder?.instructions.append(instructions)
    recorder?.contextLimits.append(contextLimit)
    return TestSession(snapshots: snapshots, recorder: recorder)
  }

  func availableModelIDs() async throws -> [String] {
    ["test-model"]
  }

  func embeddings(for texts: [String]) async throws -> [[Double]]? {
    guard let embedding else { return nil }
    return texts.map { embedding($0) ?? [0, 0] }
  }
}

private struct TestSession: ModelConversationSession {
  let snapshots: [String]
  let recorder: TestRecorder?

  func streamResponse(
    to message: String,
    onSnapshot: (String) async throws -> Void
  ) async throws {
    recorder?.messages.append(message)
    for snapshot in snapshots {
      try await onSnapshot(snapshot)
    }
  }
}

private final class AgenticTraceRecorder: @unchecked Sendable {
  var trace: AgenticRAGTrace?
}

private final class CompatibilityContextRecorder: @unchecked Sendable {
  var context: OpenAICompatibilityContext?
}

private struct AgenticTestProvider: ModelProvider {
  let plan: String
  let answer: String
  let recorder: TestRecorder

  var id: String { "agentic-test" }
  var name: String { "Agentic Test" }
  var configuration: ProviderConfig { ProviderConfig(providerID: id) }

  func status() async -> ServiceStatus {
    ServiceStatus(available: true, detail: "ready", providerID: id, providerName: name)
  }

  func makeSession(instructions: String) async throws -> any ModelConversationSession {
    try await makeSession(instructions: instructions, contextLimit: 6_000)
  }

  func makeSession(instructions: String, contextLimit: Int) async throws
    -> any ModelConversationSession
  {
    recorder.sessionCount += 1
    recorder.instructions.append(instructions)
    let output = instructions.contains("ONIGIRI_AGENTIC_RAG_PLANNER") ? plan : answer
    return TestSession(snapshots: [output], recorder: recorder)
  }

  func availableModelIDs() async throws -> [String] { ["agentic-test-model"] }
}

private struct CancellableTestProvider: ModelProvider {
  let recorder: TestRecorder

  init(recorder: TestRecorder = TestRecorder()) {
    self.recorder = recorder
  }

  var id: String { "cancellable" }
  var name: String { "Cancellable" }
  var configuration: ProviderConfig { ProviderConfig(providerID: id) }

  func status() async -> ServiceStatus {
    ServiceStatus(available: true, detail: "ready", providerID: id, providerName: name)
  }

  func makeSession(instructions: String) async throws -> any ModelConversationSession {
    recorder.sessionCount += 1
    return CancellableTestSession(shouldWait: recorder.sessionCount == 1)
  }

  func availableModelIDs() async throws -> [String] { [] }
}

private struct CancellableTestSession: ModelConversationSession {
  let shouldWait: Bool

  func streamResponse(
    to message: String, onSnapshot: (String) async throws -> Void
  ) async throws {
    if shouldWait { try await Task.sleep(nanoseconds: 30_000_000_000) }
    try await onSnapshot("after cancel")
  }
}

@Test func validatesInput() throws {
  #expect(try Harness.validatedMessage(" こんにちは\n") == "こんにちは")
  #expect(throws: HarnessError.self) { try Harness.validatedMessage(" \n ") }
  #expect(throws: HarnessError.self) {
    try Harness.validatedMessage(String(repeating: "あ", count: 4001))
  }
  #expect(try Harness.validatedMessage(String(repeating: "あ", count: 4000)).count == 4000)
}

@Test func streamEventRoundTrips() throws {
  let original = ChatStreamEvent(kind: .snapshot, content: "途中の返答")
  let data = try JSONEncoder().encode(original)
  #expect(try JSONDecoder().decode(ChatStreamEvent.self, from: data) == original)
}

@Test func contextBuilderKeepsLatestHistoryWithinBudget() throws {
  let history = [
    ChatHistoryMessage(role: .user, content: "OLD-MARKER-" + String(repeating: "古", count: 4_000)),
    ChatHistoryMessage(role: .assistant, content: "LATEST-MARKER 最新の回答"),
  ]
  let prompt = ContextBuilder.build(
    message: "続けて", history: history, maxCharacters: 2_000)

  #expect(prompt.count <= 2_000)
  #expect(prompt.contains("LATEST-MARKER"))
  #expect(prompt.contains("OLD-MARKER") == false)
  #expect(prompt.contains("続けて"))
}

@Test func contextBuilderBudgetsReferenceMaterialAndKeepsQuestion() throws {
  let match = KnowledgeChunkMatch(
    documentID: UUID(), title: "large.md", chunkIndex: 1, score: 10, citationIndex: 1,
    text: String(repeating: "資料", count: 4_000))
  let prompt = ContextBuilder.build(
    message: "質問です", history: [], matches: [match], maxCharacters: 2_000)

  #expect(prompt.count <= 2_000)
  #expect(prompt.contains("Reference material"))
  #expect(prompt.contains("質問です"))
}

@Test func activeGenerationCanBeCancelledAndConversationCanBeReused() async throws {
  let harness = Harness(provider: CancellableTestProvider())
  let conversationID = UUID()
  let generation = Task {
    try await harness.streamResponse(to: "long answer", conversationID: conversationID) { _ in }
  }

  var cancelled = false
  for _ in 0..<100 where !cancelled {
    cancelled = await harness.cancelGeneration(conversationID)
    if !cancelled { await Task.yield() }
  }

  #expect(cancelled)
  await #expect(throws: CancellationError.self) { try await generation.value }
  var snapshots: [String] = []
  try await harness.streamResponse(to: "retry", conversationID: conversationID) {
    snapshots.append($0)
  }
  #expect(snapshots == ["after cancel"])
}

@Test func failedStreamConsumerDiscardsPartialModelSession() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["partial"], recorder: recorder))
  let conversationID = UUID()

  await #expect(throws: CancellationError.self) {
    try await harness.streamResponse(to: "first", conversationID: conversationID) { _ in
      throw CancellationError()
    }
  }
  try await harness.streamResponse(to: "retry", conversationID: conversationID) { _ in }

  #expect(recorder.sessionCount == 2)
}

@Test func clearingUnknownConversationIsSafe() async throws {
  let harness = Harness()
  #expect(try await harness.clearConversation(UUID()) == false)
}

@Test func harnessStreamsThroughConfiguredProvider() async throws {
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["こ", "こんにちは", "こんにちは"]))
  var received: [String] = []

  try await harness.streamResponse(to: " こんにちは ", conversationID: UUID()) { content in
    received.append(content)
  }

  #expect(received == ["こ", "こんにちは"])
  let status = await harness.status()
  #expect(status.providerID == "test-provider")
  #expect(status.providerName == "Test Provider")
}

@Test func unavailableProviderFailsBeforeSessionCreation() async throws {
  let harness = Harness(provider: TestProvider(available: false, snapshots: ["unused"]))

  await #expect(throws: HarnessError.self) {
    try await harness.streamResponse(to: "こんにちは", conversationID: UUID()) { _ in }
  }
}

@Test func appleFoundationSessionResetsBeforeContextBudgetIsExceeded() throws {
  #expect(
    AppleFoundationModelsSession.shouldResetSession(
      accumulatedCharacters: 5_500, nextMessageCharacters: 700, maxCharacters: 6_000))
  #expect(
    !AppleFoundationModelsSession.shouldResetSession(
      accumulatedCharacters: 5_000, nextMessageCharacters: 700, maxCharacters: 6_000))
  #expect(
    !AppleFoundationModelsSession.shouldResetSession(
      accumulatedCharacters: 0, nextMessageCharacters: 7_000, maxCharacters: 6_000))
}

@Test func appleSensitiveContentAnalyzerFailureGetsActionableDiagnosis() {
  let error = NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15)
  #expect(AppleFoundationModelsSession.isSensitiveContentAnalysisError(error))
  #expect(
    !AppleFoundationModelsSession.isSensitiveContentAnalysisError(
      NSError(domain: "example", code: 15)))
}

@Test func invalidGeneratedCitationUsesTheOnlyAvailableSourceIndex() {
  #expect(
    Harness.normalizedCitationMarkers(in: "復旧番号です [4]", validIndexes: [1])
      == "復旧番号です [1]")
  #expect(
    Harness.normalizedCitationMarkers(in: "根拠 [9]", validIndexes: [1, 2])
      == "根拠 ")
  #expect(
    Harness.normalizedCitationMarkers(in: "配列 [4]", validIndexes: [])
      == "配列 [4]")
}

@Test func localOpenAIHistoryIsTrimmedToRecentMessages() throws {
  let system = OpenAIChatMessage(role: "system", content: "system")
  let oldUser = OpenAIChatMessage(role: "user", content: String(repeating: "古", count: 20))
  let oldAssistant = OpenAIChatMessage(
    role: "assistant", content: String(repeating: "旧", count: 20))
  let recentUser = OpenAIChatMessage(role: "user", content: "recent question")
  let recentAssistant = OpenAIChatMessage(role: "assistant", content: "recent answer")

  let trimmed = LocalOpenAICompatibleSession.trimmingHistory(
    [system, oldUser, oldAssistant, recentUser, recentAssistant], maxCharacters: 40)

  #expect(trimmed.first == system)
  #expect(!trimmed.contains(oldUser))
  #expect(!trimmed.contains(oldAssistant))
  #expect(trimmed.contains(recentUser))
  #expect(trimmed.contains(recentAssistant))
}

@Test func providerFactorySelectsLocalProvidersFromEnvironment() async throws {
  let lmStudio = ModelProviderFactory.makeFromEnvironment([
    "ONIGIRI_MODEL_PROVIDER": "lmstudio",
    "ONIGIRI_MODEL_ID": "loaded-model",
  ])
  #expect(lmStudio.id == "lmstudio")
  #expect(lmStudio.name == "LM Studio")

  let ollama = ModelProviderFactory.makeFromEnvironment([
    "ONIGIRI_MODEL_PROVIDER": "ollama",
    "ONIGIRI_MODEL_ID": "llama3.2",
  ])
  #expect(ollama.id == "ollama")
  #expect(ollama.name == "Ollama")
}

@Test func unknownProviderReportsUnavailableStatus() async throws {
  let provider = ModelProviderFactory.makeFromEnvironment(["ONIGIRI_MODEL_PROVIDER": "missing"])
  let status = await provider.status()

  #expect(status.available == false)
  #expect(status.providerID == "unknown")
}

@Test func harnessReportsProviderOptionsAndModelIDs() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))

  let providers = await harness.providerOptions()
  #expect(providers.options.contains { $0.id == "lmstudio" })
  #expect(providers.current.providerID == "test-provider")
  #expect(try await harness.availableModelIDs() == ["test-model"])
}

@Test func configuringProviderClearsExistingSessions() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: ["first"]))
  let conversationID = UUID()
  var before: [String] = []
  var after: [String] = []

  try await harness.streamResponse(to: "before", conversationID: conversationID) {
    before.append($0)
  }
  _ = try await harness.configureProvider(ProviderConfig(providerID: "apple-foundation-models"))
  let cleared = try await harness.clearConversation(conversationID)

  #expect(before == ["first"])
  #expect(cleared == false)

  let secondHarness = Harness(provider: TestProvider(available: true, snapshots: ["second"]))
  try await secondHarness.streamResponse(to: "after", conversationID: conversationID) {
    after.append($0)
  }
  #expect(after == ["second"])
}

@Test func knowledgeDocumentsAreCountedAndCleared() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  let added = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "notes.txt",
      content: "Onigiri Harness の合言葉は銀色です。\nPhase 6 は資料検索です。"
    ))

  #expect(added.documentCount == 1)
  #expect(added.chunkCount == 1)
  #expect(await harness.knowledgeStatus() == added)

  let cleared = try await harness.clearKnowledge()
  #expect(cleared.documentCount == 0)
  #expect(cleared.chunkCount == 0)
}

@Test func knowledgeChangesResetProviderSessions() async throws {
  let recorder = TestRecorder()
  let conversationID = UUID()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "secret.txt", content: "銀色のおにぎりは資料由来の合言葉です。"))

  try await harness.streamResponse(to: "銀色のおにぎり", conversationID: conversationID) { _ in }
  #expect(recorder.sessionCount == 1)
  #expect(recorder.messages.last?.contains("Reference material") == true)

  _ = try await harness.clearKnowledge()
  try await harness.streamResponse(to: "銀色のおにぎり", conversationID: conversationID) { _ in }

  #expect(recorder.sessionCount == 2)
  #expect(recorder.messages.last == "銀色のおにぎり")
}

@Test func noKnowledgeAvailabilityQuestionReturnsDeterministicAnswerAfterClear() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["誤ったモデル回答"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "temporary.md", content: "一時資料です。"))
  _ = try await harness.clearKnowledge()

  var japanese: [String] = []
  try await harness.streamResponse(
    to: "資料を持ってる？", conversationID: UUID(),
    history: [.init(role: .assistant, content: "はい。資料があります。")]
  ) { japanese.append($0) }
  #expect(japanese == ["いいえ。現在、読み込まれているRAG資料はありません。"])
  #expect(recorder.sessionCount == 0)

  var english: [String] = []
  try await harness.streamResponse(to: "Do you have any documents loaded?", conversationID: UUID()) {
    english.append($0)
  }
  #expect(english == ["No. There are currently no RAG documents loaded."])
  #expect(recorder.sessionCount == 0)
}

@Test func currentDateAndLiveDataRequestsRespectCapabilityBoundaries() async throws {
  let date = Date(timeIntervalSince1970: 1_791_763_200)
  let japaneseDate = ContextBuilder.localCapabilityResponse(for: "今日は何年何月？", now: date)
  #expect(japaneseDate?.contains("2026年10月") == true)

  let englishDate = ContextBuilder.localCapabilityResponse(for: "What month is it?", now: date)
  #expect(englishDate?.contains("October") == true)

  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["fabricated"], recorder: recorder))
  var response: [String] = []
  try await harness.streamResponse(
    to: "最新のレートをウェブ検索して", conversationID: UUID()
  ) { response.append($0) }

  #expect(response.count == 1)
  #expect(response[0].contains("Web検索やライブの外部データ取得機能がありません"))
  #expect(recorder.sessionCount == 0)
}

@Test func japaneseIMEConfirmationDoesNotSubmitChat() {
  #expect(
    ChatComposerInputPolicy.returnAction(hasMarkedText: true, shiftPressed: false)
      == .commitComposition)
  #expect(
    ChatComposerInputPolicy.returnAction(hasMarkedText: false, shiftPressed: true)
      == .insertNewline)
  #expect(
    ChatComposerInputPolicy.returnAction(hasMarkedText: false, shiftPressed: false) == .submit)
}

@Test func knowledgeChunkingSettingsRebuildExistingDocuments() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  let content = String(repeating: "未来から逆算して今日の行動を決めます。", count: 120)
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "chunking.md", content: content))
  let original = await harness.knowledgeStatus()

  let updated = try await harness.configureKnowledgeChunking(
    KnowledgeChunkingSettings(maxCharacters: 400, overlapCharacters: 80))

  #expect(updated.settings.maxCharacters == 400)
  #expect(updated.settings.overlapCharacters == 80)
  #expect(updated.status.documentCount == 1)
  #expect(updated.status.chunkCount >= original.chunkCount)
  #expect(updated.status.embeddedChunkCount == 0)
}

@Test func knowledgeChunksCanBeListedForDocumentPreview() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "chunks.md",
      content: """
        未来から逆算します。今日の行動を決めます。

        夢を紙に書きます。必要な情報を探します。
        """
    ))

  let document = await harness.knowledgeDocuments().documents[0]
  let response = await harness.knowledgeChunks(for: document.id)

  #expect(response.document?.id == document.id)
  #expect(response.chunks.count == document.chunkCount)
  #expect(response.chunks[0].chunkIndex == 1)
  #expect(response.chunks[0].isEmbedded == false)
  #expect(response.chunks[0].text.contains("未来"))
  #expect(!response.chunks[0].keywords.isEmpty)
}

@Test func knowledgeDocumentsCanBeListedAndDeleted() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "delete-me.md",
      content: "削除対象の資料です。Phase 7 で一覧表示します。"
    ))

  let documents = await harness.knowledgeDocuments().documents
  #expect(documents.count == 1)
  #expect(documents[0].title == "delete-me.md")
  #expect(documents[0].preview.contains("削除対象"))

  let status = try await harness.deleteKnowledgeDocument(documents[0].id)
  #expect(status.documentCount == 0)
  #expect(await harness.knowledgeDocuments().documents.isEmpty)
}

@Test func knowledgeDocumentsPersistWhenStoreURLIsProvided() async throws {
  let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "onigiri-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: storeURL) }

  let firstHarness = Harness(
    provider: TestProvider(available: true, snapshots: []), knowledgeStoreURL: storeURL)
  _ = try await firstHarness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "persisted.txt",
      content: "永続化された資料です。"
    ))

  let secondHarness = Harness(
    provider: TestProvider(available: true, snapshots: []), knowledgeStoreURL: storeURL)
  let documents = await secondHarness.knowledgeDocuments().documents

  #expect(documents.count == 1)
  #expect(documents[0].title == "persisted.txt")
  #expect(await secondHarness.knowledgeStatus().chunkCount == 1)
}

@Test func knowledgeChunksCanBeSearchedWithinDocument() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  let targetParagraph = String(repeating: "未来から逆算して今日の行動を決めます。", count: 90)
  let otherParagraph = String(repeating: "料理の材料を買って夕食を作ります。", count: 90)
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "steps.md",
      content: "\(targetParagraph)\n\n\(otherParagraph)"
    ))

  let document = await harness.knowledgeDocuments().documents[0]
  let response = try await harness.searchKnowledgeChunks(
    documentID: document.id,
    query: "未来 行動",
    settings: KnowledgeSearchSettings(limit: 10, minScore: 1, keywordWeight: 1, embeddingWeight: 0)
  )

  #expect(response.document?.id == document.id)
  #expect(response.query == "未来 行動")
  #expect(response.results.count == document.chunkCount)
  #expect(response.results.count >= 2)
  #expect(response.results[0].rank == 1)
  #expect(response.results[0].chunk.text.contains("未来"))
  #expect(response.results[0].score >= response.results[1].score)
  #expect(response.results[0].diagnostics.rawKeywordScore > 0)
}

@Test func knowledgeSearchReturnsRankedCitationMatches() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "phase8.md",
      content: "Phase 8 の合言葉は真珠色のおにぎりです。\n検索結果の詳細を表示します。"
    ))

  let response = try await harness.searchKnowledge(query: "真珠色のおにぎり")

  #expect(response.matches.count == 1)
  #expect(response.matches[0].title == "phase8.md")
  #expect(response.matches[0].citationIndex == 1)
  #expect(response.matches[0].text.contains("真珠色"))
}

@Test func selectedChunksAreTheOnlyReferenceMaterialForOneAnswer() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["回答"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "red.md", content: "赤い資料の固有情報です。"))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "blue.md", content: "青い資料の固有情報です。"))
  let redID = try #require(await harness.searchKnowledge(query: "赤い資料").matches.first?.id)
  let conversationID = UUID()

  try await harness.streamResponse(to: "青い資料について", conversationID: conversationID) { _ in }

  try await harness.streamResponse(
    to: "資料を説明して", conversationID: conversationID, selectedChunkIDs: [redID]
  ) { _ in }
  #expect(recorder.sessionCount == 2)
  #expect(recorder.messages[1].contains("赤い資料の固有情報"))
  #expect(!recorder.messages[1].contains("青い資料の固有情報"))
  #expect(recorder.messages[1].contains("[1]"))

  _ = try await harness.clearKnowledge()
  await #expect(throws: HarnessError.self) {
    try await harness.streamResponse(
      to: "もう一度説明して", conversationID: UUID(), selectedChunkIDs: [redID]
    ) { _ in }
  }
}

@Test func selectedChunksRejectDuplicatesAndExcessiveSelections() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "one.md", content: "一つ目の資料です。"))
  let id = try #require(await harness.searchKnowledge(query: "一つ目").matches.first?.id)
  await #expect(throws: HarnessError.self) {
    try await harness.streamResponse(
      to: "教えて", conversationID: UUID(), selectedChunkIDs: [id, id]
    ) { _ in }
  }
}

@Test func ragEvaluationMeasuresExpectedRanksCitationsAndTiming() async throws {
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["合言葉は琥珀色のおにぎりです [1]"]))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "target.md", content: "評価対象の合言葉は琥珀色のおにぎりです。"))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "other.md", content: "別の資料には青空の話があります。"))
  let expectedID = try #require(
    await harness.searchKnowledge(query: "琥珀色のおにぎり").matches.first?.id)

  let result = try await harness.evaluateRAG(
    RAGEvaluationRequest(
      question: "琥珀色のおにぎりの合言葉を教えて",
      expectedChunkIDs: [expectedID],
      searchSettings: KnowledgeSearchSettings(
        limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0),
      expectedAnswerPoints: ["琥珀色のおにぎり"],
      forbiddenAnswerPhrases: ["青空"]))

  #expect(result.providerID == "test-provider")
  #expect(result.answer == "合言葉は琥珀色のおにぎりです [1]")
  #expect(result.expectedRanks == [RAGEvaluationExpectedRank(chunkID: expectedID, rank: 1)])
  #expect(result.retrievalRecall == 1)
  #expect(result.citationPrecision == 1)
  #expect(result.citationRecall == 1)
  #expect(result.answerPointCoverage == 1)
  #expect(result.groundedAnswerPointCoverage == 1)
  #expect(result.expectedAnswerPointResults == [
    RAGEvaluationAnswerPointResult(
      point: "琥珀色のおにぎり", foundInAnswer: true, supportedByExpectedChunks: true)
  ])
  #expect(result.forbiddenPhraseHits.isEmpty)
  #expect(result.retrievalMilliseconds >= 0)
  #expect(result.generationMilliseconds >= 0)
  #expect(result.totalMilliseconds >= 0)
}

@Test func ragManagerExposesModelIndependentKnowledgeTools() async throws {
  #expect(RAGToolCatalog.descriptors.map(\.name) == [.searchKnowledge, .getKnowledgeChunk])

  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "tool.md", content: "道具用の合言葉は緑のおにぎりです。"))

  let search = try await harness.searchKnowledgeTool(
    SearchKnowledgeToolRequest(
      query: "緑のおにぎり",
      settings: KnowledgeSearchSettings(
        limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0)))
  let match = try #require(search.matches.first)
  let fetched = await harness.getKnowledgeChunkTool(
    GetKnowledgeChunkToolRequest(chunkID: match.id))

  #expect(fetched.chunk?.id == match.id)
  #expect(fetched.chunk?.text == match.text)
  #expect(
    await harness.getKnowledgeChunkTool(GetKnowledgeChunkToolRequest(chunkID: "missing")).chunk
      == nil)
}

@Test func disabledRAGModeSkipsRetrievalAndIsRecorded() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["通常回答"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "secret.md", content: "秘密の合言葉は紫のおにぎりです。"))
  let expectedID = try #require(
    await harness.searchKnowledge(query: "紫のおにぎり").matches.first?.id)

  let result = try await harness.evaluateRAG(
    RAGEvaluationRequest(
      question: "秘密の合言葉は？", expectedChunkIDs: [expectedID], ragMode: .disabled))

  #expect(result.ragMode == .disabled)
  #expect(result.matches.isEmpty)
  #expect(recorder.messages == ["秘密の合言葉は？"])
  #expect(recorder.messages[0].contains("Reference material") == false)
}

@Test func agenticRAGSkipsSearchWhenPlannerSaysKnowledgeIsUnneeded() async throws {
  let recorder = TestRecorder()
  let traceRecorder = AgenticTraceRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: #"{"search":false,"query":null,"retryQuery":null,"reason":"一般的な挨拶"}"#,
    answer: "こんにちは", recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "secret.md", content: "秘密の資料です。"))

  try await harness.streamResponse(
    to: "こんにちは", conversationID: UUID(), runtime: ChatRuntimeOptions(ragMode: .agentic),
    onRAGTrace: { traceRecorder.trace = $0 }
  ) { _ in }

  #expect(traceRecorder.trace?.decision == .skipped)
  #expect(traceRecorder.trace?.toolCallCount == 0)
  #expect(recorder.messages.last == "こんにちは")
  #expect(recorder.messages.last?.contains("Reference material") == false)
}

@Test func agenticRAGRetriesWeakSearchAndRecordsRetrievedChunks() async throws {
  let recorder = TestRecorder()
  let traceRecorder = AgenticTraceRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: #"{"search":true,"query":"zzzz-no-match","retryQuery":"琥珀色のおにぎり","reason":"資料の合言葉を確認する"}"#,
    answer: "琥珀色です [1]", recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "target.md", content: "資料の合言葉は琥珀色のおにぎりです。"))

  try await harness.streamResponse(
    to: "資料の合言葉は？", conversationID: UUID(),
    runtime: ChatRuntimeOptions(
      ragMode: .agentic,
      searchSettings: KnowledgeSearchSettings(
        limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0)),
    onRAGTrace: { traceRecorder.trace = $0 }
  ) { _ in }

  #expect(traceRecorder.trace?.decision == .search)
  #expect(traceRecorder.trace?.queries == ["zzzz-no-match", "琥珀色のおにぎり"])
  #expect(traceRecorder.trace?.toolCallCount == 2)
  #expect(traceRecorder.trace?.matches.first?.title == "target.md")
  #expect(recorder.messages.last?.contains("Reference material") == true)
  #expect(recorder.messages.last?.contains("琥珀色のおにぎり") == true)
}

@Test func agenticRetryCannotEvictTheTopPrimaryMatch() async throws {
  let recorder = TestRecorder()
  let traceRecorder = AgenticTraceRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: #"{"search":true,"query":"Project Aurora 水野葵","retryQuery":"開始日 責任者 記録","reason":"資料を確認する"}"#,
    answer: "2027年3月18日です [1]", recorder: recorder))
  _ = try await harness.addKnowledgeDocument(KnowledgeDocumentRequest(
    title: "aurora.md", content: "Project Auroraは2027年3月18日公開です。責任者は水野葵です。"))
  for index in 1...6 {
    _ = try await harness.addKnowledgeDocument(KnowledgeDocumentRequest(
      title: "generic-\(index).md",
      content: "開始日、責任者、記録、確認、手順についての一般的な説明です。"))
  }

  try await harness.streamResponse(
    to: "オーロラ計画の公開日と責任者は？", conversationID: UUID(),
    runtime: ChatRuntimeOptions(
      ragMode: .agentic,
      searchSettings: KnowledgeSearchSettings(
        limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0)),
    onRAGTrace: { traceRecorder.trace = $0 }
  ) { _ in }

  #expect(traceRecorder.trace?.toolCallCount == 2)
  #expect(traceRecorder.trace?.matches.contains { $0.title == "aurora.md" } == true)
  #expect(traceRecorder.trace?.matches.first?.title == "aurora.md")
}

@Test func agenticRAGFallsBackToAlwaysWhenPlannerOutputIsInvalid() async throws {
  let recorder = TestRecorder()
  let traceRecorder = AgenticTraceRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: "JSONではない回答", answer: "回答 [1]", recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "fallback.md", content: "流星の合言葉は銀河です。"))

  try await harness.streamResponse(
    to: "流星の合言葉は？", conversationID: UUID(),
    runtime: ChatRuntimeOptions(
      ragMode: .agentic,
      searchSettings: KnowledgeSearchSettings(
        limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0)),
    onRAGTrace: { traceRecorder.trace = $0 }
  ) { _ in }

  #expect(traceRecorder.trace?.usedFallback == true)
  #expect(traceRecorder.trace?.queries == ["流星の合言葉は？"])
  #expect(traceRecorder.trace?.matches.first?.title == "fallback.md")
}

@Test func agenticEvaluationMeasuresSearchDecisionAndRetryRecovery() async throws {
  let recorder = TestRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: #"{"search":true,"query":"zzzz-no-match","retryQuery":"黄金の合言葉","reason":"資料を確認する"}"#,
    answer: "合言葉は黄金です [1]", recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "evaluation.md", content: "評価用の合言葉は黄金です。"))
  let expectedID = try #require(
    await harness.searchKnowledge(query: "黄金の合言葉").matches.first?.id)

  let result = try await harness.evaluateRAG(RAGEvaluationRequest(
    question: "評価用の合言葉は？", expectedChunkIDs: [expectedID],
    ragMode: .agentic, expectedSearch: true,
    searchSettings: KnowledgeSearchSettings(
      limit: 3, minScore: 1, keywordWeight: 1, embeddingWeight: 0)))

  #expect(result.expectedSearch)
  #expect(result.didSearch)
  #expect(result.searchDecisionCorrect)
  #expect(result.agenticTrace?.queries == ["zzzz-no-match", "黄金の合言葉"])
  #expect(result.diagnostics.contains { $0.code == .retryRecovered })
  #expect(result.retrievalRecall == 1)
}

@Test func agenticEvaluationSupportsSearchUnneededCases() async throws {
  let recorder = TestRecorder()
  let harness = Harness(provider: AgenticTestProvider(
    plan: #"{"search":false,"query":null,"retryQuery":null,"reason":"挨拶"}"#,
    answer: "こんにちは", recorder: recorder))

  let result = try await harness.evaluateRAG(RAGEvaluationRequest(
    question: "こんにちは", expectedChunkIDs: [], ragMode: .agentic,
    expectedSearch: false))

  #expect(!result.expectedSearch)
  #expect(!result.didSearch)
  #expect(result.searchDecisionCorrect)
  #expect(result.retrievalRecall == 1)
  #expect(result.citationPrecision == 1)
  #expect(result.citationRecall == 1)
  #expect(result.passes(.default))
}

@Test func ragEvaluationDiagnosesSearchMissAndAggregatesDecisionMetrics() async throws {
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["資料なしで回答しました。"]))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "miss.md", content: "診断対象の答えは青です。"))
  let expectedID = try #require(await harness.searchKnowledge(query: "診断対象").matches.first?.id)
  let missed = try await harness.evaluateRAG(RAGEvaluationRequest(
    question: "診断対象の答えは？", expectedChunkIDs: [expectedID],
    ragMode: .disabled, expectedSearch: true))
  #expect(!missed.searchDecisionCorrect)
  #expect(missed.diagnostics.contains { $0.code == .searchMiss })
  #expect(!missed.passes(.default))

  let unnecessary = RAGEvaluationResponse(
    providerID: "test", providerName: "Test", modelID: nil, ragMode: .always,
    expectedSearch: false, searchDecisionCorrect: false,
    answer: "回答", matches: [], expectedRanks: [], retrievalRecall: 1,
    citationPrecision: 1, citationRecall: 1,
    retrievalMilliseconds: 1, generationMilliseconds: 1, totalMilliseconds: 2)
  let report = RAGEvaluationReport(createdAt: Date(), entries: [
    RAGEvaluationReportEntry(
      profileName: "Disabled", caseID: UUID(), question: "必要",
      searchSettings: .init(), criteria: .default, result: missed),
    RAGEvaluationReportEntry(
      profileName: "Always", caseID: UUID(), question: "不要",
      searchSettings: .init(), criteria: .default, result: unnecessary),
  ])
  #expect(report.searchDecisionPrecision == 0)
  #expect(report.searchDecisionRecall == 0)
  #expect(report.unnecessarySearchCount == 1)
  #expect(report.missedSearchCount == 1)
}

@Test func legacyRAGEvaluationResponseDefaultsToAlwaysMode() throws {
  let data = Data("""
    {
      "providerID":"test","providerName":"Test","answer":"ok","matches":[],
      "expectedRanks":[],"retrievalRecall":1,"citationPrecision":1,"citationRecall":1,
      "retrievalMilliseconds":1,"generationMilliseconds":2,"totalMilliseconds":3
    }
    """.utf8)

  let result = try JSONDecoder().decode(RAGEvaluationResponse.self, from: data)
  #expect(result.ragMode == .always)
}

@Test func ragEvaluationAppliesSavedPassCriteria() {
  let result = RAGEvaluationResponse(
    providerID: "test-provider", providerName: "Test", modelID: "test-model",
    answer: "回答 [1]", matches: [], expectedRanks: [],
    retrievalRecall: 0.8, citationPrecision: 1, citationRecall: 0.75,
    retrievalMilliseconds: 100, generationMilliseconds: 900, totalMilliseconds: 1_000)

  #expect(result.passes(RAGEvaluationCriteria(
    minimumRetrievalRecall: 0.8, minimumCitationPrecision: 1,
    minimumCitationRecall: 0.75, maximumTotalMilliseconds: 1_000)))
  #expect(!result.passes(RAGEvaluationCriteria(
    minimumRetrievalRecall: 0.9, minimumCitationPrecision: 1,
    minimumCitationRecall: 0.75, maximumTotalMilliseconds: 1_000)))
  #expect(!result.passes(RAGEvaluationCriteria(
    minimumRetrievalRecall: 0.8, minimumCitationPrecision: 1,
    minimumCitationRecall: 0.75, maximumTotalMilliseconds: 999)))

  let unsafeResult = RAGEvaluationResponse(
    providerID: "test-provider", providerName: "Test", modelID: "test-model",
    answer: "根拠のない内容", matches: [], expectedRanks: [],
    retrievalRecall: 1, citationPrecision: 1, citationRecall: 1,
    answerPointCoverage: 1, groundedAnswerPointCoverage: 0,
    forbiddenPhraseHits: ["根拠のない内容"],
    retrievalMilliseconds: 10, generationMilliseconds: 10, totalMilliseconds: 20)
  #expect(!unsafeResult.passes(.default))
}

@Test func knowledgeSearchBoostsTitleMatches() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "月光おにぎり.md",
      content: "この資料は短い概要だけを含みます。"
    ))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "general.md",
      content: "月光のおにぎりについての一般的な説明です。"
    ))

  let response = try await harness.searchKnowledge(query: "月光おにぎり")

  #expect(response.matches.count == 2)
  #expect(response.matches[0].title == "月光おにぎり.md")
  #expect(response.matches[0].score > response.matches[1].score)
}

@Test func knowledgeChunksKeepOverlapAcrossBoundaries() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))
  let first = String(repeating: "境界前の説明です。", count: 90)
  let second = "境界後の結論は瑠璃色のおにぎりです。"
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "overlap.md",
      content: "\(first)\n\(second)"
    ))

  let response = try await harness.searchKnowledge(query: "境界前 瑠璃色")

  #expect(response.matches.count >= 1)
  #expect(response.matches[0].text.contains("境界前"))
  #expect(response.matches[0].text.contains("瑠璃色"))
}

@Test func knowledgeSearchUsesEmbeddingsWhenKeywordsDoNotMatch() async throws {
  let provider = TestProvider(available: true, snapshots: []) { text in
    if text.contains("自動車") || text.contains("車") { return [1, 0] }
    if text.contains("バナナ") { return [0, 1] }
    return [0, 0]
  }
  let harness = Harness(provider: provider)
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "vehicle.md",
      content: "自動車の整備記録です。"
    ))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "fruit.md",
      content: "バナナの保存方法です。"
    ))

  let response = try await harness.searchKnowledge(query: "車")

  #expect(response.matches.count >= 1)
  #expect(response.matches[0].title == "vehicle.md")
  #expect(response.matches[0].searchMode == "embedding")
}

@Test func knowledgeSearchSettingsTuneLimitThresholdAndWeights() async throws {
  let provider = TestProvider(available: true, snapshots: []) { text in
    if text.contains("自動車") || text.contains("車") { return [1, 0] }
    if text.contains("バナナ") { return [0, 1] }
    return [0, 0]
  }
  let harness = Harness(provider: provider)
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "vehicle.md", content: "自動車の整備記録です。")
  )
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "fruit.md", content: "バナナの保存方法です。")
  )

  let limited = try await harness.searchKnowledge(
    query: "車",
    settings: KnowledgeSearchSettings(limit: 1, minScore: 1, keywordWeight: 1, embeddingWeight: 1)
  )
  #expect(limited.matches.count == 1)

  let thresholded = try await harness.searchKnowledge(
    query: "車",
    settings: KnowledgeSearchSettings(
      limit: 5, minScore: 60, keywordWeight: 1, embeddingWeight: 0.5)
  )
  #expect(thresholded.matches.isEmpty)

  let disabledEmbeddings = try await harness.searchKnowledge(
    query: "車",
    settings: KnowledgeSearchSettings(limit: 5, minScore: 1, keywordWeight: 1, embeddingWeight: 0)
  )
  #expect(disabledEmbeddings.matches.isEmpty)
}

@Test func knowledgeEmbeddingsCanBeRefreshedAndPersisted() async throws {
  let storeURL = URL(fileURLWithPath: NSTemporaryDirectory())
    .appending(path: "onigiri-embeddings-\(UUID().uuidString).json")
  defer { try? FileManager.default.removeItem(at: storeURL) }

  let provider = TestProvider(available: true, snapshots: []) { text in
    text.contains("資料") ? [1, 0] : [0, 1]
  }
  let harness = Harness(provider: provider, knowledgeStoreURL: storeURL)
  let added = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "embeddings.md", content: "Embedding 更新を確認する資料です。")
  )

  #expect(added.embeddedChunkCount == 0)
  let refreshed = try await harness.refreshKnowledgeEmbeddings()
  #expect(refreshed.chunkCount == 1)
  #expect(refreshed.embeddedChunkCount == 1)

  let reloaded = Harness(provider: provider, knowledgeStoreURL: storeURL)
  #expect(await reloaded.knowledgeStatus().embeddedChunkCount == 1)
  #expect(await reloaded.knowledgeDocuments().documents[0].embeddedChunkCount == 1)
}

@Test func knowledgeSearchRejectsEmptyQuery() async throws {
  let harness = Harness(provider: TestProvider(available: true, snapshots: []))

  await #expect(throws: HarnessError.self) {
    _ = try await harness.searchKnowledge(query: "  ")
  }
}

@Test func shortRewriteRequestTargetsPreviousAssistantAnswer() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  let conversationID = UUID()
  let history = [
    ChatHistoryMessage(role: .user, content: "未来を実現するためのステップを順番に教えて"),
    ChatHistoryMessage(
      role: .assistant,
      content: "まず夢を書きます。次に未来から逆算します。最後に今日の行動を決めます。"),
  ]

  try await harness.streamResponse(
    to: "箇条書きでお願いします", conversationID: conversationID, history: history
  ) { _ in }

  #expect(recorder.messages.count == 1)
  #expect(recorder.messages[0].contains("Source answer"))
  #expect(recorder.messages[0].contains("Transform only the source answer"))
  #expect(recorder.messages[0].contains("translate every part faithfully"))
  #expect(recorder.messages[0].contains("まず夢を書きます"))
  #expect(recorder.messages[0].contains("箇条書きでお願いします"))
}

@Test func englishTranslationRequestTargetsPreviousAssistantAnswer() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  let history = [
    ChatHistoryMessage(role: .user, content: "What day is it?"),
    ChatHistoryMessage(role: .assistant, content: "It is Wednesday."),
    ChatHistoryMessage(role: .user, content: "合言葉は？"),
    ChatHistoryMessage(
      role: .assistant,
      content: "合言葉は青い土曜日です。"),
  ]

  try await harness.streamResponse(to: "英訳して", conversationID: UUID(), history: history) { _ in }

  #expect(recorder.messages.count == 1)
  #expect(recorder.messages[0].contains("Source answer"))
  #expect(recorder.messages[0].contains("translate every part faithfully"))
  #expect(recorder.messages[0].contains("合言葉は青い土曜日です"))
  #expect(recorder.messages[0].contains("It is Wednesday") == false)
  #expect(recorder.messages[0].contains("英訳して"))
}

@Test func compatibilityFollowUpTransformDoesNotExposeUnrelatedCitations() async throws {
  let recorder = TestRecorder()
  let contextRecorder = CompatibilityContextRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["- First\n- Second"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(KnowledgeDocumentRequest(
    title: "unrelated.md", content: "箇条書きという語を含む無関係な資料です。"))
  let history = [
    ChatHistoryMessage(role: .user, content: "手順を教えて"),
    ChatHistoryMessage(role: .assistant, content: "最初に確認し、次に実行します。"),
  ]

  try await harness.streamCompatibilityResponse(
    to: "箇条書きでお願いします", conversationID: UUID(), history: history,
    runtime: ChatRuntimeOptions(ragMode: .always),
    onContext: { contextRecorder.context = $0 }
  ) { _ in }

  #expect(contextRecorder.context?.matches.isEmpty == true)
  #expect(recorder.messages.last?.contains("Source answer") == true)
  #expect(recorder.messages.last?.contains("Reference material") == false)
}

@Test func knowledgeContextIsInjectedIntoProviderMessage() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "secret.txt",
      content: "銀色のおにぎりは Phase 6 のテスト用合言葉です。"
    ))

  try await harness.streamResponse(to: "銀色のおにぎりについて教えて", conversationID: UUID()) { _ in }

  #expect(recorder.messages.count == 1)
  #expect(recorder.messages[0].contains("Answer in the same language"))
  #expect(recorder.messages[0].contains("Reference material"))
  #expect(recorder.messages[0].contains("secret.txt"))
  #expect(recorder.messages[0].contains("銀色のおにぎり"))
}

@Test func knowledgeContextKeepsEnglishQuestionLanguage() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(
      title: "identity.md",
      content: "Foundation Model is the local assistant name used in this document."
    ))

  try await harness.streamResponse(to: "What is your name?", conversationID: UUID()) { _ in }

  #expect(recorder.messages.count == 1)
  #expect(recorder.messages[0].contains("Answer in the same language as the user's latest message"))
  #expect(recorder.messages[0].contains("User's latest message:"))
  #expect(recorder.messages[0].contains("What is your name?"))
}

@Test func chatRuntimeAppliesProfileInstructionsAndContextLimit() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  let runtime = ChatRuntimeOptions(
    systemInstructions: "Always answer as a cooking assistant.", ragMode: .disabled,
    contextLimit: 8_500)

  try await harness.streamResponse(
    to: "Hello", conversationID: UUID(), runtime: runtime
  ) { _ in }

  #expect(recorder.instructions == [runtime.effectiveSystemInstructions])
  #expect(recorder.contextLimits == [8_500])
}

@Test func disabledRAGDoesNotInjectKnowledge() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  _ = try await harness.addKnowledgeDocument(
    KnowledgeDocumentRequest(title: "secret.md", content: "秘密の合言葉は青い月です。"))

  try await harness.streamResponse(
    to: "秘密の合言葉は？", conversationID: UUID(),
    runtime: ChatRuntimeOptions(ragMode: .disabled)
  ) { _ in }

  #expect(recorder.messages == ["秘密の合言葉は？"])
  #expect(recorder.messages[0].contains("Reference material") == false)
}

@Test func changingChatRuntimeRecreatesConversationSession() async throws {
  let recorder = TestRecorder()
  let harness = Harness(
    provider: TestProvider(available: true, snapshots: ["ok"], recorder: recorder))
  let conversationID = UUID()

  try await harness.streamResponse(
    to: "first", conversationID: conversationID,
    runtime: ChatRuntimeOptions(systemInstructions: "Profile A")
  ) { _ in }
  try await harness.streamResponse(
    to: "second", conversationID: conversationID,
    runtime: ChatRuntimeOptions(systemInstructions: "Profile B")
  ) { _ in }

  #expect(recorder.sessionCount == 2)
  #expect(
    recorder.instructions
      == [
        ChatRuntimeOptions(systemInstructions: "Profile A").effectiveSystemInstructions,
        ChatRuntimeOptions(systemInstructions: "Profile B").effectiveSystemInstructions,
      ])
}

@Test func evaluationReportSummarizesAndFiltersMarkdown() throws {
  func result(citationPrecision: Double, milliseconds: Int) -> RAGEvaluationResponse {
    RAGEvaluationResponse(
      providerID: "test", providerName: "Test", modelID: "model-a", answer: "回答です。",
      matches: [], expectedRanks: [], retrievalRecall: 1,
      citationPrecision: citationPrecision, citationRecall: 1,
      retrievalMilliseconds: 10, generationMilliseconds: milliseconds - 10,
      totalMilliseconds: milliseconds)
  }
  let caseID = UUID()
  let report = RAGEvaluationReport(
    createdAt: Date(timeIntervalSince1970: 1_000),
    entries: [
      RAGEvaluationReportEntry(
        profileName: "Model A", caseID: caseID, question: "合格ケース",
        searchSettings: .init(), criteria: .default,
        result: result(citationPrecision: 1, milliseconds: 1_000)),
      RAGEvaluationReportEntry(
        profileName: "Model A", caseID: caseID, question: "不合格ケース",
        searchSettings: .init(), criteria: .default,
        result: result(citationPrecision: 0.5, milliseconds: 2_000)),
    ])

  #expect(report.passedCount == 1)
  #expect(report.failedCount == 1)
  #expect(report.passRate == 0.5)
  #expect(report.averageTotalMilliseconds == 1_500)
  let markdown = report.markdown(failedOnly: true)
  #expect(markdown.contains("不合格ケース"))
  #expect(markdown.contains("引用精度 / 再現率: 50% / 100%"))
  #expect(!markdown.contains("## ✅ 合格ケース"))

  let previous = RAGEvaluationReport(
    createdAt: Date(timeIntervalSince1970: 900),
    completedAt: Date(timeIntervalSince1970: 950),
    entries: [
      RAGEvaluationReportEntry(
        profileName: "Model A", caseID: caseID, question: "不合格ケース",
        searchSettings: .init(), criteria: .default,
        result: result(citationPrecision: 1, milliseconds: 1_000))
    ])
  let regressions = report.regressions(comparedTo: previous)
  #expect(regressions.count == 1)
  #expect(regressions[0].detail.contains("合格から不合格"))
  #expect(regressions[0].detail.contains("合計時間 +1000ms"))
}

@Test func evaluationReportDecodesPhase32FilesAsManualRuns() throws {
  let json = """
    {
      "id":"11111111-1111-1111-1111-111111111111",
      "createdAt":100,
      "completedAt":200,
      "entries":[]
    }
    """
  let report = try JSONDecoder().decode(RAGEvaluationReport.self, from: Data(json.utf8))
  #expect(report.trigger == .manual)
  #expect(report.suiteName == nil)
  #expect(report.knowledgeSnapshot == nil)
}

@Test func evaluationKnowledgeSnapshotTracksDocumentAndChunkChanges() throws {
  let firstID = UUID()
  let secondID = UUID()
  let before = RAGEvaluationKnowledgeSnapshot(
    status: KnowledgeStatus(documentCount: 1, chunkCount: 2, embeddedChunkCount: 1),
    chunkingSettings: KnowledgeChunkingSettings(maxCharacters: 1_200, overlapCharacters: 260),
    documents: [
      KnowledgeDocumentSummary(
        id: firstID, title: "guide.md", chunkCount: 2, embeddedChunkCount: 1, preview: "")
    ])
  let after = RAGEvaluationKnowledgeSnapshot(
    status: KnowledgeStatus(documentCount: 2, chunkCount: 4, embeddedChunkCount: 4),
    chunkingSettings: KnowledgeChunkingSettings(maxCharacters: 900, overlapCharacters: 180),
    documents: [
      KnowledgeDocumentSummary(
        id: firstID, title: "guide.md", chunkCount: 3, embeddedChunkCount: 3, preview: ""),
      KnowledgeDocumentSummary(
        id: secondID, title: "faq.md", chunkCount: 1, embeddedChunkCount: 1, preview: ""),
    ])

  #expect(before.versionID != after.versionID)
  let changes = after.differences(comparedTo: before)
  #expect(changes.contains(where: { $0.contains("分割設定") }))
  #expect(changes.contains(where: { $0.contains("追加: faq.md") }))
  #expect(changes.contains(where: { $0.contains("guide.md: 2 → 3チャンク") }))
}

@Test func evaluationCoverageFindsGapsGroupsRetrievalAndDuplicates() {
  let firstDocumentID = UUID()
  let secondDocumentID = UUID()
  let suiteID = UUID()
  let firstCaseID = UUID()
  let secondCaseID = UUID()
  let report = RAGEvaluationCoverageAnalyzer.analyze(
    documents: [
      RAGEvaluationCoverageDocument(
        id: firstDocumentID, title: "guide.md",
        chunkIDs: ["guide-0", "guide-1"]),
      RAGEvaluationCoverageDocument(
        id: secondDocumentID, title: "faq.md", chunkIDs: ["faq-0"]),
    ],
    cases: [
      RAGEvaluationCoverageCase(
        id: firstCaseID, question: "おにぎりの作り方を教えてください",
        expectedChunkIDs: ["guide-0"], retrievedChunkIDs: ["guide-0", "faq-0"],
        tags: ["基本"], suiteIDs: [suiteID]),
      RAGEvaluationCoverageCase(
        id: secondCaseID, question: "おにぎりの作り方を教えてください。",
        expectedChunkIDs: ["guide-0"], tags: ["基本"], suiteIDs: [suiteID]),
    ],
    suiteNames: [suiteID: "基本スイート"])

  #expect(report.documentCoverage == 0.5)
  #expect(report.expectedChunkCoverage == 1.0 / 3.0)
  #expect(report.retrievalCoverage == 2.0 / 3.0)
  #expect(report.uncoveredDocuments.map(\.title) == ["faq.md"])
  #expect(report.neverRetrievedChunkIDs == ["guide-1"])
  #expect(report.tagGroups == [
    RAGEvaluationCoverageGroup(name: "基本", caseCount: 2, documentCount: 1)
  ])
  #expect(report.suiteGroups == [
    RAGEvaluationCoverageGroup(name: "基本スイート", caseCount: 2, documentCount: 1)
  ])
  #expect(report.duplicateCases.count == 1)
  #expect(report.duplicateCases[0].firstCaseID == firstCaseID)
}
