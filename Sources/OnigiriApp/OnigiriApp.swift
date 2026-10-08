import AppKit
import Charts
import OnigiriCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import WebKit

private enum OnigiriEndpoint {
  static let port = 18080
  static let baseURL = URL(string: "http://127.0.0.1:\(port)")!

  static func url(_ path: String) -> URL {
    baseURL.appending(path: path)
  }
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Notification.Name {
  static let ensureOnigiriServer = Notification.Name("OnigiriHarness.ensureServer")
}

private enum AppLanguage: String, CaseIterable, Identifiable {
  case japanese = "ja"
  case english = "en"

  var id: String { rawValue }
  var locale: Locale { Locale(identifier: rawValue) }
  var displayName: String {
    switch self {
    case .japanese: return "日本語"
    case .english: return "English"
    }
  }
}

@main
struct OnigiriApp: App {
  @NSApplicationDelegateAdaptor(BundledServerLauncher.self) private var serverLauncher
  @AppStorage("onigiri.uiLanguage") private var languageCode = AppLanguage.japanese.rawValue

  private var language: AppLanguage { AppLanguage(rawValue: languageCode) ?? .japanese }

  var body: some Scene {
    WindowGroup("Onigiri Harness") {
      ChatView()
        .environment(\.locale, language.locale)
    }
      .defaultSize(width: 980, height: 640)

    Settings {
      LanguageSettingsView()
        .environment(\.locale, language.locale)
    }
  }
}

private struct LanguageSettingsView: View {
  @AppStorage("onigiri.uiLanguage") private var languageCode = AppLanguage.japanese.rawValue

  var body: some View {
    Form {
      Picker("表示言語", selection: $languageCode) {
        ForEach(AppLanguage.allCases) { language in
          Text(language.displayName).tag(language.rawValue)
        }
      }
      Text("言語の変更はすべてのOnigiriウインドウへすぐに反映されます。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
    .frame(width: 420)
    .padding(12)
  }
}

final class BundledServerLauncher: NSObject, NSApplicationDelegate {
  private var process: Process?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NotificationCenter.default.addObserver(
      self, selector: #selector(ensureServerIsRunning), name: .ensureOnigiriServer, object: nil)
    ensureServerIsRunning()
  }

  @objc private func ensureServerIsRunning() {
    if process?.isRunning == true { return }
    let executableURL = Bundle.main.bundleURL
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "MacOS", directoryHint: .isDirectory)
      .appending(path: "OnigiriServer")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { return }

    let server = Process()
    server.executableURL = executableURL
    server.currentDirectoryURL = executableURL.deletingLastPathComponent()
    var environment = ProcessInfo.processInfo.environment
    environment["ONIGIRI_SERVER_PORT"] = "\(OnigiriEndpoint.port)"
    server.environment = environment
    server.terminationHandler = { [weak self, weak server] _ in
      DispatchQueue.main.async {
        guard let self, let server, self.process === server else { return }
        self.process = nil
      }
    }
    do {
      try server.run()
      process = server
    } catch {
      fputs("OnigiriServer launch failed: \(error.localizedDescription)\n", stderr)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    NotificationCenter.default.removeObserver(self)
    process?.terminate()
  }
}

private struct DisplayMessage: Identifiable, Equatable, Codable {
  enum Role: String, Codable { case user, assistant }
  let id: UUID
  let role: Role
  var content: String
  var citations: [KnowledgeChunkMatch]
  var webSources: [WebResearchCitation]?
  var ragMode: RAGMode?
  var ragTrace: AgenticRAGTrace?

  init(
    id: UUID = UUID(), role: Role, content: String, citations: [KnowledgeChunkMatch] = [],
    webSources: [WebResearchCitation] = [],
    ragMode: RAGMode? = nil, ragTrace: AgenticRAGTrace? = nil
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.citations = citations
    self.webSources = webSources.isEmpty ? nil : webSources
    self.ragMode = ragMode
    self.ragTrace = ragTrace
  }
}

private struct StoredConversation: Identifiable, Equatable, Codable {
  var id: UUID
  var title: String
  var updatedAt: Date
  var messages: [DisplayMessage]
  var profileID: UUID?
  var contextResetAfterMessageID: UUID?

  static var empty: StoredConversation {
    StoredConversation(
      id: UUID(), title: "新しい会話", updatedAt: Date(), messages: [], profileID: nil,
      contextResetAfterMessageID: nil)
  }
}

private struct ChatComposerTextView: NSViewRepresentable {
  @Binding var text: String
  let isEnabled: Bool
  let canSubmit: Bool
  let onSubmit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder

    let textView = IMEAwareTextView()
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.font = .preferredFont(forTextStyle: .body)
    textView.textContainerInset = NSSize(width: 6, height: 7)
    textView.string = text
    textView.onPlainReturn = { [weak coordinator = context.coordinator] in
      coordinator?.submitIfPossible()
    }
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    context.coordinator.parent = self
    guard let textView = scrollView.documentView as? IMEAwareTextView else { return }
    textView.isEditable = isEnabled
    textView.isSelectable = true
    if !textView.hasMarkedText(), textView.string != text {
      textView.string = text
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ChatComposerTextView

    init(parent: ChatComposerTextView) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      parent.text = textView.string
    }

    func submitIfPossible() {
      guard parent.isEnabled, parent.canSubmit else { return }
      parent.onSubmit()
    }
  }
}

private final class IMEAwareTextView: NSTextView {
  var onPlainReturn: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    guard isReturn else {
      super.keyDown(with: event)
      return
    }
    let action = ChatComposerInputPolicy.returnAction(
      hasMarkedText: hasMarkedText(), shiftPressed: event.modifierFlags.contains(.shift))
    if action != .submit {
      super.keyDown(with: event)
      return
    }
    onPlainReturn?()
  }
}

private struct ProductProfile: Identifiable, Equatable, Codable {
  let id: UUID
  var name: String
  var providerID: String
  var baseURL: String
  var modelID: String
  var systemInstructions: String
  var ragMode: RAGMode
  var searchSettings: KnowledgeSearchSettings
  var contextLimit: Int

  init(
    id: UUID = UUID(), name: String, providerID: String,
    baseURL: String = "", modelID: String = "",
    systemInstructions: String = ChatRuntimeOptions.defaultInstructions,
    ragMode: RAGMode = .always,
    searchSettings: KnowledgeSearchSettings = KnowledgeSearchSettings(),
    contextLimit: Int = 6_000
  ) {
    self.id = id
    self.name = name
    self.providerID = providerID
    self.baseURL = baseURL
    self.modelID = modelID
    self.systemInstructions = systemInstructions
    self.ragMode = ragMode
    self.searchSettings = searchSettings
    self.contextLimit = contextLimit
  }

  var runtime: ChatRuntimeOptions {
    ChatRuntimeOptions(
      systemInstructions: systemInstructions, ragMode: ragMode,
      searchSettings: searchSettings, contextLimit: contextLimit)
  }
}

private struct ProductProfileStore: Codable {
  let formatVersion: Int
  var defaultProfileID: UUID
  var profiles: [ProductProfile]
}

private extension RAGMode {
  var displayName: String {
    switch self {
    case .disabled: return "RAGなし"
    case .always: return "RAG常時"
    case .agentic: return "Agentic RAG"
    }
  }
}

private struct KnowledgeSearchFeedback: Identifiable, Equatable, Codable {
  enum Rating: String, Codable { case good, bad }

  let id: UUID
  let createdAt: Date
  let query: String
  let rating: Rating
  let settings: KnowledgeSearchSettings
  let match: KnowledgeChunkMatch

  init(query: String, rating: Rating, settings: KnowledgeSearchSettings, match: KnowledgeChunkMatch)
  {
    self.id = UUID()
    self.createdAt = Date()
    self.query = query
    self.rating = rating
    self.settings = settings
    self.match = match
  }
}

private struct KnowledgeSelectionHistory: Identifiable, Equatable, Codable {
  let id: UUID
  var createdAt: Date
  let query: String
  let matches: [KnowledgeChunkMatch]
  var isPinned: Bool

  init(
    id: UUID = UUID(), createdAt: Date = Date(), query: String,
    matches: [KnowledgeChunkMatch], isPinned: Bool = false
  ) {
    self.id = id
    self.createdAt = createdAt
    self.query = query
    self.matches = matches
    self.isPinned = isPinned
  }
}

private struct RAGEvaluationEnvironment: Equatable, Codable {
  let providerID: String
  let providerName: String
  let baseURL: String?
  let modelID: String?
  let ragMode: RAGMode
  let searchSettings: KnowledgeSearchSettings

  init(
    providerID: String, providerName: String, baseURL: String?, modelID: String?,
    ragMode: RAGMode = .always, searchSettings: KnowledgeSearchSettings
  ) {
    self.providerID = providerID
    self.providerName = providerName
    self.baseURL = baseURL
    self.modelID = modelID
    self.ragMode = ragMode
    self.searchSettings = searchSettings
  }

  private enum CodingKeys: String, CodingKey {
    case providerID, providerName, baseURL, modelID, ragMode, searchSettings
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    providerID = try container.decode(String.self, forKey: .providerID)
    providerName = try container.decode(String.self, forKey: .providerName)
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
    modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
    ragMode = try container.decodeIfPresent(RAGMode.self, forKey: .ragMode) ?? .always
    searchSettings = try container.decode(KnowledgeSearchSettings.self, forKey: .searchSettings)
  }
}

private struct RAGEvaluationRun: Identifiable, Equatable, Codable {
  let id: UUID
  let createdAt: Date
  let result: RAGEvaluationResponse
  let environment: RAGEvaluationEnvironment?

  init(
    id: UUID = UUID(), createdAt: Date = Date(), result: RAGEvaluationResponse,
    environment: RAGEvaluationEnvironment? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.result = result
    self.environment = environment
  }

  private enum CodingKeys: String, CodingKey { case id, createdAt, result, environment }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    result = try container.decode(RAGEvaluationResponse.self, forKey: .result)
    environment = try container.decodeIfPresent(RAGEvaluationEnvironment.self, forKey: .environment)
  }
}

private struct RAGEvaluationSuiteFile: Codable {
  let formatVersion: Int
  let exportedAt: Date
  let cases: [RAGEvaluationCase]
}

private struct RAGEvaluationImportSummary {
  let importedCount: Int
  let skippedCount: Int
}

private struct RAGEvaluationProfile: Identifiable, Equatable, Codable {
  let id: UUID
  var name: String
  var environment: RAGEvaluationEnvironment
  var isSelected: Bool

  init(
    id: UUID = UUID(), name: String, environment: RAGEvaluationEnvironment,
    isSelected: Bool = true
  ) {
    self.id = id
    self.name = name
    self.environment = environment
    self.isSelected = isSelected
  }
}

private struct RAGEvaluationAutomationSettings: Equatable, Codable {
  var isEnabled = false
  var scheduledHour = 9
  var scheduledMinute = 0
  var retentionDays = 30
  var notifyOnRegression = true
  var lastScheduledRunAt: Date?
}

private struct RAGEvaluationSuite: Identifiable, Equatable, Codable {
  let id: UUID
  var name: String
  var caseIDs: [UUID]

  init(id: UUID = UUID(), name: String, caseIDs: [UUID] = []) {
    self.id = id
    self.name = name
    self.caseIDs = caseIDs
  }
}

private struct RAGEvaluationGeneratedCandidate: Identifiable, Equatable {
  let question: String
  let expectedMatch: KnowledgeChunkMatch
  let expectedAnswerPoint: String
  var id: String { expectedMatch.id }
}

private struct RAGEvaluationCase: Identifiable, Equatable, Codable {
  let id: UUID
  let createdAt: Date
  var question: String
  let expectedMatches: [KnowledgeChunkMatch]
  var expectedSearch: Bool
  var runs: [RAGEvaluationRun]
  var criteria: RAGEvaluationCriteria
  var baselineRunID: UUID?
  var expectedAnswerPoints: [String]
  var forbiddenAnswerPhrases: [String]
  var tags: [String]

  init(
    id: UUID = UUID(), createdAt: Date = Date(), question: String,
    expectedMatches: [KnowledgeChunkMatch], expectedSearch: Bool? = nil,
    runs: [RAGEvaluationRun] = [],
    criteria: RAGEvaluationCriteria = .default, baselineRunID: UUID? = nil,
    expectedAnswerPoints: [String] = [], forbiddenAnswerPhrases: [String] = [],
    tags: [String] = []
  ) {
    self.id = id
    self.createdAt = createdAt
    self.question = question
    self.expectedMatches = expectedMatches
    self.expectedSearch = expectedSearch ?? !expectedMatches.isEmpty
    self.runs = runs
    self.criteria = criteria
    self.baselineRunID = baselineRunID
    self.expectedAnswerPoints = expectedAnswerPoints
    self.forbiddenAnswerPhrases = forbiddenAnswerPhrases
    self.tags = tags
  }

  private enum CodingKeys: String, CodingKey {
    case id, createdAt, question, expectedMatches, expectedSearch, runs, criteria, baselineRunID
    case expectedAnswerPoints, forbiddenAnswerPhrases
    case tags
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    question = try container.decode(String.self, forKey: .question)
    expectedMatches = try container.decode([KnowledgeChunkMatch].self, forKey: .expectedMatches)
    expectedSearch =
      try container.decodeIfPresent(Bool.self, forKey: .expectedSearch)
      ?? !expectedMatches.isEmpty
    runs = try container.decode([RAGEvaluationRun].self, forKey: .runs)
    criteria = try container.decodeIfPresent(RAGEvaluationCriteria.self, forKey: .criteria) ?? .default
    baselineRunID = try container.decodeIfPresent(UUID.self, forKey: .baselineRunID)
    expectedAnswerPoints =
      try container.decodeIfPresent([String].self, forKey: .expectedAnswerPoints) ?? []
    forbiddenAnswerPhrases =
      try container.decodeIfPresent([String].self, forKey: .forbiddenAnswerPhrases) ?? []
    tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
  }
}

private struct SearchPreset: Identifiable, Equatable, Codable {
  let id: UUID
  var name: String
  var settings: KnowledgeSearchSettings
  var isBuiltIn: Bool

  init(
    id: UUID = UUID(), name: String, settings: KnowledgeSearchSettings, isBuiltIn: Bool = false
  ) {
    self.id = id
    self.name = name
    self.settings = settings
    self.isBuiltIn = isBuiltIn
  }

  static let builtIns: [SearchPreset] = [
    SearchPreset(
      name: "バランス",
      settings: KnowledgeSearchSettings(
        limit: 5, minScore: 1, keywordWeight: 1, embeddingWeight: 1),
      isBuiltIn: true),
    SearchPreset(
      name: "キーワード重視",
      settings: KnowledgeSearchSettings(
        limit: 5, minScore: 1, keywordWeight: 1.6, embeddingWeight: 0.6),
      isBuiltIn: true),
    SearchPreset(
      name: "Embedding重視",
      settings: KnowledgeSearchSettings(
        limit: 5, minScore: 1, keywordWeight: 0.6, embeddingWeight: 1.6),
      isBuiltIn: true),
    SearchPreset(
      name: "厳しめ",
      settings: KnowledgeSearchSettings(
        limit: 3, minScore: 40, keywordWeight: 1, embeddingWeight: 1),
      isBuiltIn: true),
  ]
}

private struct StreamError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private struct KnowledgeButtonsScrollVisibility: Equatable {
  var leading = false
  var trailing = false
}

private struct KnowledgeSearchPresentation: Identifiable {
  let id = UUID()
  let query: String
  let matches: [KnowledgeChunkMatch]
}

private struct KnowledgeImportFailure {
  let title: String
  let reason: String
}

private func copyToPasteboard(_ text: String) {
  NSPasteboard.general.clearContents()
  NSPasteboard.general.setString(text, forType: .string)
}

struct ChatView: View {
  @Environment(\.locale) private var locale
  @State private var conversations: [StoredConversation] = [.empty]
  @State private var selectedConversationID: UUID?
  @State private var draft = "こんにちは"
  @State private var status = "サーバーを確認しています…"
  @State private var providerName = "Model Provider"
  @State private var providerOptions: [ProviderOption] = []
  @State private var modelIDs: [String] = []
  @State private var productProfiles: [ProductProfile] = []
  @State private var defaultProductProfileID: UUID?
  @State private var selectedProductProfileID: UUID?
  @State private var systemInstructions = ChatRuntimeOptions.defaultInstructions
  @State private var selectedRAGMode = RAGMode.always
  @State private var contextLimit = 6_000
  @State private var showingProductProfiles = false
  @State private var errorMessage: String?
  @State private var knowledgeStatus = KnowledgeStatus(documentCount: 0, chunkCount: 0)
  @State private var knowledgeDocuments: [KnowledgeDocumentSummary] = []
  @State private var selectedKnowledgeChunks: KnowledgeChunksResponse?
  @State private var knowledgeSearchPresentation: KnowledgeSearchPresentation?
  @State private var queuedKnowledgeMatches: [KnowledgeChunkMatch] = []
  @State private var searchFeedbackEntries: [KnowledgeSearchFeedback] = []
  @State private var knowledgeSelectionHistory: [KnowledgeSelectionHistory] = []
  @State private var ragEvaluationCases: [RAGEvaluationCase] = []
  @State private var ragEvaluationProfiles: [RAGEvaluationProfile] = []
  @State private var ragEvaluationReports: [RAGEvaluationReport] = []
  @State private var ragEvaluationSuites: [RAGEvaluationSuite] = []
  @State private var ragEvaluationAutomationSettings = RAGEvaluationAutomationSettings()
  @State private var runningRAGEvaluationCaseIDs: Set<UUID> = []
  @State private var runningRAGEvaluationMatrix = false
  @State private var ragEvaluationMatrixProgress: String?
  @State private var customSearchPresets: [SearchPreset] = []
  @State private var knowledgeSearchQuery = ""
  @State private var quickKnowledgeSearchQuery = ""
  @State private var knowledgeButtonsScrollVisibility = KnowledgeButtonsScrollVisibility()
  @State private var selectedCitation: KnowledgeChunkMatch?
  @State private var showingKnowledgeImporter = false
  @State private var showingWebResearch = false
  @State private var queuedWebResearchSources: [WebResearchSource] = []
  @State private var showingKnowledgeDocuments = false
  @State private var showingSearchSettings = false
  @State private var showingChunkingSettings = false
  @State private var showingSearchFeedbackLog = false
  @State private var showingKnowledgeSelectionHistory = false
  @State private var showingRAGEvaluation = false
  @State private var showingCodexTasks = false
  @State private var aiTaskAvailabilities: [CodexAvailability] = []
  @State private var codexTasks: [CodexTaskRecord] = []
  @State private var showingMCPAudit = false
  @State private var knowledgeToolAuditEntries: [KnowledgeToolAuditEntry] = []
  @State private var showingDecisionLab = false
  @State private var showingDataManagement = false
  @State private var decisionModels: [DecisionModelSummary] = []
  @State private var decisionRuns: [DecisionExperimentRecord] = []
  @State private var decisionEvaluationReports: [DecisionEvaluationReport] = []
  @State private var busy = false
  @State private var sendingConversationID: UUID?
  @State private var stopRequested = false
  @State private var stoppingGeneration = false
  @State private var available = false
  @AppStorage("onigiri.providerID") private var selectedProviderID = "apple-foundation-models"
  @AppStorage("onigiri.baseURL") private var baseURL = ""
  @AppStorage("onigiri.modelID") private var modelID = ""
  @AppStorage("onigiri.searchLimit") private var searchLimit = 5
  @AppStorage("onigiri.searchMinScore") private var searchMinScore = 1
  @AppStorage("onigiri.searchKeywordWeight") private var searchKeywordWeight = 1.0
  @AppStorage("onigiri.searchEmbeddingWeight") private var searchEmbeddingWeight = 1.0
  @AppStorage("onigiri.chunkMaxCharacters") private var chunkMaxCharacters = 1_200
  @AppStorage("onigiri.chunkOverlapCharacters") private var chunkOverlapCharacters = 260
  @AppStorage("onigiri.ragEvaluationSuiteID") private var selectedRAGEvaluationSuiteID = ""

  private var selectedConversation: StoredConversation? {
    guard let selectedConversationID else { return nil }
    return conversations.first { $0.id == selectedConversationID }
  }

  private var conversationID: UUID {
    selectedConversationID ?? conversations.first?.id ?? UUID()
  }

  private var messages: [DisplayMessage] {
    selectedConversation?.messages ?? []
  }

  private var currentSearchSettings: KnowledgeSearchSettings {
    KnowledgeSearchSettings(
      limit: searchLimit,
      minScore: searchMinScore,
      keywordWeight: searchKeywordWeight,
      embeddingWeight: searchEmbeddingWeight
    )
  }

  private var selectedRAGEvaluationSuite: RAGEvaluationSuite? {
    guard let id = UUID(uuidString: selectedRAGEvaluationSuiteID) else { return nil }
    return ragEvaluationSuites.first { $0.id == id }
  }

  private var scopedRAGEvaluationCases: [RAGEvaluationCase] {
    guard let suite = selectedRAGEvaluationSuite else { return ragEvaluationCases }
    let caseIDs = Set(suite.caseIDs)
    return ragEvaluationCases.filter { caseIDs.contains($0.id) }
  }

  var body: some View {
    HStack(spacing: 0) {
      conversationSidebar
      Divider()
      chatWorkspace
    }
    .frame(minWidth: 980, minHeight: 620)
    .task {
      do {
        _ = try OnigiriDataVault().prepareStorage()
      } catch {
        errorMessage = error.localizedDescription
      }
      loadProductProfiles()
      loadConversations()
      loadSearchPresets()
      loadKnowledgeSelectionHistory()
      loadRAGEvaluationCases()
      loadRAGEvaluationProfiles()
      loadRAGEvaluationSuites()
      loadRAGEvaluationAutomationSettings()
      loadRAGEvaluationReports()
      await waitForServer()
      await loadProviders()
      activateProfileForSelectedConversation()
      await applyProvider(clearChat: false)
      if selectedProviderNeedsLocalSettings { await loadModels(applyFirst: false) }
      await loadKnowledgeStatus()
      await loadKnowledgeDocuments()
      await loadKnowledgeChunkingSettings()
    }
    .task(id: ragEvaluationAutomationSettings.isEnabled) {
      await runRAGEvaluationAutomationLoop()
    }
    .onChange(of: selectedConversationID) { _, _ in
      queuedKnowledgeMatches = []
      queuedWebResearchSources = []
      activateProfileForSelectedConversation()
    }
    .fileImporter(
      isPresented: $showingKnowledgeImporter,
      allowedContentTypes: [
        .plainText, .text, .utf8PlainText, .pdf, .folder, UTType(filenameExtension: "md") ?? .text,
        UTType(filenameExtension: "markdown") ?? .text,
      ],
      allowsMultipleSelection: true
    ) { result in
      Task { await importKnowledge(result) }
    }
    .sheet(isPresented: $showingCodexTasks) {
      CodexTasksView(
        availabilities: aiTaskAvailabilities,
        tasks: codexTasks,
        refresh: { await loadCodexTasks() },
        start: { request in await startCodexTask(request) },
        cancel: { id in await cancelCodexTask(id) }
      )
      .frame(minWidth: 820, minHeight: 620, alignment: .topLeading)
    }
    .sheet(isPresented: $showingWebResearch) {
      WebResearchView(sources: $queuedWebResearchSources)
        .frame(minWidth: 900, minHeight: 650, alignment: .topLeading)
    }
    .sheet(isPresented: $showingMCPAudit) {
      MCPAuditView(
        entries: knowledgeToolAuditEntries,
        refresh: { await loadKnowledgeToolAudit() },
        clear: { await clearKnowledgeToolAudit() }
      )
      .frame(minWidth: 760, minHeight: 520, alignment: .topLeading)
    }
    .sheet(isPresented: $showingDecisionLab) {
      DecisionLabView(
        models: decisionModels,
        runs: decisionRuns,
        loadModels: { config in await loadDecisionModels(config) },
        run: { request in await runDecisionExperiment(request) },
        refreshRuns: { await loadDecisionRuns() },
        clearRuns: { await clearDecisionRuns() },
        evaluationReports: decisionEvaluationReports,
        runEvaluation: { request in await runDecisionEvaluation(request) },
        refreshEvaluations: { await loadDecisionEvaluations() },
        clearEvaluations: { await clearDecisionEvaluations() }
      )
      .frame(minWidth: 980, minHeight: 680, alignment: .topLeading)
    }
    .sheet(isPresented: $showingDataManagement) {
      DataManagementView()
        .frame(minWidth: 620, minHeight: 460, alignment: .topLeading)
    }
    .sheet(isPresented: $showingKnowledgeDocuments) {
      KnowledgeDocumentsView(
        documents: knowledgeDocuments,
        searchDocument: { document in
          Task { await searchKnowledge(query: document.title) }
        },
        showChunks: { document in
          Task { await loadKnowledgeChunks(for: document) }
        },
        deleteDocument: { id in
          Task { await deleteKnowledgeDocument(id) }
        }
      )
      .frame(minWidth: 560, minHeight: 380, alignment: .topLeading)
    }
    .sheet(isPresented: $showingProductProfiles, onDismiss: {
      normalizeAndSaveProductProfiles()
      activateProfileForSelectedConversation()
      Task { await applyProvider(clearChat: false) }
    }) {
      ProductProfilesView(
        profiles: $productProfiles,
        defaultProfileID: $defaultProductProfileID,
        selectedProfileID: selectedProductProfileID,
        providerOptions: providerOptions
      )
      .frame(minWidth: 820, minHeight: 560, alignment: .topLeading)
    }
    .sheet(item: $selectedKnowledgeChunks) { response in
      KnowledgeChunksView(response: response, settings: currentSearchSettings)
        .frame(minWidth: 720, minHeight: 580, alignment: .topLeading)
    }
    .sheet(item: $knowledgeSearchPresentation) { result in
      KnowledgeMatchesView(
        query: result.query,
        matches: result.matches,
        useSelected: { selected in
          queueKnowledgeMatches(selected, query: result.query, recordHistory: true)
          knowledgeSearchPresentation = nil
        },
        rateMatch: { match, rating in
          recordSearchFeedback(match: match, rating: rating)
        },
        showCitation: { citation in
          selectedCitation = citation
        }
      )
      .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
    }
    .sheet(isPresented: $showingSearchSettings) {
      SearchSettingsView(
        limit: $searchLimit,
        minScore: $searchMinScore,
        keywordWeight: $searchKeywordWeight,
        embeddingWeight: $searchEmbeddingWeight,
        customPresets: customSearchPresets,
        applyPreset: { preset in
          applySearchSettings(preset.settings, showSettings: false)
        },
        savePreset: { name in
          saveSearchPreset(named: name)
        },
        deletePreset: { preset in
          deleteSearchPreset(preset)
        }
      )
      .frame(minWidth: 420, minHeight: 440, alignment: .topLeading)
    }
    .sheet(isPresented: $showingChunkingSettings) {
      ChunkingSettingsView(
        maxCharacters: $chunkMaxCharacters,
        overlapCharacters: $chunkOverlapCharacters,
        apply: {
          Task { await applyKnowledgeChunkingSettings() }
        }
      )
      .frame(minWidth: 420, minHeight: 260, alignment: .topLeading)
    }
    .sheet(isPresented: $showingSearchFeedbackLog) {
      SearchFeedbackLogView(
        entries: searchFeedbackEntries,
        applySettings: { settings in
          applySearchSettings(settings)
        },
        deleteFeedback: { feedback in
          deleteSearchFeedback(feedback)
        },
        deleteFeedbackEntries: { entries in
          deleteSearchFeedbackEntries(entries)
        },
        showCitation: { feedback in
          selectedCitation = feedback.match
        }
      )
      .frame(minWidth: 680, minHeight: 460, alignment: .topLeading)
    }
    .sheet(isPresented: $showingKnowledgeSelectionHistory) {
      KnowledgeSelectionHistoryView(
        entries: knowledgeSelectionHistory,
        reuse: { entry in
          queueKnowledgeMatches(entry.matches, query: entry.query, recordHistory: false)
          showingKnowledgeSelectionHistory = false
        },
        togglePinned: { entry in
          toggleKnowledgeSelectionHistoryPinned(entry)
        },
        delete: { entry in
          deleteKnowledgeSelectionHistory(entry)
        },
        addEvaluationCase: { entry in
          addRAGEvaluationCase(from: entry)
        }
      )
      .frame(minWidth: 680, minHeight: 460, alignment: .topLeading)
    }
    .sheet(isPresented: $showingRAGEvaluation) {
      RAGEvaluationView(
        cases: ragEvaluationCases,
        documents: knowledgeDocuments,
        profiles: ragEvaluationProfiles,
        reports: ragEvaluationReports,
        suites: ragEvaluationSuites,
        selectedSuiteID: UUID(uuidString: selectedRAGEvaluationSuiteID),
        automationSettings: ragEvaluationAutomationSettings,
        runningCaseIDs: runningRAGEvaluationCaseIDs,
        matrixRunning: runningRAGEvaluationMatrix,
        matrixProgress: ragEvaluationMatrixProgress,
        runAll: {
          Task { await runAllRAGEvaluations() }
        },
        run: { evaluationCase in
          Task { await runRAGEvaluation(evaluationCase) }
        },
        importCases: { importedCases in
          importRAGEvaluationCases(importedCases)
        },
        registerCurrentEnvironment: {
          registerCurrentRAGEvaluationEnvironment()
        },
        updateProfile: { profile in
          updateRAGEvaluationProfile(profile)
        },
        deleteProfile: { profile in
          deleteRAGEvaluationProfile(profile)
        },
        runMatrix: {
          Task { await runRAGEvaluationMatrix() }
        },
        selectSuite: { suiteID in
          selectedRAGEvaluationSuiteID = suiteID?.uuidString ?? ""
        },
        createSuite: { createRAGEvaluationSuite() },
        updateSuite: { suite in updateRAGEvaluationSuite(suite) },
        deleteSuite: { suite in deleteRAGEvaluationSuite(suite) },
        toggleCaseInSuite: { evaluationCase, suite in
          toggleRAGEvaluationCase(evaluationCase, in: suite)
        },
        updateAutomationSettings: { settings in
          updateRAGEvaluationAutomationSettings(settings)
        },
        updateCriteria: { evaluationCase, criteria in
          updateRAGEvaluationCriteria(evaluationCase, criteria: criteria)
        },
        updateExpectedSearch: { evaluationCase, expectedSearch in
          updateRAGEvaluationSearchExpectation(evaluationCase, expectedSearch: expectedSearch)
        },
        addNoSearchCase: { question in
          addNoSearchRAGEvaluationCase(question: question)
        },
        updateAnswerRules: { evaluationCase, expectedPoints, forbiddenPhrases in
          updateRAGEvaluationAnswerRules(
            evaluationCase, expectedPoints: expectedPoints,
            forbiddenPhrases: forbiddenPhrases)
        },
        updateTags: { evaluationCase, tags in
          updateRAGEvaluationTags(evaluationCase, tags: tags)
        },
        suggestAnswerPoints: { evaluationCase in
          suggestRAGEvaluationAnswerPoints(evaluationCase)
        },
        duplicate: { evaluationCase in
          duplicateRAGEvaluationCase(evaluationCase)
        },
        generateCandidates: { document in
          await generateRAGEvaluationCandidates(for: document)
        },
        addGeneratedCandidates: { candidates in
          addGeneratedRAGEvaluationCandidates(candidates)
        },
        setBaseline: { evaluationCase, evaluationRun in
          setRAGEvaluationBaseline(evaluationCase, run: evaluationRun)
        },
        delete: { evaluationCase in
          deleteRAGEvaluationCase(evaluationCase)
        }
      )
      .frame(minWidth: 900, minHeight: 680, alignment: .topLeading)
    }
    .sheet(item: $selectedCitation) { citation in
      KnowledgeCitationDetailView(citation: citation)
        .frame(minWidth: 540, minHeight: 360, alignment: .topLeading)
    }
  }

  private var appHeader: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 10) {
        Text("🍙")
          .font(.system(size: 30))
        Text("Onigiri Harness")
          .font(.system(size: 28, weight: .bold))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }

      HStack(alignment: .top, spacing: 8) {
        Circle().fill(available ? .green : .orange).frame(width: 8, height: 8).padding(.top, 4)
        Text("\(providerName): \(status)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .textSelection(.enabled)
        Spacer(minLength: 4)
        Button("再確認") { Task { await waitForServer() } }
          .font(.caption)
          .disabled(busy)
      }
    }
  }

  private var chatWorkspace: some View {
    VStack(alignment: .leading, spacing: 14) {
      providerSettings
      Divider()
      knowledgeSettings
      Divider()

      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(spacing: 12) {
            if messages.isEmpty {
              ContentUnavailableView(
                "新しい会話",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("\(providerName) と会話できます。")
              )
              .padding(.top, 70)
            }
            ForEach(messages) { item in
              MessageRow(message: item) { citation in
                selectedCitation = citation
              }
              .id(item.id)
            }
          }
          .padding(.vertical, 8)
        }
        .onChange(of: messages) { _, items in
          guard let id = items.last?.id else { return }
          withAnimation { proxy.scrollTo(id, anchor: .bottom) }
        }
      }

      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }

      if !queuedKnowledgeMatches.isEmpty {
        HStack {
          Text("次の質問に選択中のチャンク \(queuedKnowledgeMatches.count)件を使用")
            .font(.caption)
          Spacer()
          Button("選択を解除") { queuedKnowledgeMatches = [] }
            .font(.caption)
            .disabled(busy)
        }
      }

      if !queuedWebResearchSources.isEmpty {
        HStack {
          Text(webResearchQueueLabel)
            .font(.caption)
          Spacer()
          Button("Web資料を解除") { queuedWebResearchSources = [] }
            .font(.caption)
            .disabled(busy)
        }
      }

      ChatComposerTextView(
        text: $draft,
        isEnabled: !busy,
        canSubmit: available && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        onSubmit: { Task { await send() } }
      )
        .frame(height: 78)
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        .accessibilityLabel("メッセージ")

      HStack {
        Text("会話の文脈は「新しい会話」を押すまで保持されます。")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        if busy { ProgressView().controlSize(.small) }
        if sendingConversationID != nil {
          Button("停止", systemImage: "stop.fill") { Task { await stopGeneration() } }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(stoppingGeneration)
        } else {
          Button("送信") { Task { await send() } }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(
              busy || !available || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var webResearchQueueLabel: String {
    if locale.identifier.lowercased().hasPrefix("ja") {
      return "次の質問にWebページ \(queuedWebResearchSources.count)件を使用"
    }
    return "Using \(queuedWebResearchSources.count) web page(s) for the next question"
  }

  private var conversationSidebar: some View {
    VStack(alignment: .leading, spacing: 14) {
      appHeader
      Divider()
      HStack {
        Text("チャット")
          .font(.headline)
        Spacer()
        Button {
          deleteSelectedConversation()
        } label: {
          Image(systemName: "minus")
            .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .help("選択中の会話を削除")
        .disabled(busy || selectedConversationID == nil)
        Button {
          Task { await newConversation() }
        } label: {
          Image(systemName: "plus")
            .frame(width: 28, height: 24)
        }
        .buttonStyle(.bordered)
        .help("新しい会話")
        .disabled(busy)
      }
      List(selection: $selectedConversationID) {
        ForEach(conversations) { conversation in
          ConversationRow(conversation: conversation)
            .tag(conversation.id)
            .contextMenu {
              Button("Markdownとしてエクスポート", systemImage: "square.and.arrow.down") {
                exportConversationMarkdown(conversation)
              }
            }
        }
        .onDelete { offsets in
          deleteConversations(at: offsets)
        }
      }
      .listStyle(.sidebar)
    }
    .padding(16)
    .frame(width: 330)
    .background(Color.secondary.opacity(0.05))
  }

  private var selectedProviderNeedsLocalSettings: Bool {
    selectedProviderID != "apple-foundation-models" && selectedProviderID != "apple"
  }

  private var selectedProviderUsesBaseURL: Bool {
    ["lmstudio", "lm-studio", "ollama", "openai-compatible"].contains(selectedProviderID)
  }

  private var providerSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text("Profile")
          .font(.headline)
        Picker("Profile", selection: $selectedProductProfileID) {
          ForEach(productProfiles) { profile in
            Text(profile.name).tag(Optional(profile.id))
          }
        }
        .labelsHidden()
        .frame(width: 220)
        .onChange(of: selectedProductProfileID) { _, profileID in
          guard profileID != nil else { return }
          assignProfileToSelectedConversation(profileID)
          activateProfileForSelectedConversation()
          if available { Task { await applyProvider(clearChat: false) } }
        }
        Button("管理") { showingProductProfiles = true }
          .disabled(busy)
        Text(LocalizedStringKey(selectedRAGMode.displayName))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer(minLength: 8)
        if defaultProductProfileID == selectedProductProfileID {
          Label("既定", systemImage: "star.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.small)

      HStack(spacing: 10) {
        Text("モデル")
          .font(.headline)

        Picker("Provider", selection: $selectedProviderID) {
          ForEach(providerOptions, id: \.id) { option in
            Text(option.name).tag(option.id)
          }
        }
        .labelsHidden()
        .frame(width: 220)
        .onChange(of: selectedProviderID) { _, providerID in
          if let profile = selectedProductProfileID.flatMap({ id in
            productProfiles.first(where: { $0.id == id && $0.providerID == providerID })
          }) {
            baseURL = profile.baseURL
            modelID = profile.modelID
          } else if let defaultBaseURL = providerOptions.first(where: { $0.id == providerID })?
            .defaultBaseURL
          {
            baseURL = defaultBaseURL
          } else if !selectedProviderUsesBaseURL {
            baseURL = ""
            modelID = ""
            modelIDs = []
          } else if !selectedProviderNeedsLocalSettings {
            baseURL = ""
            modelID = ""
            modelIDs = []
          }
        }

        Spacer(minLength: 8)

        Button("モデル再取得") { Task { await loadModels(applyFirst: true) } }
          .disabled(busy || !selectedProviderNeedsLocalSettings)
        Button("Profileへ保存・適用") {
          captureCurrentSettingsInActiveProfile()
          Task { await applyProvider(clearChat: false) }
        }
          .disabled(busy)
      }
      .controlSize(.small)

      if selectedProviderNeedsLocalSettings {
        HStack(spacing: 8) {
          if selectedProviderUsesBaseURL {
            TextField("Base URL", text: $baseURL)
              .textFieldStyle(.roundedBorder)
          }

          TextField(
            selectedProviderUsesBaseURL ? "Model ID" : "Model ID（空欄ならCLIの既定値）",
            text: $modelID)
            .textFieldStyle(.roundedBorder)

          if !modelIDs.isEmpty {
            Picker("候補", selection: $modelID) {
              Text("未指定").tag("")
              ForEach(modelIDs, id: \.self) { model in
                Text(model).tag(model)
              }
            }
            .labelsHidden()
            .frame(width: 180)
          }
        }
      }
    }
  }

  private var conversationsStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "conversations.json")
  }

  private var productProfilesStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "product-profiles.json")
  }

  private var searchFeedbackStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "search-feedback.json")
  }

  private var searchPresetsStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "search-presets.json")
  }

  private var knowledgeSelectionHistoryStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "knowledge-selection-history.json")
  }

  private var ragEvaluationStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "rag-evaluations.json")
  }

  private var ragEvaluationProfilesStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "rag-evaluation-environments.json")
  }

  private var ragEvaluationReportsStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "rag-evaluation-reports.json")
  }

  private var ragEvaluationSuitesStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "rag-evaluation-suites.json")
  }

  private var ragEvaluationAutomationStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "rag-evaluation-automation.json")
  }

  @MainActor private func loadConversations() {
    do {
      let data = try Data(contentsOf: conversationsStoreURL)
      let decoded = try JSONDecoder().decode([StoredConversation].self, from: data)
      conversations = decoded.isEmpty ? [.empty] : decoded
    } catch {
      _ = try? OnigiriDataVault().preserveCorruptFile(at: conversationsStoreURL)
      conversations = [.empty]
    }
    let fallbackProfileID = defaultProductProfileID ?? productProfiles.first?.id
    let validProfileIDs = Set(productProfiles.map(\.id))
    for index in conversations.indices {
      if conversations[index].profileID.map({ validProfileIDs.contains($0) }) != true {
        conversations[index].profileID = fallbackProfileID
      }
    }
    selectedConversationID = conversations.first?.id
    selectedProductProfileID = conversations.first?.profileID ?? fallbackProfileID
    saveConversations()
  }

  @MainActor private func loadProductProfiles() {
    do {
      let data = try Data(contentsOf: productProfilesStoreURL)
      let store = try JSONDecoder().decode(ProductProfileStore.self, from: data)
      guard !store.profiles.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
      productProfiles = store.profiles
      defaultProductProfileID = store.profiles.contains { $0.id == store.defaultProfileID }
        ? store.defaultProfileID : store.profiles[0].id
    } catch {
      _ = try? OnigiriDataVault().preserveCorruptFile(at: productProfilesStoreURL)
      let migrated = ProductProfile(
        name: "general", providerID: selectedProviderID, baseURL: baseURL, modelID: modelID,
        searchSettings: currentSearchSettings)
      let apple = ProductProfile(name: "apple-local", providerID: "apple-foundation-models")
      productProfiles = [migrated, apple]
      defaultProductProfileID = migrated.id
      saveProductProfiles()
    }
  }

  @MainActor private func saveProductProfiles() {
    guard let defaultID = defaultProductProfileID, !productProfiles.isEmpty else { return }
    do {
      try FileManager.default.createDirectory(
        at: productProfilesStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      let store = ProductProfileStore(
        formatVersion: 1, defaultProfileID: defaultID, profiles: productProfiles)
      let data = try JSONEncoder().encode(store)
      try data.write(to: productProfilesStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func normalizeAndSaveProductProfiles() {
    if productProfiles.isEmpty {
      let fallback = ProductProfile(name: "general", providerID: "apple-foundation-models")
      productProfiles = [fallback]
      defaultProductProfileID = fallback.id
    }
    for index in productProfiles.indices {
      let trimmedName = productProfiles[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
      productProfiles[index].name = trimmedName.isEmpty ? "Profile \(index + 1)" : trimmedName
      productProfiles[index].systemInstructions = ChatRuntimeOptions(
        systemInstructions: productProfiles[index].systemInstructions
      ).systemInstructions
      productProfiles[index].contextLimit = min(max(productProfiles[index].contextLimit, 2_000), 50_000)
    }
    let validIDs = Set(productProfiles.map(\.id))
    if defaultProductProfileID.map({ validIDs.contains($0) }) != true {
      defaultProductProfileID = productProfiles[0].id
    }
    let fallbackID = defaultProductProfileID ?? productProfiles[0].id
    for index in conversations.indices
    where conversations[index].profileID.map({ validIDs.contains($0) }) != true {
      conversations[index].profileID = fallbackID
    }
    if selectedProductProfileID.map({ validIDs.contains($0) }) != true {
      selectedProductProfileID = fallbackID
      assignProfileToSelectedConversation(fallbackID)
    }
    saveProductProfiles()
    saveConversations()
  }

  @MainActor private func assignProfileToSelectedConversation(_ profileID: UUID?) {
    guard let conversationID = selectedConversationID,
      let index = conversations.firstIndex(where: { $0.id == conversationID })
    else { return }
    conversations[index].profileID = profileID
    saveConversations()
  }

  @MainActor private func activateProfileForSelectedConversation() {
    let assignedID = selectedConversation?.profileID ?? defaultProductProfileID
    guard let profile = productProfiles.first(where: { $0.id == assignedID })
      ?? productProfiles.first
    else { return }
    selectedProductProfileID = profile.id
    selectedProviderID = profile.providerID
    baseURL = profile.baseURL
    modelID = profile.modelID
    systemInstructions = profile.systemInstructions
    selectedRAGMode = profile.ragMode
    searchLimit = profile.searchSettings.limit
    searchMinScore = profile.searchSettings.minScore
    searchKeywordWeight = profile.searchSettings.keywordWeight
    searchEmbeddingWeight = profile.searchSettings.embeddingWeight
    contextLimit = profile.contextLimit
  }

  @MainActor private func captureCurrentSettingsInActiveProfile() {
    guard let profileID = selectedProductProfileID,
      let index = productProfiles.firstIndex(where: { $0.id == profileID })
    else { return }
    productProfiles[index].providerID = selectedProviderID
    productProfiles[index].baseURL = selectedProviderUsesBaseURL ? baseURL : ""
    productProfiles[index].modelID = selectedProviderNeedsLocalSettings ? modelID : ""
    productProfiles[index].systemInstructions = systemInstructions
    productProfiles[index].ragMode = selectedRAGMode
    productProfiles[index].searchSettings = currentSearchSettings
    productProfiles[index].contextLimit = contextLimit
    normalizeAndSaveProductProfiles()
  }

  @MainActor private func saveConversations() {
    do {
      try FileManager.default.createDirectory(
        at: conversationsStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(conversations)
      try data.write(to: conversationsStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadKnowledgeSelectionHistory() {
    do {
      let data = try Data(contentsOf: knowledgeSelectionHistoryStoreURL)
      knowledgeSelectionHistory =
        try JSONDecoder().decode([KnowledgeSelectionHistory].self, from: data)
        .sorted(by: Self.knowledgeSelectionHistoryOrder)
    } catch {
      knowledgeSelectionHistory = []
    }
  }

  @MainActor private func saveKnowledgeSelectionHistory() {
    do {
      try FileManager.default.createDirectory(
        at: knowledgeSelectionHistoryStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      knowledgeSelectionHistory.sort(by: Self.knowledgeSelectionHistoryOrder)
      let data = try JSONEncoder().encode(knowledgeSelectionHistory)
      try data.write(to: knowledgeSelectionHistoryStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private static func knowledgeSelectionHistoryOrder(
    _ lhs: KnowledgeSelectionHistory, _ rhs: KnowledgeSelectionHistory
  ) -> Bool {
    if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
    return lhs.createdAt > rhs.createdAt
  }

  @MainActor private func queueKnowledgeMatches(
    _ matches: [KnowledgeChunkMatch], query: String, recordHistory: Bool
  ) {
    let normalized = matches.prefix(3).enumerated().map { offset, match in
      KnowledgeChunkMatch(
        documentID: match.documentID, title: match.title,
        chunkIndex: match.chunkIndex, score: match.score,
        citationIndex: offset + 1, text: match.text,
        searchMode: match.searchMode, diagnostics: match.diagnostics)
    }
    guard !normalized.isEmpty else { return }
    queuedKnowledgeMatches = normalized
    quickKnowledgeSearchQuery = query
    guard recordHistory else { return }

    let ids = normalized.map(\.id)
    let existingIndex = knowledgeSelectionHistory.firstIndex {
      $0.query == query && $0.matches.map(\.id) == ids
    }
    if let existingIndex {
      knowledgeSelectionHistory[existingIndex].createdAt = Date()
    } else {
      knowledgeSelectionHistory.append(
        KnowledgeSelectionHistory(query: query, matches: normalized))
    }
    let pinned = knowledgeSelectionHistory.filter(\.isPinned)
    let recent = knowledgeSelectionHistory.filter { !$0.isPinned }
      .sorted { $0.createdAt > $1.createdAt }
      .prefix(100)
    knowledgeSelectionHistory = pinned + recent
    saveKnowledgeSelectionHistory()
  }

  @MainActor private func toggleKnowledgeSelectionHistoryPinned(
    _ entry: KnowledgeSelectionHistory
  ) {
    guard let index = knowledgeSelectionHistory.firstIndex(where: { $0.id == entry.id }) else {
      return
    }
    knowledgeSelectionHistory[index].isPinned.toggle()
    saveKnowledgeSelectionHistory()
  }

  @MainActor private func deleteKnowledgeSelectionHistory(_ entry: KnowledgeSelectionHistory) {
    knowledgeSelectionHistory.removeAll { $0.id == entry.id }
    saveKnowledgeSelectionHistory()
  }

  @MainActor private func discardInvalidKnowledgeSelectionHistory() {
    let documentIDs = Set(knowledgeDocuments.map(\.id))
    let remaining = knowledgeSelectionHistory.filter { entry in
      !entry.matches.isEmpty && entry.matches.allSatisfy { documentIDs.contains($0.documentID) }
    }
    guard remaining != knowledgeSelectionHistory else { return }
    knowledgeSelectionHistory = remaining
    saveKnowledgeSelectionHistory()
  }

  @MainActor private func loadRAGEvaluationCases() {
    do {
      let data = try Data(contentsOf: ragEvaluationStoreURL)
      ragEvaluationCases = try JSONDecoder().decode([RAGEvaluationCase].self, from: data)
        .sorted { $0.createdAt > $1.createdAt }
    } catch {
      ragEvaluationCases = []
    }
  }

  @MainActor private func loadRAGEvaluationProfiles() {
    do {
      let data = try Data(contentsOf: ragEvaluationProfilesStoreURL)
      ragEvaluationProfiles = try JSONDecoder().decode([RAGEvaluationProfile].self, from: data)
    } catch {
      ragEvaluationProfiles = []
    }
  }

  @MainActor private func loadRAGEvaluationSuites() {
    do {
      let data = try Data(contentsOf: ragEvaluationSuitesStoreURL)
      ragEvaluationSuites = try JSONDecoder().decode([RAGEvaluationSuite].self, from: data)
      let validCaseIDs = Set(ragEvaluationCases.map(\.id))
      for index in ragEvaluationSuites.indices {
        ragEvaluationSuites[index].caseIDs.removeAll { !validCaseIDs.contains($0) }
      }
      if !selectedRAGEvaluationSuiteID.isEmpty,
        !ragEvaluationSuites.contains(where: { $0.id.uuidString == selectedRAGEvaluationSuiteID })
      {
        selectedRAGEvaluationSuiteID = ""
      }
    } catch {
      ragEvaluationSuites = []
      selectedRAGEvaluationSuiteID = ""
    }
  }

  @MainActor private func saveRAGEvaluationSuites() {
    do {
      try FileManager.default.createDirectory(
        at: ragEvaluationSuitesStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try JSONEncoder().encode(ragEvaluationSuites)
        .write(to: ragEvaluationSuitesStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func pruneRAGEvaluationSuites() {
    let validCaseIDs = Set(ragEvaluationCases.map(\.id))
    for index in ragEvaluationSuites.indices {
      ragEvaluationSuites[index].caseIDs.removeAll { !validCaseIDs.contains($0) }
    }
    saveRAGEvaluationSuites()
  }

  @MainActor private func createRAGEvaluationSuite() {
    let suite = RAGEvaluationSuite(
      name: "新しいスイート \(ragEvaluationSuites.count + 1)",
      caseIDs: ragEvaluationCases.map(\.id))
    ragEvaluationSuites.append(suite)
    selectedRAGEvaluationSuiteID = suite.id.uuidString
    saveRAGEvaluationSuites()
  }

  @MainActor private func updateRAGEvaluationSuite(_ suite: RAGEvaluationSuite) {
    guard let index = ragEvaluationSuites.firstIndex(where: { $0.id == suite.id }) else { return }
    ragEvaluationSuites[index] = suite
    saveRAGEvaluationSuites()
  }

  @MainActor private func deleteRAGEvaluationSuite(_ suite: RAGEvaluationSuite) {
    ragEvaluationSuites.removeAll { $0.id == suite.id }
    if selectedRAGEvaluationSuiteID == suite.id.uuidString { selectedRAGEvaluationSuiteID = "" }
    saveRAGEvaluationSuites()
  }

  @MainActor private func toggleRAGEvaluationCase(
    _ evaluationCase: RAGEvaluationCase, in suite: RAGEvaluationSuite
  ) {
    guard let index = ragEvaluationSuites.firstIndex(where: { $0.id == suite.id }) else { return }
    if let caseIndex = ragEvaluationSuites[index].caseIDs.firstIndex(of: evaluationCase.id) {
      ragEvaluationSuites[index].caseIDs.remove(at: caseIndex)
    } else {
      ragEvaluationSuites[index].caseIDs.append(evaluationCase.id)
    }
    saveRAGEvaluationSuites()
  }

  @MainActor private func loadRAGEvaluationReports() {
    do {
      let data = try Data(contentsOf: ragEvaluationReportsStoreURL)
      ragEvaluationReports = try JSONDecoder().decode([RAGEvaluationReport].self, from: data)
        .sorted { $0.completedAt > $1.completedAt }
      pruneRAGEvaluationReports()
    } catch {
      ragEvaluationReports = []
    }
  }

  @MainActor private func loadRAGEvaluationAutomationSettings() {
    do {
      let data = try Data(contentsOf: ragEvaluationAutomationStoreURL)
      ragEvaluationAutomationSettings =
        try JSONDecoder().decode(RAGEvaluationAutomationSettings.self, from: data)
    } catch {
      ragEvaluationAutomationSettings = RAGEvaluationAutomationSettings()
    }
  }

  @MainActor private func updateRAGEvaluationAutomationSettings(
    _ settings: RAGEvaluationAutomationSettings
  ) {
    let shouldRequestNotificationPermission = settings.notifyOnRegression
      && ((!ragEvaluationAutomationSettings.isEnabled && settings.isEnabled)
        || !ragEvaluationAutomationSettings.notifyOnRegression)
    var normalized = settings
    normalized.scheduledHour = min(max(settings.scheduledHour, 0), 23)
    normalized.scheduledMinute = min(max(settings.scheduledMinute, 0), 59)
    normalized.retentionDays = min(max(settings.retentionDays, 1), 365)
    ragEvaluationAutomationSettings = normalized
    saveRAGEvaluationAutomationSettings()
    pruneRAGEvaluationReports()
    saveRAGEvaluationReports()
    if shouldRequestNotificationPermission {
      Task {
        _ = try? await UNUserNotificationCenter.current()
          .requestAuthorization(options: [.alert, .sound])
      }
    }
  }

  @MainActor private func saveRAGEvaluationAutomationSettings() {
    do {
      try FileManager.default.createDirectory(
        at: ragEvaluationAutomationStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try JSONEncoder().encode(ragEvaluationAutomationSettings)
        .write(to: ragEvaluationAutomationStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func saveRAGEvaluationReports() {
    do {
      try FileManager.default.createDirectory(
        at: ragEvaluationReportsStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      ragEvaluationReports.sort { $0.completedAt > $1.completedAt }
      pruneRAGEvaluationReports()
      ragEvaluationReports = Array(ragEvaluationReports.prefix(100))
      try JSONEncoder().encode(ragEvaluationReports)
        .write(to: ragEvaluationReportsStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func pruneRAGEvaluationReports(now: Date = Date()) {
    let cutoff = Calendar.current.date(
      byAdding: .day, value: -ragEvaluationAutomationSettings.retentionDays, to: now)
      ?? .distantPast
    ragEvaluationReports.removeAll { $0.completedAt < cutoff }
  }

  @MainActor private func runRAGEvaluationAutomationLoop() async {
    guard ragEvaluationAutomationSettings.isEnabled else { return }
    while !Task.isCancelled {
      if shouldRunScheduledRAGEvaluation() {
        ragEvaluationAutomationSettings.lastScheduledRunAt = Date()
        saveRAGEvaluationAutomationSettings()
        await runRAGEvaluationMatrix(trigger: .scheduled)
      }
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {
        return
      }
    }
  }

  @MainActor private func shouldRunScheduledRAGEvaluation(now: Date = Date()) -> Bool {
    guard ragEvaluationAutomationSettings.isEnabled,
      !runningRAGEvaluationMatrix,
      !scopedRAGEvaluationCases.isEmpty,
      ragEvaluationProfiles.contains(where: \.isSelected)
    else { return false }
    let calendar = Calendar.current
    guard let scheduled = calendar.date(
      bySettingHour: ragEvaluationAutomationSettings.scheduledHour,
      minute: ragEvaluationAutomationSettings.scheduledMinute, second: 0, of: now),
      now >= scheduled
    else { return false }
    return ragEvaluationAutomationSettings.lastScheduledRunAt.map { $0 < scheduled } ?? true
  }

  @MainActor private func saveRAGEvaluationProfiles() {
    do {
      try FileManager.default.createDirectory(
        at: ragEvaluationProfilesStoreURL.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      try JSONEncoder().encode(ragEvaluationProfiles)
        .write(to: ragEvaluationProfilesStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func registerCurrentRAGEvaluationEnvironment() {
    let environment = RAGEvaluationEnvironment(
      providerID: selectedProviderID,
      providerName: providerName,
      baseURL: selectedProviderUsesBaseURL ? baseURL : nil,
      modelID: selectedProviderNeedsLocalSettings ? modelID : nil,
      ragMode: selectedRAGMode,
      searchSettings: currentSearchSettings)
    if let index = ragEvaluationProfiles.firstIndex(where: { $0.environment == environment }) {
      ragEvaluationProfiles[index].isSelected = true
    } else {
      let modelLabel = environment.modelID.flatMap { $0.isEmpty ? nil : $0 }
        ?? environment.providerName
      ragEvaluationProfiles.append(RAGEvaluationProfile(
        name: "\(modelLabel)・上位\(environment.searchSettings.limit)件",
        environment: environment))
    }
    saveRAGEvaluationProfiles()
  }

  @MainActor private func updateRAGEvaluationProfile(_ profile: RAGEvaluationProfile) {
    guard let index = ragEvaluationProfiles.firstIndex(where: { $0.id == profile.id }) else {
      return
    }
    ragEvaluationProfiles[index] = profile
    saveRAGEvaluationProfiles()
  }

  @MainActor private func deleteRAGEvaluationProfile(_ profile: RAGEvaluationProfile) {
    ragEvaluationProfiles.removeAll { $0.id == profile.id }
    saveRAGEvaluationProfiles()
  }

  @MainActor private func saveRAGEvaluationCases() {
    do {
      try FileManager.default.createDirectory(
        at: ragEvaluationStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      ragEvaluationCases.sort { $0.createdAt > $1.createdAt }
      let data = try JSONEncoder().encode(ragEvaluationCases)
      try data.write(to: ragEvaluationStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func addRAGEvaluationCase(from history: KnowledgeSelectionHistory) {
    let expectedIDs = history.matches.map(\.id)
    guard !ragEvaluationCases.contains(where: {
      $0.question == history.query && $0.expectedMatches.map(\.id) == expectedIDs
    }) else {
      showingKnowledgeSelectionHistory = false
      showingRAGEvaluation = true
      return
    }
    let evaluationCase = RAGEvaluationCase(
      question: history.query, expectedMatches: history.matches)
    ragEvaluationCases.insert(evaluationCase, at: 0)
    if let suiteIndex = ragEvaluationSuites.firstIndex(where: {
      $0.id.uuidString == selectedRAGEvaluationSuiteID
    }) {
      ragEvaluationSuites[suiteIndex].caseIDs.append(evaluationCase.id)
      saveRAGEvaluationSuites()
    }
    saveRAGEvaluationCases()
    showingKnowledgeSelectionHistory = false
    showingRAGEvaluation = true
  }

  @MainActor private func deleteRAGEvaluationCase(_ evaluationCase: RAGEvaluationCase) {
    ragEvaluationCases.removeAll { $0.id == evaluationCase.id }
    for index in ragEvaluationSuites.indices {
      ragEvaluationSuites[index].caseIDs.removeAll { $0 == evaluationCase.id }
    }
    saveRAGEvaluationSuites()
    saveRAGEvaluationCases()
  }

  @MainActor private func duplicateRAGEvaluationCase(_ evaluationCase: RAGEvaluationCase) {
    let duplicate = RAGEvaluationCase(
      question: "\(evaluationCase.question)（コピー）",
      expectedMatches: evaluationCase.expectedMatches,
      expectedSearch: evaluationCase.expectedSearch,
      criteria: evaluationCase.criteria,
      expectedAnswerPoints: evaluationCase.expectedAnswerPoints,
      forbiddenAnswerPhrases: evaluationCase.forbiddenAnswerPhrases,
      tags: evaluationCase.tags)
    ragEvaluationCases.insert(duplicate, at: 0)
    if let index = ragEvaluationSuites.firstIndex(where: {
      $0.id.uuidString == selectedRAGEvaluationSuiteID
    }) {
      ragEvaluationSuites[index].caseIDs.append(duplicate.id)
      saveRAGEvaluationSuites()
    }
    saveRAGEvaluationCases()
  }

  @MainActor private func generateRAGEvaluationCandidates(
    for document: KnowledgeDocumentSummary
  ) async -> [RAGEvaluationGeneratedCandidate] {
    do {
      var request = URLRequest(
        url: OnigiriEndpoint.url("knowledge/documents/\(document.id.uuidString)/chunks"))
      request.timeoutInterval = 10
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      let chunks = try JSONDecoder().decode(KnowledgeChunksResponse.self, from: data).chunks
      let existingChunkIDs = Set(ragEvaluationCases.flatMap { $0.expectedMatches.map(\.id) })
      errorMessage = nil
      return chunks.filter { !existingChunkIDs.contains($0.id) }.map { chunk in
        let topics = chunk.keywords.compactMap(Self.cleanCandidateKeyword).prefix(3)
        let topic = topics.joined(separator: "・")
        let title = (chunk.title as NSString).deletingPathExtension
        let question = topic.isEmpty
          ? "「\(title)」のチャンク #\(chunk.chunkIndex) の要点を説明してください。"
          : "「\(title)」のチャンク #\(chunk.chunkIndex) を、キーワード「\(topic)」を含めて要約してください。"
        let point = Self.expectedPointCandidate(from: chunk.text)
        return RAGEvaluationGeneratedCandidate(
          question: question,
          expectedMatch: KnowledgeChunkMatch(
            documentID: chunk.documentID, title: chunk.title, chunkIndex: chunk.chunkIndex,
            score: 0, citationIndex: 1, text: chunk.text, searchMode: "generated"),
          expectedAnswerPoint: point)
      }
    } catch {
      errorMessage = error.localizedDescription
      return []
    }
  }

  private static func expectedPointCandidate(from text: String) -> String {
    let cleaned = text.replacingOccurrences(
      of: #"(?:\d+\s*時間\s*)?(?:\d+\s*分\s*)?\d+\s*秒\s*|(?:\d{1,2}:){1,2}\d{2}(?:\.\d+)?\s*"#,
      with: " ",
      options: .regularExpression)
    let candidates = cleaned.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { candidate in
        candidate.count >= 15
          && !["はい", "えっと", "皆さんこんにちは"].contains(where: candidate.hasPrefix)
      }
    let best = candidates.max { lhs, rhs in
      min(lhs.count, 180) < min(rhs.count, 180)
    }
    return String((best ?? cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
      .prefix(180))
  }

  private static func cleanCandidateKeyword(_ keyword: String) -> String? {
    let cleaned = keyword.replacingOccurrences(
      of: #"^(?:秒|分|時間)+"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count >= 4, !["youtube", "ライブ"].contains(cleaned.lowercased()) else {
      return nil
    }
    return cleaned
  }

  @MainActor private func addGeneratedRAGEvaluationCandidates(
    _ candidates: [RAGEvaluationGeneratedCandidate]
  ) {
    guard !candidates.isEmpty else { return }
    let newCases = candidates.map { candidate in
      RAGEvaluationCase(
        question: candidate.question, expectedMatches: [candidate.expectedMatch],
        expectedAnswerPoints: candidate.expectedAnswerPoint.isEmpty
          ? [] : [candidate.expectedAnswerPoint],
        tags: ["自動生成", candidate.expectedMatch.title])
    }
    ragEvaluationCases.insert(contentsOf: newCases, at: 0)
    if let suiteIndex = ragEvaluationSuites.firstIndex(where: {
      $0.id.uuidString == selectedRAGEvaluationSuiteID
    }) {
      ragEvaluationSuites[suiteIndex].caseIDs.append(contentsOf: newCases.map(\.id))
      saveRAGEvaluationSuites()
    }
    saveRAGEvaluationCases()
  }

  @MainActor private func importRAGEvaluationCases(
    _ importedCases: [RAGEvaluationCase]
  ) -> RAGEvaluationImportSummary {
    let documentIDs = Set(knowledgeDocuments.map(\.id))
    let validCases = importedCases.filter { evaluationCase in
      (!evaluationCase.expectedSearch || !evaluationCase.expectedMatches.isEmpty)
        && evaluationCase.expectedMatches.allSatisfy { documentIDs.contains($0.documentID) }
    }
    for importedCase in validCases {
      if let index = ragEvaluationCases.firstIndex(where: {
        $0.id == importedCase.id
          || ($0.question == importedCase.question
            && $0.expectedMatches.map(\.id) == importedCase.expectedMatches.map(\.id))
      }) {
        ragEvaluationCases[index] = importedCase
      } else {
        ragEvaluationCases.append(importedCase)
      }
    }
    saveRAGEvaluationCases()
    return RAGEvaluationImportSummary(
      importedCount: validCases.count,
      skippedCount: importedCases.count - validCases.count)
  }

  @MainActor private func updateRAGEvaluationCriteria(
    _ evaluationCase: RAGEvaluationCase, criteria: RAGEvaluationCriteria
  ) {
    guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
      return
    }
    ragEvaluationCases[index].criteria = criteria
    saveRAGEvaluationCases()
  }

  @MainActor private func updateRAGEvaluationSearchExpectation(
    _ evaluationCase: RAGEvaluationCase, expectedSearch: Bool
  ) {
    guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
      return
    }
    ragEvaluationCases[index].expectedSearch = expectedSearch
    saveRAGEvaluationCases()
  }

  @MainActor private func addNoSearchRAGEvaluationCase(question: String) {
    let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let evaluationCase = RAGEvaluationCase(
      question: trimmed, expectedMatches: [], expectedSearch: false,
      criteria: .default, tags: ["検索不要"])
    ragEvaluationCases.insert(evaluationCase, at: 0)
    if let index = ragEvaluationSuites.firstIndex(where: {
      $0.id.uuidString == selectedRAGEvaluationSuiteID
    }) {
      ragEvaluationSuites[index].caseIDs.append(evaluationCase.id)
      saveRAGEvaluationSuites()
    }
    saveRAGEvaluationCases()
  }

  @MainActor private func updateRAGEvaluationAnswerRules(
    _ evaluationCase: RAGEvaluationCase,
    expectedPoints: [String], forbiddenPhrases: [String]
  ) {
    guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
      return
    }
    ragEvaluationCases[index].expectedAnswerPoints = expectedPoints
    ragEvaluationCases[index].forbiddenAnswerPhrases = forbiddenPhrases
    saveRAGEvaluationCases()
  }

  @MainActor private func updateRAGEvaluationTags(
    _ evaluationCase: RAGEvaluationCase, tags: [String]
  ) {
    guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
      return
    }
    ragEvaluationCases[index].tags = tags
    saveRAGEvaluationCases()
  }

  @MainActor private func suggestRAGEvaluationAnswerPoints(
    _ evaluationCase: RAGEvaluationCase
  ) {
    guard let answer = evaluationCase.runs.first?.result.answer else { return }
    var seen = Set(evaluationCase.expectedAnswerPoints)
    let candidates = answer.components(separatedBy: CharacterSet(charactersIn: "。！？\n"))
      .map {
        $0.replacingOccurrences(of: #"\s*\[\d+\]"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }
      .filter { $0.count >= 6 && seen.insert($0).inserted }
      .prefix(5)
    updateRAGEvaluationAnswerRules(
      evaluationCase,
      expectedPoints: evaluationCase.expectedAnswerPoints + Array(candidates),
      forbiddenPhrases: evaluationCase.forbiddenAnswerPhrases)
  }

  @MainActor private func setRAGEvaluationBaseline(
    _ evaluationCase: RAGEvaluationCase, run: RAGEvaluationRun
  ) {
    guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
      return
    }
    ragEvaluationCases[index].baselineRunID =
      ragEvaluationCases[index].baselineRunID == run.id ? nil : run.id
    saveRAGEvaluationCases()
  }

  @MainActor private func discardInvalidRAGEvaluationCases() {
    let documentIDs = Set(knowledgeDocuments.map(\.id))
    let remaining = ragEvaluationCases.filter { evaluationCase in
      (!evaluationCase.expectedSearch || !evaluationCase.expectedMatches.isEmpty)
        && evaluationCase.expectedMatches.allSatisfy { documentIDs.contains($0.documentID) }
    }
    guard remaining != ragEvaluationCases else { return }
    ragEvaluationCases = remaining
    saveRAGEvaluationCases()
    pruneRAGEvaluationSuites()
  }

  @MainActor private func runRAGEvaluation(
    _ evaluationCase: RAGEvaluationCase,
    environmentOverride: RAGEvaluationEnvironment? = nil
  ) async -> RAGEvaluationRun? {
    guard !runningRAGEvaluationCaseIDs.contains(evaluationCase.id) else { return nil }
    runningRAGEvaluationCaseIDs.insert(evaluationCase.id)
    errorMessage = nil
    defer { runningRAGEvaluationCaseIDs.remove(evaluationCase.id) }
    let evaluationSearchSettings = environmentOverride?.searchSettings ?? currentSearchSettings
    let evaluationProviderID = environmentOverride?.providerID ?? selectedProviderID
    let evaluationRAGMode = environmentOverride?.ragMode ?? selectedRAGMode
    let evaluationBaseURL = environmentOverride == nil
      ? (selectedProviderUsesBaseURL ? baseURL : nil)
      : environmentOverride?.baseURL

    do {
      var request = URLRequest(url: OnigiriEndpoint.url("evaluation/run"))
      request.httpMethod = "POST"
      request.timeoutInterval = 180
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(
        RAGEvaluationRequest(
          question: evaluationCase.question,
          expectedChunkIDs: evaluationCase.expectedMatches.map(\.id),
          ragMode: evaluationRAGMode,
          expectedSearch: evaluationCase.expectedSearch,
          searchSettings: evaluationSearchSettings,
          expectedAnswerPoints: evaluationCase.expectedAnswerPoints,
          forbiddenAnswerPhrases: evaluationCase.forbiddenAnswerPhrases))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "RAG評価を実行できませんでした。")
      }
      let result = try JSONDecoder().decode(RAGEvaluationResponse.self, from: data)
      guard let index = ragEvaluationCases.firstIndex(where: { $0.id == evaluationCase.id }) else {
        return nil
      }
      let environment = RAGEvaluationEnvironment(
        providerID: evaluationProviderID,
        providerName: result.providerName,
        baseURL: evaluationBaseURL,
        modelID: result.modelID,
        ragMode: evaluationRAGMode,
        searchSettings: evaluationSearchSettings)
      let evaluationRun = RAGEvaluationRun(result: result, environment: environment)
      ragEvaluationCases[index].runs.insert(evaluationRun, at: 0)
      let baselineRunID = ragEvaluationCases[index].baselineRunID
      let recentRuns = Array(ragEvaluationCases[index].runs.prefix(30))
      if let baselineRunID,
        !recentRuns.contains(where: { $0.id == baselineRunID }),
        let baseline = ragEvaluationCases[index].runs.first(where: { $0.id == baselineRunID })
      {
        ragEvaluationCases[index].runs = Array(recentRuns.prefix(29)) + [baseline]
      } else {
        ragEvaluationCases[index].runs = recentRuns
      }
      saveRAGEvaluationCases()
      return evaluationRun
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @MainActor private func runAllRAGEvaluations() async {
    let caseIDs = scopedRAGEvaluationCases.map(\.id)
    for caseID in caseIDs {
      guard let evaluationCase = ragEvaluationCases.first(where: { $0.id == caseID }) else {
        continue
      }
      _ = await runRAGEvaluation(evaluationCase)
    }
  }

  @MainActor private func runRAGEvaluationMatrix(
    trigger: RAGEvaluationTrigger = .manual
  ) async {
    let selectedProfiles = ragEvaluationProfiles.filter(\.isSelected)
    guard !selectedProfiles.isEmpty, !scopedRAGEvaluationCases.isEmpty,
      !runningRAGEvaluationMatrix else { return }
    runningRAGEvaluationMatrix = true
    errorMessage = nil
    let originalEnvironment = RAGEvaluationEnvironment(
      providerID: selectedProviderID, providerName: providerName,
      baseURL: selectedProviderUsesBaseURL ? baseURL : nil,
      modelID: selectedProviderNeedsLocalSettings ? modelID : nil,
      ragMode: selectedRAGMode,
      searchSettings: currentSearchSettings)
    let reportStartedAt = Date()
    var reportEntries: [RAGEvaluationReportEntry] = []
    defer { runningRAGEvaluationMatrix = false }

    do {
      for (profileIndex, profile) in selectedProfiles.enumerated() {
        ragEvaluationMatrixProgress =
          "\(profileIndex + 1)/\(selectedProfiles.count)環境: \(profile.name)"
        try await configureEvaluationProvider(profile.environment)
        let caseIDs = scopedRAGEvaluationCases.map(\.id)
        for caseID in caseIDs {
          guard let evaluationCase = ragEvaluationCases.first(where: { $0.id == caseID }) else {
            continue
          }
          if let evaluationRun = await runRAGEvaluation(
            evaluationCase, environmentOverride: profile.environment)
          {
            reportEntries.append(RAGEvaluationReportEntry(
              profileID: profile.id, profileName: profile.name,
              caseID: evaluationCase.id, question: evaluationCase.question,
              createdAt: evaluationRun.createdAt,
              searchSettings: profile.environment.searchSettings,
              criteria: evaluationCase.criteria, result: evaluationRun.result))
          }
        }
      }
      if !reportEntries.isEmpty {
        let previousReport = ragEvaluationReports.first
        let report = RAGEvaluationReport(
          createdAt: reportStartedAt, trigger: trigger,
          suiteName: selectedRAGEvaluationSuite?.name,
          knowledgeSnapshot: RAGEvaluationKnowledgeSnapshot(
            status: knowledgeStatus,
            chunkingSettings: KnowledgeChunkingSettings(
              maxCharacters: chunkMaxCharacters,
              overlapCharacters: chunkOverlapCharacters),
            documents: knowledgeDocuments),
          entries: reportEntries)
        ragEvaluationReports.insert(report, at: 0)
        saveRAGEvaluationReports()
        if trigger == .scheduled, ragEvaluationAutomationSettings.notifyOnRegression,
          let previousReport
        {
          let regressions = report.regressions(comparedTo: previousReport)
          if !regressions.isEmpty { sendRAGEvaluationRegressionNotification(regressions) }
        }
      }
      ragEvaluationMatrixProgress = "モデルマトリクス評価が完了しました。"
    } catch {
      ragEvaluationMatrixProgress = "モデルマトリクス評価を中断しました。"
      errorMessage = error.localizedDescription
    }

    do {
      try await configureEvaluationProvider(originalEnvironment)
    } catch {
      errorMessage = "元のモデルへ戻せませんでした: \(error.localizedDescription)"
    }
    _ = await checkHealth()
  }

  private func sendRAGEvaluationRegressionNotification(
    _ regressions: [RAGEvaluationReportRegression]
  ) {
    let content = UNMutableNotificationContent()
    content.title = "Onigiri Harness: RAG評価の回帰"
    content.body = regressions.count == 1
      ? "\(regressions[0].question): \(regressions[0].detail)"
      : "\(regressions.count)件のケースで品質または速度が低下しました。"
    content.sound = .default
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  @MainActor private func configureEvaluationProvider(
    _ environment: RAGEvaluationEnvironment
  ) async throws {
    var request = URLRequest(url: OnigiriEndpoint.url("provider"))
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(ProviderConfig(
      providerID: environment.providerID,
      baseURL: environment.baseURL,
      modelID: environment.modelID))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let apiError = try? JSONDecoder().decode(APIError.self, from: data)
      throw StreamError(message: apiError?.error ?? "評価環境へ切り替えられませんでした。")
    }
  }

  @MainActor private func recordSearchFeedback(
    match: KnowledgeChunkMatch, rating: KnowledgeSearchFeedback.Rating
  ) {
    do {
      let existing: [KnowledgeSearchFeedback]
      if let data = try? Data(contentsOf: searchFeedbackStoreURL) {
        existing = (try? JSONDecoder().decode([KnowledgeSearchFeedback].self, from: data)) ?? []
      } else {
        existing = []
      }
      let feedback = KnowledgeSearchFeedback(
        query: knowledgeSearchQuery,
        rating: rating,
        settings: currentSearchSettings,
        match: match
      )
      try FileManager.default.createDirectory(
        at: searchFeedbackStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(existing + [feedback])
      try data.write(to: searchFeedbackStoreURL, options: .atomic)
      searchFeedbackEntries = existing + [feedback]
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func saveSearchFeedbackEntries(_ entries: [KnowledgeSearchFeedback]) {
    do {
      try FileManager.default.createDirectory(
        at: searchFeedbackStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(entries)
      try data.write(to: searchFeedbackStoreURL, options: .atomic)
      searchFeedbackEntries = entries.sorted { $0.createdAt > $1.createdAt }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadSearchFeedback() {
    do {
      let data = try Data(contentsOf: searchFeedbackStoreURL)
      searchFeedbackEntries = try JSONDecoder().decode([KnowledgeSearchFeedback].self, from: data)
        .sorted { $0.createdAt > $1.createdAt }
    } catch {
      searchFeedbackEntries = []
    }
  }

  @MainActor private func deleteSearchFeedback(_ feedback: KnowledgeSearchFeedback) {
    deleteSearchFeedbackEntries([feedback])
  }

  @MainActor private func deleteSearchFeedbackEntries(_ entries: [KnowledgeSearchFeedback]) {
    let deletedIDs = Set(entries.map(\.id))
    let remaining = searchFeedbackEntries.filter { !deletedIDs.contains($0.id) }
    saveSearchFeedbackEntries(remaining)
  }

  @MainActor private func applySearchSettings(_ settings: KnowledgeSearchSettings) {
    applySearchSettings(settings, showSettings: true)
  }

  @MainActor private func applySearchSettings(
    _ settings: KnowledgeSearchSettings, showSettings: Bool
  ) {
    searchLimit = settings.limit
    searchMinScore = settings.minScore
    searchKeywordWeight = settings.keywordWeight
    searchEmbeddingWeight = settings.embeddingWeight
    showingSearchFeedbackLog = false
    showingSearchSettings = showSettings
  }

  @MainActor private func loadSearchPresets() {
    do {
      let data = try Data(contentsOf: searchPresetsStoreURL)
      customSearchPresets = try JSONDecoder().decode([SearchPreset].self, from: data)
    } catch {
      customSearchPresets = []
    }
  }

  @MainActor private func saveSearchPresets() {
    do {
      try FileManager.default.createDirectory(
        at: searchPresetsStoreURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(customSearchPresets)
      try data.write(to: searchPresetsStoreURL, options: .atomic)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func saveSearchPreset(named rawName: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let preset = SearchPreset(name: name, settings: currentSearchSettings)
    customSearchPresets.removeAll { $0.name == name }
    customSearchPresets.append(preset)
    customSearchPresets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    saveSearchPresets()
  }

  @MainActor private func deleteSearchPreset(_ preset: SearchPreset) {
    guard !preset.isBuiltIn else { return }
    customSearchPresets.removeAll { $0.id == preset.id }
    saveSearchPresets()
  }

  @MainActor private func updateSelectedConversation(
    _ update: (inout StoredConversation) -> Void
  ) {
    guard let id = selectedConversationID else { return }
    updateConversation(id: id, update)
  }

  @MainActor private func updateConversation(
    id: UUID, select: Bool = true, _ update: (inout StoredConversation) -> Void
  ) {
    guard let index = conversations.firstIndex(where: { $0.id == id })
    else { return }
    update(&conversations[index])
    conversations[index].updatedAt = Date()
    conversations.sort { $0.updatedAt > $1.updatedAt }
    if select {
      selectedConversationID = id
    }
    saveConversations()
  }

  @MainActor private func appendMessage(_ message: DisplayMessage, to conversationID: UUID) {
    updateConversation(id: conversationID, select: false) { conversation in
      conversation.messages.append(message)
      if conversation.title == "新しい会話", message.role == .user {
        conversation.title = Self.conversationTitle(from: message.content)
      }
    }
  }

  @MainActor private func updateMessage(
    conversationID: UUID, messageID: UUID, content: String
  ) {
    updateConversation(id: conversationID, select: false) { conversation in
      if let index = conversation.messages.firstIndex(where: { $0.id == messageID }) {
        conversation.messages[index].content = content
      }
    }
  }

  @MainActor private func updateMessage(
    conversationID: UUID, messageID: UUID, ragTrace: AgenticRAGTrace
  ) {
    updateConversation(id: conversationID, select: false) { conversation in
      if let index = conversation.messages.firstIndex(where: { $0.id == messageID }) {
        conversation.messages[index].ragTrace = ragTrace
        conversation.messages[index].citations = ragTrace.matches
      }
    }
  }

  @MainActor private func removeTrailingEmptyAssistantMessage(from conversationID: UUID) {
    updateConversation(id: conversationID, select: false) { conversation in
      if conversation.messages.last?.role == .assistant,
        conversation.messages.last?.content.isEmpty == true
      {
        conversation.messages.removeLast()
      }
    }
  }

  @MainActor private func clearSelectedConversationCitations() {
    updateSelectedConversation { conversation in
      for index in conversation.messages.indices {
        conversation.messages[index].citations = []
        conversation.messages[index].ragTrace = nil
      }
    }
  }

  @MainActor private func exportConversationMarkdown(_ conversation: StoredConversation) {
    do {
      let data = Data(Self.markdown(for: conversation).utf8)
      let filename = "\(Self.safeFilename(conversation.title)).md"
      let panel = NSSavePanel()
      panel.nameFieldStringValue = filename
      panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
      guard panel.runModal() == .OK, let url = panel.url else { return }
      try data.write(to: url, options: .atomic)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private static func markdown(for conversation: StoredConversation) -> String {
    var lines: [String] = []
    lines.append("# \(conversation.title)")
    lines.append("")
    lines.append("- 更新日: \(conversation.updatedAt.formatted(date: .numeric, time: .shortened))")
    lines.append("- メッセージ数: \(conversation.messages.count)")
    lines.append("")

    for message in conversation.messages {
      lines.append("## \(message.role == .user ? "あなた" : "Onigiri")")
      lines.append("")
      if let ragMode = message.ragMode {
        lines.append("- RAGモード: \(ragMode.rawValue)")
        if let trace = message.ragTrace {
          lines.append("- Agentic判断: \(trace.decision.rawValue)")
          lines.append("- 判断理由: \(trace.reason)")
          lines.append("- 検索語: \(trace.queries.isEmpty ? "なし" : trace.queries.joined(separator: " → "))")
          lines.append("- Tool実行: \(trace.toolCallCount)回 / \(trace.elapsedMilliseconds)ms")
          if trace.usedFallback { lines.append("- フォールバック: always") }
        }
        lines.append("")
      }
      lines.append(message.content.isEmpty ? "_空のメッセージ_" : message.content)
      lines.append("")
      if !message.citations.isEmpty {
        lines.append("### 引用")
        lines.append("")
        for citation in message.citations {
          lines.append(
            "- [\(citation.citationIndex)] \(citation.title) #\(citation.chunkIndex) score \(citation.score) / \(citation.searchMode)"
          )
        }
        lines.append("")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func safeFilename(_ rawName: String) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = trimmed.isEmpty ? "Onigiri Chat" : trimmed
    let invalid = CharacterSet(charactersIn: #"/\?%*|"<>:"#)
    let sanitized = fallback.components(separatedBy: invalid).joined(separator: "-")
    return String(sanitized.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @MainActor private func deleteConversations(at offsets: IndexSet) {
    let deletedIDs = offsets.map { conversations[$0].id }
    conversations.remove(atOffsets: offsets)
    if conversations.isEmpty {
      var conversation = StoredConversation.empty
      conversation.profileID = defaultProductProfileID ?? productProfiles.first?.id
      conversations = [conversation]
    }
    if let selectedConversationID, deletedIDs.contains(selectedConversationID) {
      self.selectedConversationID = conversations.first?.id
    }
    saveConversations()
  }

  @MainActor private func deleteSelectedConversation() {
    guard let selectedConversationID,
      let index = conversations.firstIndex(where: { $0.id == selectedConversationID })
    else { return }
    deleteConversations(at: IndexSet(integer: index))
  }

  private static func conversationTitle(from text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "新しい会話" }
    return String(trimmed.prefix(28))
  }

  private var knowledgeSettings: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label(knowledgeStatusLabel, systemImage: "doc.text.magnifyingglass")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)

        TextField("RAG検索", text: $quickKnowledgeSearchQuery)
          .textFieldStyle(.roundedBorder)
          .frame(width: 220)
          .onSubmit {
            Task { await searchKnowledgeFromToolbar() }
          }
          .disabled(busy || knowledgeStatus.chunkCount == 0)

        Button("検索", systemImage: "magnifyingglass") {
          Task { await searchKnowledgeFromToolbar() }
        }
        .disabled(busy || knowledgeStatus.chunkCount == 0)

        Button("Webリサーチ", systemImage: "safari") {
          showingWebResearch = true
        }
        .disabled(busy)

        Button("AIタスク", systemImage: "terminal") {
          showingCodexTasks = true
          Task { await loadCodexTasks() }
        }
        .disabled(busy)

        Button("MCP", systemImage: "point.3.connected.trianglepath.dotted") {
          showingMCPAudit = true
          Task { await loadKnowledgeToolAudit() }
        }
        .disabled(busy)

        Button("Decision Lab", systemImage: "switch.2") {
          showingDecisionLab = true
          Task { await loadDecisionRuns() }
        }
        .disabled(busy)

        Button("データ管理", systemImage: "externaldrive.badge.timemachine") {
          showingDataManagement = true
        }
        .disabled(busy)
      }
      .controlSize(.small)

      GeometryReader { viewport in
        ScrollViewReader { scrollProxy in
          ZStack {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) {
                Button("資料一覧", systemImage: "list.bullet.rectangle") {
                  Task {
                    await loadKnowledgeDocuments()
                    showingKnowledgeDocuments = true
                  }
                }
                .disabled(busy || knowledgeStatus.documentCount == 0)
                .id("knowledgeButtonsStart")

                Button("関連チャンク", systemImage: "quote.bubble") {
                  Task { await searchKnowledgeForCurrentText() }
                }
                .disabled(busy || knowledgeStatus.chunkCount == 0)

                Button("検索設定", systemImage: "slider.horizontal.3") {
                  showingSearchSettings = true
                }
                .disabled(busy)

                Button("分割設定", systemImage: "square.grid.2x2") {
                  showingChunkingSettings = true
                }
                .disabled(busy)

                Button("評価ログ", systemImage: "list.clipboard") {
                  loadSearchFeedback()
                  showingSearchFeedbackLog = true
                }
                .disabled(busy)

                Button("選択履歴", systemImage: "clock.arrow.circlepath") {
                  showingKnowledgeSelectionHistory = true
                }
                .disabled(busy || knowledgeSelectionHistory.isEmpty)

                Button("RAG評価", systemImage: "chart.bar.xaxis") {
                  showingRAGEvaluation = true
                }
                .disabled(busy || (ragEvaluationCases.isEmpty && knowledgeDocuments.isEmpty))

                Button("埋め込み更新", systemImage: "sparkle.magnifyingglass") {
                  Task { await refreshKnowledgeEmbeddings() }
                }
                .disabled(busy || knowledgeStatus.chunkCount == 0)

                Button("資料追加", systemImage: "doc.badge.plus") {
                  showingKnowledgeImporter = true
                }
                .disabled(busy)

                Button("資料クリア", systemImage: "trash") {
                  Task { await clearKnowledge() }
                }
                .disabled(busy || knowledgeStatus.chunkCount == 0)
                .id("knowledgeButtonsEnd")
              }
              .fixedSize(horizontal: true, vertical: false)
              .buttonStyle(.bordered)
              .controlSize(.small)
            }
            .frame(width: viewport.size.width, alignment: .leading)
            .onScrollGeometryChange(for: KnowledgeButtonsScrollVisibility.self) { geometry in
              // Use the scroll view's actual visible rectangle; a child view's
              // frame can remain unchanged while the native scroll view scrolls.
              let visible = geometry.visibleRect
              let tolerance: CGFloat = 1
              return KnowledgeButtonsScrollVisibility(
                leading: visible.minX > tolerance,
                trailing: geometry.contentSize.width - visible.maxX > tolerance
              )
            } action: { _, visibility in
              knowledgeButtonsScrollVisibility = visibility
            }
            .clipped()

            knowledgeButtonsScrollCue(edge: .leading, visible: knowledgeButtonsScrollVisibility.leading) {
              withAnimation { scrollProxy.scrollTo("knowledgeButtonsStart", anchor: .leading) }
            }
            knowledgeButtonsScrollCue(edge: .trailing, visible: knowledgeButtonsScrollVisibility.trailing) {
              withAnimation { scrollProxy.scrollTo("knowledgeButtonsEnd", anchor: .trailing) }
            }
          }
        }
      }
      .frame(height: 28)
    }
  }

  private var knowledgeStatusLabel: String {
    if locale.identifier.lowercased().hasPrefix("en") {
      return "\(knowledgeStatus.documentCount) documents / \(knowledgeStatus.chunkCount) chunks / \(knowledgeStatus.embeddedChunkCount) embedded"
    }
    return "資料 \(knowledgeStatus.documentCount)件 / \(knowledgeStatus.chunkCount)チャンク / 埋め込み \(knowledgeStatus.embeddedChunkCount)"
  }

  private func knowledgeButtonsScrollCue(
    edge: HorizontalEdge, visible: Bool, action: @escaping () -> Void
  ) -> some View {
    HStack {
      if edge == .trailing { Spacer() }
      if visible {
        LinearGradient(
          colors: [
            Color(NSColor.windowBackgroundColor).opacity(0), Color(NSColor.windowBackgroundColor),
          ],
          startPoint: edge == .leading ? .trailing : .leading,
          endPoint: edge == .leading ? .leading : .trailing
        )
        .frame(width: 42)
        .overlay {
          Button(action: action) {
            Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 24, height: 28)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            Text(
              LocalizedStringKey(
                edge == .leading ? "左の隠れたボタンを表示" : "右の隠れたボタンを表示")))
          .frame(maxWidth: .infinity, alignment: edge == .leading ? .leading : .trailing)
        }
        .transition(.opacity)
      }
      if edge == .leading { Spacer() }
    }
  }

  @MainActor private func waitForServer() async {
    NotificationCenter.default.post(name: .ensureOnigiriServer, object: nil)
    for _ in 0..<20 {
      if await checkHealth() { return }
      try? await Task.sleep(for: .milliseconds(200))
    }
  }

  @MainActor private func checkHealth() async -> Bool {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("health"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      let health = try JSONDecoder().decode(ServiceStatus.self, from: data)
      guard health.serverVersion == OnigiriServerProtocol.version else {
        available = false
        providerName = "OnigiriServer"
        status = "古い OnigiriServer に接続しています。起動中の Onigiri をすべて終了してから、修正版アプリを開き直してください。"
        return false
      }
      available = health.available
      providerName = health.providerName
      status = health.detail
      return true
    } catch {
      available = false
      providerName = "OnigiriServer"
      status = "サーバーに接続できません。OnigiriServer を起動して再確認してください。使用ポート: \(OnigiriEndpoint.port)"
      return false
    }
  }

  @MainActor private func loadProviders() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("providers"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      let providers = try JSONDecoder().decode(ProviderOptionsResponse.self, from: data)
      providerOptions = providers.options
      if baseURL.isEmpty {
        baseURL =
          providers.current.baseURL ?? providerOptions.first(where: { $0.id == selectedProviderID }
          )?.defaultBaseURL ?? ""
      }
      if modelID.isEmpty {
        modelID = providers.current.modelID ?? ""
      }
    } catch {
      if providerOptions.isEmpty {
        providerOptions = [
          ProviderOption(id: "apple-foundation-models", name: "Apple Foundation Models")
        ]
      }
    }
  }

  @MainActor private func applyProvider(clearChat: Bool) async {
    busy = true
    errorMessage = nil
    defer { busy = false }

    do {
      var request = URLRequest(url: OnigiriEndpoint.url("provider"))
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let config = ProviderConfig(
        providerID: selectedProviderID,
        baseURL: selectedProviderUsesBaseURL ? baseURL : nil,
        modelID: selectedProviderNeedsLocalSettings ? modelID : nil
      )
      request.httpBody = try JSONEncoder().encode(config)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "Provider の切り替えに失敗しました。")
      }
      let applied = try JSONDecoder().decode(ProviderConfig.self, from: data)
      selectedProviderID = applied.providerID
      baseURL = applied.baseURL ?? ""
      modelID = applied.modelID ?? ""
      if clearChat {
        var conversation = StoredConversation.empty
        conversation.profileID = selectedProductProfileID ?? defaultProductProfileID
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        saveConversations()
        modelIDs = []
      }
      _ = await checkHealth()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadModels(applyFirst: Bool) async {
    guard selectedProviderNeedsLocalSettings else { return }
    do {
      // Applying a temporary provider selection must not create a new
      // conversation. A new conversation reactivates its assigned Profile and
      // can reset the picker while the server remains on the selected provider.
      if applyFirst { await applyProvider(clearChat: false) }
      var request = URLRequest(url: OnigiriEndpoint.url("models"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      modelIDs = try JSONDecoder().decode(ModelListResponse.self, from: data).models
      if modelID.isEmpty, let first = modelIDs.first { modelID = first }
    } catch {
      errorMessage = error.localizedDescription
      modelIDs = []
    }
  }

  @MainActor private func loadKnowledgeStatus() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeStatus = try JSONDecoder().decode(KnowledgeStatus.self, from: data)
      await loadKnowledgeDocuments()
    } catch {
      knowledgeStatus = KnowledgeStatus(documentCount: 0, chunkCount: 0)
      knowledgeDocuments = []
    }
  }

  @MainActor private func loadKnowledgeChunkingSettings() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/chunking"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      let decoded = try JSONDecoder().decode(KnowledgeChunkingSettingsResponse.self, from: data)
      chunkMaxCharacters = decoded.settings.maxCharacters
      chunkOverlapCharacters = decoded.settings.overlapCharacters
      knowledgeStatus = decoded.status
    } catch {
      // Keep local defaults if the server is not ready yet.
    }
  }

  @MainActor private func applyKnowledgeChunkingSettings() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/chunking"))
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(
        KnowledgeChunkingSettings(
          maxCharacters: chunkMaxCharacters,
          overlapCharacters: chunkOverlapCharacters
        ))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "分割設定の更新に失敗しました。")
      }
      let decoded = try JSONDecoder().decode(KnowledgeChunkingSettingsResponse.self, from: data)
      chunkMaxCharacters = decoded.settings.maxCharacters
      chunkOverlapCharacters = decoded.settings.overlapCharacters
      knowledgeStatus = decoded.status
      knowledgeSearchPresentation = nil
      queuedKnowledgeMatches = []
      knowledgeSelectionHistory = []
      saveKnowledgeSelectionHistory()
      ragEvaluationCases = []
      saveRAGEvaluationCases()
      pruneRAGEvaluationSuites()
      selectedKnowledgeChunks = nil
      await loadKnowledgeDocuments()
      showingChunkingSettings = false
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadKnowledgeDocuments() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/documents"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeDocuments = try JSONDecoder().decode(KnowledgeDocumentsResponse.self, from: data)
        .documents
      discardInvalidKnowledgeSelectionHistory()
      discardInvalidRAGEvaluationCases()
    } catch {
      knowledgeDocuments = []
    }
  }

  @MainActor private func loadKnowledgeChunks(for document: KnowledgeDocumentSummary) async {
    do {
      var request = URLRequest(
        url: OnigiriEndpoint.url("knowledge/documents/\(document.id.uuidString)/chunks"))
      request.timeoutInterval = 10
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      selectedKnowledgeChunks = try JSONDecoder().decode(KnowledgeChunksResponse.self, from: data)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func importKnowledge(_ result: Result<[URL], Error>) async {
    busy = true
    errorMessage = nil
    defer { busy = false }

    do {
      let roots = try result.get()
      guard !roots.isEmpty else { return }
      var importedCount = 0
      var failures: [KnowledgeImportFailure] = []
      for root in roots {
        let didStartAccessing = root.startAccessingSecurityScopedResource()
        defer {
          if didStartAccessing { root.stopAccessingSecurityScopedResource() }
        }
        do {
          let files = try collectKnowledgeFiles(from: root)
          if files.isEmpty {
            failures.append(
              KnowledgeImportFailure(
                title: root.lastPathComponent, reason: "対応する資料ファイルが見つかりませんでした。"))
          }
          for file in files {
            let title = knowledgeTitle(for: file, selectedRoot: root)
            do {
              let content = try extractKnowledgeText(from: file)
              try await addKnowledge(title: title, content: content)
              importedCount += 1
            } catch {
              failures.append(
                KnowledgeImportFailure(title: title, reason: error.localizedDescription))
            }
          }
        } catch {
          failures.append(
            KnowledgeImportFailure(
              title: root.lastPathComponent, reason: error.localizedDescription))
        }
      }
      await loadKnowledgeStatus()
      if importedCount == 0 {
        throw StreamError(
          message: knowledgeImportMessage(importedCount: importedCount, failures: failures))
      }
      if !failures.isEmpty {
        errorMessage = knowledgeImportMessage(importedCount: importedCount, failures: failures)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func knowledgeImportMessage(
    importedCount: Int, failures: [KnowledgeImportFailure]
  ) -> String {
    guard !failures.isEmpty else {
      return importedCount == 0 ? "対応する資料ファイルが見つかりませんでした。" : "\(importedCount)件の資料を追加しました。"
    }

    var lines =
      importedCount > 0
      ? ["\(importedCount)件の資料を追加しました。\(failures.count)件は読み込めませんでした。"]
      : ["資料を追加できませんでした。"]
    lines.append(
      contentsOf: failures.prefix(5).map { failure in
        "・\(failure.title): \(failure.reason)"
      })
    if failures.count > 5 {
      lines.append("ほか\(failures.count - 5)件も読み込めませんでした。")
    }
    return lines.joined(separator: "\n")
  }

  private func collectKnowledgeFiles(from url: URL) throws -> [URL] {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
    if values.isDirectory == true {
      let keys: Set<URLResourceKey> = [.isRegularFileKey, .isHiddenKey]
      guard
        let enumerator = FileManager.default.enumerator(
          at: url,
          includingPropertiesForKeys: Array(keys),
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else { return [] }
      return enumerator.compactMap { item in
        guard let file = item as? URL else { return nil }
        guard isSupportedKnowledgeFile(file) else { return nil }
        let values = try? file.resourceValues(forKeys: keys)
        guard values?.isRegularFile == true, values?.isHidden != true else { return nil }
        return file
      }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    guard values.isRegularFile == true, isSupportedKnowledgeFile(url) else { return [] }
    return [url]
  }

  private func isSupportedKnowledgeFile(_ url: URL) -> Bool {
    ["txt", "text", "md", "markdown", "pdf"].contains(url.pathExtension.lowercased())
  }

  private func knowledgeTitle(for file: URL, selectedRoot: URL) -> String {
    let rootValues = try? selectedRoot.resourceValues(forKeys: [.isDirectoryKey])
    guard rootValues?.isDirectory == true else { return file.lastPathComponent }
    let rootPath = selectedRoot.standardizedFileURL.path
    let filePath = file.standardizedFileURL.path
    if filePath.hasPrefix(rootPath + "/") {
      return selectedRoot.lastPathComponent + "/" + String(filePath.dropFirst(rootPath.count + 1))
    }
    return selectedRoot.lastPathComponent + "/" + file.lastPathComponent
  }

  private func extractKnowledgeText(from url: URL) throws -> String {
    if url.pathExtension.lowercased() == "pdf" {
      let readableURL = try coordinatedReadableURL(for: url) { coordinatedURL in
        coordinatedURL
      }
      guard let document = PDFDocument(url: readableURL) else {
        throw StreamError(message: "PDF を開けませんでした。")
      }
      let pages = (0..<document.pageCount).compactMap { index in
        document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
      }.filter { !$0.isEmpty }
      let text = pages.joined(separator: "\n\n")
      guard !text.isEmpty else { throw StreamError(message: "PDF からテキストを抽出できませんでした。") }
      return text
    }
    let data = try readKnowledgeFileData(from: url)
    if let text = String(data: data, encoding: .utf8) { return text }
    // Foundation can decode arbitrary byte pairs as UTF-16 and silently produce
    // mojibake. Only accept UTF-16 when the file declares its byte order with a BOM.
    let hasUTF16ByteOrderMark =
      data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    if hasUTF16ByteOrderMark, let text = String(data: data, encoding: .utf16) { return text }
    if let text = String(data: data, encoding: .shiftJIS) { return text }
    throw StreamError(message: "テキストの文字コードを判定できませんでした。UTF-8、UTF-16、Shift JIS のいずれかで保存してください。")
  }

  private func readKnowledgeFileData(from url: URL) throws -> Data {
    try prepareKnowledgeFileForReading(url)
    return try coordinatedReadableURL(for: url) { coordinatedURL in
      try Data(contentsOf: coordinatedURL)
    }
  }

  private func coordinatedReadableURL<T>(for url: URL, read: (URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var readResult: Result<T, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) {
      coordinatedURL in
      readResult = Result { try read(coordinatedURL) }
    }
    if let coordinationError { throw coordinationError }
    guard let readResult else { throw StreamError(message: "ファイルを読み込めませんでした。") }
    return try readResult.get()
  }

  private func prepareKnowledgeFileForReading(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) { return }
    do {
      try FileManager.default.startDownloadingUbiquitousItem(at: url)
    } catch {
      throw StreamError(
        message: "ファイルの実体を取得できませんでした。iCloud、OneDrive、Dropbox などの同期が完了しているか確認してください。")
    }
  }

  @MainActor private func addKnowledge(title: String, content: String) async throws {
    var request = URLRequest(url: OnigiriEndpoint.url("knowledge/document"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      KnowledgeDocumentRequest(title: title, content: content))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let apiError = try? JSONDecoder().decode(APIError.self, from: data)
      throw StreamError(message: apiError?.error ?? "資料の追加に失敗しました。")
    }
    knowledgeStatus = try JSONDecoder().decode(KnowledgeStatus.self, from: data)
    queuedKnowledgeMatches = []
    await loadKnowledgeDocuments()
    errorMessage = nil
  }

  @MainActor private func deleteKnowledgeDocument(_ id: UUID) async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/delete"))
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(KnowledgeDocumentDeleteRequest(id: id))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeStatus = try JSONDecoder().decode(KnowledgeStatus.self, from: data)
      queuedKnowledgeMatches.removeAll { $0.documentID == id }
      knowledgeSelectionHistory.removeAll { entry in
        entry.matches.contains { $0.documentID == id }
      }
      saveKnowledgeSelectionHistory()
      ragEvaluationCases.removeAll { evaluationCase in
        evaluationCase.expectedMatches.contains { $0.documentID == id }
      }
      saveRAGEvaluationCases()
      pruneRAGEvaluationSuites()
      await loadKnowledgeDocuments()
      if knowledgeDocuments.isEmpty { showingKnowledgeDocuments = false }
      if knowledgeStatus.documentCount == 0 { resetConversationContextsAfterKnowledgeClear() }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func searchKnowledgeForCurrentText() async {
    do {
      let latestUserMessage = messages.last(where: { $0.role == .user })?.content ?? ""
      let query =
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? latestUserMessage : draft
      let trimmedQuery = try Harness.validatedMessage(query)
      try await showKnowledgeMatches(query: trimmedQuery)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func searchKnowledgeFromToolbar() async {
    let query = quickKnowledgeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      await searchKnowledgeForCurrentText()
    } else {
      await searchKnowledge(query: query)
    }
  }

  @MainActor private func searchKnowledge(query: String) async {
    showingKnowledgeDocuments = false
    do {
      let trimmedQuery = try Harness.validatedMessage(query)
      try await showKnowledgeMatches(query: trimmedQuery)
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func showKnowledgeMatches(query: String) async throws {
    knowledgeSearchQuery = query
    let matches = try await fetchKnowledgeMatches(query: query)
    await loadKnowledgeStatus()
    knowledgeSearchPresentation = KnowledgeSearchPresentation(query: query, matches: matches)
  }

  @MainActor private func fetchKnowledgeMatches(query: String) async throws -> [KnowledgeChunkMatch]
  {
    var request = URLRequest(url: OnigiriEndpoint.url("knowledge/search"))
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      KnowledgeSearchRequest(
        query: query,
        limit: searchLimit,
        minScore: searchMinScore,
        keywordWeight: searchKeywordWeight,
        embeddingWeight: searchEmbeddingWeight
      ))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode(KnowledgeSearchResponse.self, from: data).matches
  }

  @MainActor private func refreshKnowledgeEmbeddings() async {
    busy = true
    errorMessage = nil
    defer { busy = false }

    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/embeddings"))
      request.httpMethod = "POST"
      request.timeoutInterval = 120
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "Embedding の更新に失敗しました。")
      }
      knowledgeStatus = try JSONDecoder().decode(KnowledgeStatus.self, from: data)
      await loadKnowledgeDocuments()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func clearKnowledge() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("knowledge/clear"))
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeStatus = try JSONDecoder().decode(KnowledgeStatus.self, from: data)
      knowledgeDocuments = []
      knowledgeSearchPresentation = nil
      queuedKnowledgeMatches = []
      knowledgeSelectionHistory = []
      saveKnowledgeSelectionHistory()
      ragEvaluationCases = []
      saveRAGEvaluationCases()
      pruneRAGEvaluationSuites()
      selectedCitation = nil
      resetConversationContextsAfterKnowledgeClear()
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func send() async {
    busy = true
    errorMessage = nil
    let activeConversationID = conversationID
    sendingConversationID = activeConversationID
    stopRequested = false
    defer {
      busy = false
      sendingConversationID = nil
      stopRequested = false
      stoppingGeneration = false
    }

    do {
      let input = try Harness.validatedMessage(draft)
      draft = ""
      let selectedMatches = selectedRAGMode == .disabled ? [] : queuedKnowledgeMatches
      let selectedWebSources = queuedWebResearchSources
      let citations =
        !selectedMatches.isEmpty ? selectedMatches
        : selectedRAGMode == .always && knowledgeStatus.chunkCount > 0
          && !ContextBuilder.isFollowUpTransformRequest(input)
        ? (try? await fetchKnowledgeMatches(query: input)) ?? [] : []
      appendMessage(DisplayMessage(role: .user, content: input), to: activeConversationID)
      let responseID = UUID()
      appendMessage(
        DisplayMessage(
          id: responseID, role: .assistant, content: "", citations: citations,
          webSources: selectedWebSources.map(\.citation),
          ragMode: selectedRAGMode),
        to: activeConversationID)

      var request = URLRequest(url: OnigiriEndpoint.url("chat/stream"))
      request.httpMethod = "POST"
      request.timeoutInterval = 120
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(
        ChatRequest(
          conversationID: activeConversationID,
          message: input,
          history: chatHistoryMessages(before: responseID, in: activeConversationID),
          selectedChunkIDs: selectedMatches.isEmpty ? nil : selectedMatches.map(\.id),
          webSources: selectedWebSources,
          runtime: ChatRuntimeOptions(
            systemInstructions: systemInstructions, ragMode: selectedRAGMode,
            searchSettings: currentSearchSettings, contextLimit: contextLimit)
        ))

      let (bytes, response) = try await URLSession.shared.bytes(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      for try await line in bytes.lines where !line.isEmpty {
        let event = try JSONDecoder().decode(ChatStreamEvent.self, from: Data(line.utf8))
        switch event.kind {
        case .snapshot:
          updateMessage(
            conversationID: activeConversationID, messageID: responseID, content: event.content)
        case .ragTrace:
          let trace = try JSONDecoder().decode(AgenticRAGTrace.self, from: Data(event.content.utf8))
          updateMessage(
            conversationID: activeConversationID, messageID: responseID, ragTrace: trace)
        case .done:
          if !selectedMatches.isEmpty { queuedKnowledgeMatches = [] }
          if !selectedWebSources.isEmpty { queuedWebResearchSources = [] }
        case .error:
          throw StreamError(message: event.content)
        }
      }
    } catch {
      removeTrailingEmptyAssistantMessage(from: activeConversationID)
      if !stopRequested { errorMessage = error.localizedDescription }
    }
  }

  @MainActor private func stopGeneration() async {
    guard let conversationID = sendingConversationID else { return }
    stopRequested = true
    stoppingGeneration = true
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("chat/cancel"))
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(
        ConversationRequest(conversationID: conversationID))
      let (_, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
    } catch {
      stopRequested = false
      stoppingGeneration = false
      errorMessage = "生成を停止できませんでした: \(error.localizedDescription)"
    }
  }

  @MainActor private func chatHistoryMessages(
    before responseID: UUID, in conversationID: UUID
  ) -> [ChatHistoryMessage] {
    guard let conversation = conversations.first(where: { $0.id == conversationID }) else {
      return []
    }
    let messages: ArraySlice<DisplayMessage>
    if let resetID = conversation.contextResetAfterMessageID,
      let resetIndex = conversation.messages.firstIndex(where: { $0.id == resetID })
    {
      messages = conversation.messages.suffix(from: conversation.messages.index(after: resetIndex))
    } else {
      messages = conversation.messages[...]
    }
    return messages.compactMap { message in
      guard message.id != responseID else { return nil }
      let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !content.isEmpty else { return nil }
      let role: ChatHistoryMessage.Role = message.role == .user ? .user : .assistant
      return ChatHistoryMessage(role: role, content: content)
    }
  }

  @MainActor private func resetConversationContextsAfterKnowledgeClear() {
    for index in conversations.indices {
      conversations[index].contextResetAfterMessageID = conversations[index].messages.last?.id
      for messageIndex in conversations[index].messages.indices {
        conversations[index].messages[messageIndex].citations = []
        conversations[index].messages[messageIndex].ragTrace = nil
      }
    }
    saveConversations()
  }

  @MainActor private func newConversation() async {
    let previousID = conversationID
    var conversation = StoredConversation.empty
    conversation.profileID = defaultProductProfileID ?? productProfiles.first?.id
    conversations.insert(conversation, at: 0)
    selectedConversationID = conversation.id
    selectedProductProfileID = conversation.profileID
    activateProfileForSelectedConversation()
    saveConversations()
    errorMessage = nil
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("conversation/reset"))
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(ConversationRequest(conversationID: previousID))
      _ = try await URLSession.shared.data(for: request)
    } catch {
      // The new UUID isolates the new chat even if the old server session could not be removed.
    }
  }

  @MainActor private func loadCodexTasks() async {
    do {
      async let availabilityRequest = URLSession.shared.data(
        for: URLRequest(url: OnigiriEndpoint.url("agents/status")))
      async let tasksRequest = URLSession.shared.data(
        for: URLRequest(url: OnigiriEndpoint.url("agents/tasks")))
      let ((availabilityData, availabilityResponse), (tasksData, tasksResponse)) =
        try await (availabilityRequest, tasksRequest)
      guard (availabilityResponse as? HTTPURLResponse)?.statusCode == 200,
        (tasksResponse as? HTTPURLResponse)?.statusCode == 200
      else { throw URLError(.badServerResponse) }
      aiTaskAvailabilities = try JSONDecoder().decode(
        AITaskAvailabilityResponse.self, from: availabilityData).providers
      codexTasks = try JSONDecoder().decode(CodexTaskListResponse.self, from: tasksData).tasks
    } catch {
      aiTaskAvailabilities = AITaskProvider.allCases.map {
        CodexAvailability(
          provider: $0, available: false, executablePath: nil,
          detail: "OnigiriServerから\($0.name)の状態を取得できません。")
      }
    }
  }

  @MainActor private func startCodexTask(_ task: CodexTaskRequest) async -> Bool {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("agents/tasks"))
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(task)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "AIタスクを開始できませんでした。")
      }
      let started = try JSONDecoder().decode(CodexTaskRecord.self, from: data)
      codexTasks.removeAll { $0.id == started.id }
      codexTasks.insert(started, at: 0)
      errorMessage = nil
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @MainActor private func cancelCodexTask(_ id: UUID) async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("agents/tasks/cancel"))
      request.httpMethod = "POST"
      request.timeoutInterval = 10
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(CodexTaskActionRequest(id: id))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "AIタスクをキャンセルできませんでした。")
      }
      let cancelled = try JSONDecoder().decode(CodexTaskRecord.self, from: data)
      if let index = codexTasks.firstIndex(where: { $0.id == cancelled.id }) {
        codexTasks[index] = cancelled
      }
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadKnowledgeToolAudit() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("tools/audit"))
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeToolAuditEntries =
        try JSONDecoder().decode(KnowledgeToolAuditResponse.self, from: data).entries
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func clearKnowledgeToolAudit() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("tools/audit/clear"))
      request.httpMethod = "POST"
      request.timeoutInterval = 5
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      knowledgeToolAuditEntries =
        try JSONDecoder().decode(KnowledgeToolAuditResponse.self, from: data).entries
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadDecisionModels(
    _ config: DecisionProviderConfig
  ) async -> [DecisionModelSummary]? {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("decision/models"))
      request.httpMethod = "POST"
      request.timeoutInterval = 15
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(DecisionModelListRequest(provider: config))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "意思決定モデル一覧を取得できませんでした。")
      }
      decisionModels = try JSONDecoder().decode(DecisionModelListResponse.self, from: data).models
      errorMessage = nil
      return decisionModels
    } catch {
      decisionModels = []
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @MainActor private func loadDecisionRuns() async {
    do {
      let (data, response) = try await URLSession.shared.data(
        for: URLRequest(url: OnigiriEndpoint.url("decision/runs")))
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      decisionRuns = try JSONDecoder().decode(DecisionExperimentListResponse.self, from: data).runs
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func runDecisionExperiment(
    _ experiment: DecisionExperimentRequest
  ) async -> DecisionExperimentRecord? {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("decision/run"))
      request.httpMethod = "POST"
      request.timeoutInterval = 70
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(experiment)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "意思決定実験を実行できませんでした。")
      }
      let record = try JSONDecoder().decode(DecisionExperimentRecord.self, from: data)
      decisionRuns.removeAll { $0.id == record.id }
      decisionRuns.insert(record, at: 0)
      errorMessage = record.error
      return record
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @MainActor private func clearDecisionRuns() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("decision/runs/clear"))
      request.httpMethod = "POST"
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      decisionRuns = try JSONDecoder().decode(DecisionExperimentListResponse.self, from: data).runs
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor private func loadDecisionEvaluations() async {
    do {
      let (data, response) = try await URLSession.shared.data(
        for: URLRequest(url: OnigiriEndpoint.url("decision/evaluations")))
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      decisionEvaluationReports = try JSONDecoder().decode(
        DecisionEvaluationReportList.self, from: data).reports
    } catch { errorMessage = error.localizedDescription }
  }

  @MainActor private func runDecisionEvaluation(
    _ evaluation: DecisionEvaluationRequest
  ) async -> DecisionEvaluationReport? {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("decision/evaluations/run"))
      request.httpMethod = "POST"
      request.timeoutInterval = 600
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(evaluation)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "意思決定評価を実行できませんでした。")
      }
      let report = try JSONDecoder().decode(DecisionEvaluationReport.self, from: data)
      decisionEvaluationReports.removeAll { $0.id == report.id }
      decisionEvaluationReports.insert(report, at: 0)
      errorMessage = nil
      return report
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @MainActor private func clearDecisionEvaluations() async {
    do {
      var request = URLRequest(url: OnigiriEndpoint.url("decision/evaluations/clear"))
      request.httpMethod = "POST"
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      decisionEvaluationReports = try JSONDecoder().decode(
        DecisionEvaluationReportList.self, from: data).reports
      errorMessage = nil
    } catch { errorMessage = error.localizedDescription }
  }
}

private struct SheetTitleBar: View {
  let title: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    HStack {
      Text(title).font(.title2.bold())
      Spacer()
      Button("閉じる", systemImage: "xmark") {
        dismiss()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.bordered)
      .keyboardShortcut(.cancelAction)
      .help("閉じる")
    }
  }
}

private struct DecisionQuestionDraft: Identifiable {
  let id = UUID()
  var key: String
  var type: DecisionQuestionType
  var instructions: String
  var criteria: String

  static let initial = DecisionQuestionDraft(
    key: "next_action", type: .choice,
    instructions: "Which action should be selected?",
    criteria: "proceed: Continue with the action\nescalate: Ask a stronger model or a human\nstop: Do not continue")
}

private struct DecisionLabView: View {
  let models: [DecisionModelSummary]
  let runs: [DecisionExperimentRecord]
  let loadModels: (DecisionProviderConfig) async -> [DecisionModelSummary]?
  let run: (DecisionExperimentRequest) async -> DecisionExperimentRecord?
  let refreshRuns: () async -> Void
  let clearRuns: () async -> Void
  let evaluationReports: [DecisionEvaluationReport]
  let runEvaluation: (DecisionEvaluationRequest) async -> DecisionEvaluationReport?
  let refreshEvaluations: () async -> Void
  let clearEvaluations: () async -> Void

  @AppStorage("onigiri.decisionProviderKind") private var providerKindRaw = DecisionProviderKind.ollaya.rawValue
  @AppStorage("onigiri.decisionBaseURL") private var baseURL = "http://127.0.0.1:11435"
  @State private var apiKey = ""
  @AppStorage("onigiri.decisionModel") private var selectedModel = ""
  @State private var stateText = ""
  @State private var questions: [DecisionQuestionDraft] = [.initial]
  @State private var selectedRunID: UUID?
  @State private var loadingModels = false
  @State private var running = false
  @State private var localError: String?
  @State private var showingEvaluation = false
  @State private var keychainMessage: String?
  private let secretStore = KeychainSecretStore()

  private var providerConfig: DecisionProviderConfig {
    DecisionProviderConfig(
      kind: providerKind, baseURL: baseURL,
      apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : apiKey)
  }

  private var providerKind: DecisionProviderKind {
    DecisionProviderKind(rawValue: providerKindRaw) ?? .ollaya
  }

  private var providerKindBinding: Binding<DecisionProviderKind> {
    Binding(
      get: { providerKind },
      set: { kind in
        providerKindRaw = kind.rawValue
        baseURL = DecisionProviderCatalog.descriptors.first { $0.kind == kind }?.defaultBaseURL ?? ""
        selectedModel = ""
      })
  }

  private var selectedRun: DecisionExperimentRecord? {
    guard let selectedRunID else { return runs.first }
    return runs.first { $0.id == selectedRunID } ?? runs.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "Decision Model Lab")
      Text("Jev、Ollaya、TypeSafe互換モデルを共通のtyped decision形式で比較します。実験結果は通常の会話・RAGから分離されます。")
        .font(.caption)
        .foregroundStyle(.secondary)
      providerBar
      if let localError {
        Text(localError).foregroundStyle(.red).font(.caption).textSelection(.enabled)
      }
      HSplitView {
        experimentEditor.frame(minWidth: 480, idealWidth: 560, maxHeight: .infinity)
        runHistory.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(20)
    .task { await refreshRuns() }
    .onAppear { loadAPIKeyFromKeychain() }
    .onChange(of: providerKindRaw) { _, _ in loadAPIKeyFromKeychain() }
    .sheet(isPresented: $showingEvaluation) {
      DecisionEvaluationView(
        provider: providerConfig, availableModels: models, reports: evaluationReports,
        run: runEvaluation, refresh: refreshEvaluations, clear: clearEvaluations)
      .frame(minWidth: 960, minHeight: 680)
    }
    .onChange(of: models) { _, updated in
      if !updated.isEmpty, !updated.contains(where: { $0.name == selectedModel }) {
        selectedModel = updated[0].name
      }
    }
  }

  private var providerBar: some View {
    HStack(spacing: 10) {
      Picker("Provider", selection: providerKindBinding) {
        ForEach(DecisionProviderCatalog.descriptors) { provider in
          Text(provider.name).tag(provider.kind)
        }
      }
      .frame(width: 230)
      TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
      if providerKind == .typeSafeCompatible {
        SecureField("API key（Keychain）", text: $apiKey)
          .textFieldStyle(.roundedBorder)
          .frame(width: 190)
        Button("Keychainへ保存", systemImage: "key.fill") { saveAPIKeyToKeychain() }
          .labelStyle(.iconOnly)
          .help("API keyをKeychainへ保存")
        Button("Keychainから読み込む", systemImage: "arrow.down.to.line") {
          loadAPIKeyFromKeychain()
        }
          .labelStyle(.iconOnly)
          .help("現在のProviderとBase URLに対応するAPI keyを読み込む")
        Button("Keychainから削除", systemImage: "trash") { deleteAPIKeyFromKeychain() }
          .labelStyle(.iconOnly)
          .help("保存済みAPI keyを削除")
      }
      Button("モデル確認", systemImage: "arrow.clockwise") {
        Task {
          loadingModels = true
          if let loaded = await loadModels(providerConfig) {
            selectedModel = loaded.first?.name ?? selectedModel
            localError = loaded.isEmpty
              ? "Ollayaは起動していますが、モデルはまだありません。OllayaのModelsからモデルを追加してください。"
              : nil
          } else {
            localError = "Providerへ接続できませんでした。"
          }
          loadingModels = false
        }
      }
      .disabled(loadingModels || baseURL.isEmpty)
      Button("評価", systemImage: "chart.bar.xaxis") { showingEvaluation = true }
        .disabled(baseURL.isEmpty)
      if let keychainMessage {
        Text(keychainMessage).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var keychainAccount: String {
    "decision.\(providerKind.rawValue).\(baseURL.trimmingCharacters(in: .whitespacesAndNewlines))"
  }

  private func loadAPIKeyFromKeychain() {
    guard providerKind == .typeSafeCompatible else {
      apiKey = ""
      keychainMessage = nil
      return
    }
    do {
      apiKey = try secretStore.read(account: keychainAccount) ?? ""
      keychainMessage = apiKey.isEmpty ? "Keychainに保存済みのキーはありません。" : "Keychainから読み込みました。"
    } catch {
      keychainMessage = error.localizedDescription
    }
  }

  private func saveAPIKeyToKeychain() {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      keychainMessage = "保存するAPI keyを入力してください。"
      return
    }
    do {
      try secretStore.save(key, account: keychainAccount)
      keychainMessage = "API keyをKeychainへ保存しました。"
    } catch {
      keychainMessage = error.localizedDescription
    }
  }

  private func deleteAPIKeyFromKeychain() {
    do {
      try secretStore.delete(account: keychainAccount)
      apiKey = ""
      keychainMessage = "Keychainから削除しました。"
    } catch {
      keychainMessage = error.localizedDescription
    }
  }

  private var experimentEditor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("実験入力").font(.headline)
          Spacer()
          if models.isEmpty {
            TextField("モデル名", text: $selectedModel).textFieldStyle(.roundedBorder).frame(width: 180)
          } else {
            Picker("モデル", selection: $selectedModel) {
              ForEach(models) { model in Text(model.name).tag(model.name) }
            }
            .frame(width: 240)
          }
        }
        Text("状態（テキスト、またはJSON）").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $stateText)
          .frame(minHeight: 120)
          .padding(5)
          .background(Color.secondary.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack {
          Text("質問").font(.headline)
          Spacer()
          Button("追加", systemImage: "plus") {
            questions.append(
              DecisionQuestionDraft(key: "question_\(questions.count + 1)", type: .noul, instructions: "", criteria: ""))
          }
        }
        ForEach($questions) { $question in
          GroupBox {
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                TextField("質問ID", text: $question.key).textFieldStyle(.roundedBorder)
                Picker("種類", selection: $question.type) {
                  Text("Choice").tag(DecisionQuestionType.choice)
                  Text("Score").tag(DecisionQuestionType.score)
                  Text("Noul").tag(DecisionQuestionType.noul)
                }
                .frame(width: 150)
                Button("削除", systemImage: "minus") {
                  questions.removeAll { $0.id == question.id }
                }
                .labelStyle(.iconOnly)
                .disabled(questions.count == 1)
              }
              TextField("判断してほしい内容", text: $question.instructions)
                .textFieldStyle(.roundedBorder)
              if question.type != .noul {
                Text(question.type == .choice ? "選択肢（1行に label: 説明）" : "評価段階（低い順に1行ずつ）")
                  .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $question.criteria)
                  .frame(minHeight: 70)
                  .padding(4)
                  .background(Color.secondary.opacity(0.07))
                  .clipShape(RoundedRectangle(cornerRadius: 6))
              }
            }
          }
        }
        HStack {
          Text("Phase 3.1では結果を観察・比較するだけで、回答に応じた操作は自動実行しません。")
            .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("実行", systemImage: "play.fill") { Task { await execute() } }
            .buttonStyle(.borderedProminent)
            .disabled(running || selectedModel.isEmpty || stateText.isEmpty || questions.isEmpty)
        }
      }
      .padding(.trailing, 14)
    }
  }

  private var runHistory: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("実験履歴").font(.headline)
        Text("\(runs.count)件").foregroundStyle(.secondary)
        Spacer()
        Button("クリア", systemImage: "trash") { Task { await clearRuns() } }.disabled(runs.isEmpty)
      }
      if runs.isEmpty {
        ContentUnavailableView("実験履歴はありません", systemImage: "switch.2")
      } else {
        HSplitView {
          List(selection: $selectedRunID) {
            ForEach(runs) { record in
              VStack(alignment: .leading, spacing: 3) {
                Text(record.request.model).lineLimit(1)
                Text("\(record.request.questions.count)問 / \(record.durationMilliseconds)ms")
                  .font(.caption).foregroundStyle(.secondary)
              }
              .tag(Optional(record.id))
            }
          }
          .frame(minWidth: 150, idealWidth: 180)
          decisionRunDetail.frame(minWidth: 230, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  @ViewBuilder private var decisionRunDetail: some View {
    if let record = selectedRun {
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          Label(
            record.status == .completed ? "完了" : "失敗",
            systemImage: record.status == .completed ? "checkmark.circle.fill" : "xmark.octagon.fill")
            .foregroundStyle(record.status == .completed ? Color.green : Color.red)
          Text("Provider: \(record.request.provider.kind.rawValue)")
          Text("Model: \(record.respondingModel ?? record.request.model)")
          Text("時間: \(record.durationMilliseconds)ms")
          if let error = record.error { Text(error).foregroundStyle(.red) }
          if let response = record.response {
            Text(Self.prettyJSON(response)).font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
      }
    } else {
      ContentUnavailableView("履歴を選択", systemImage: "list.bullet.rectangle")
    }
  }

  @MainActor private func execute() async {
    running = true
    defer { running = false }
    do {
      let state: JSONValue
      if let data = stateText.data(using: .utf8),
        let parsed = try? JSONDecoder().decode(JSONValue.self, from: data)
      { state = parsed } else { state = .string(stateText) }
      var mapped: [String: DecisionQuestion] = [:]
      for draft in questions {
        let key = draft.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, mapped[key] == nil else {
          throw StreamError(message: "質問IDは空欄や重複にできません。")
        }
        let lines = draft.criteria.split(whereSeparator: \.isNewline).map(String.init)
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let criteria: JSONValue?
        switch draft.type {
        case .choice:
          var choices: [String: JSONValue] = [:]
          for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            choices[parts[0].trimmingCharacters(in: .whitespaces)] =
              .string(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : parts[0])
          }
          criteria = .object(choices)
        case .score: criteria = .array(lines.map(JSONValue.string))
        case .noul: criteria = nil
        }
        mapped[key] = DecisionQuestion(
          type: draft.type,
          instructions: draft.instructions.isEmpty ? nil : .string(draft.instructions),
          criteria: criteria)
      }
      let result = await run(
        DecisionExperimentRequest(
          provider: providerConfig, model: selectedModel, state: state, questions: mapped))
      localError = result?.error
      selectedRunID = result?.id
    } catch {
      localError = error.localizedDescription
    }
  }

  private static func prettyJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
}

private struct DecisionEvaluationCaseDraft: Identifiable {
  let id = UUID()
  var name = "ケース 1"
  var state = ""
  var questionID = "decision"
  var type = DecisionQuestionType.choice
  var instructions = "Select the best decision."
  var criteria = "approve: Approve the request\nreject: Reject the request"
  var expectedChoice = "approve"
  var minimumScore = "0"
  var maximumScore = "1"
  var expectedNoul = true
}

private struct DecisionOverrideDraft: Identifiable {
  let id = UUID()
  var model = ""
  var questionID = ""
  var threshold = 0.7
  var fallback = DecisionFallbackTarget.human
}

private struct DecisionEvaluationView: View {
  let provider: DecisionProviderConfig
  let availableModels: [DecisionModelSummary]
  let reports: [DecisionEvaluationReport]
  let run: (DecisionEvaluationRequest) async -> DecisionEvaluationReport?
  let refresh: () async -> Void
  let clear: () async -> Void

  @State private var modelNames = ""
  @State private var cases = [DecisionEvaluationCaseDraft()]
  @State private var threshold = 0.7
  @State private var fallback = DecisionFallbackTarget.human
  @State private var overrides: [DecisionOverrideDraft] = []
  @State private var running = false
  @State private var localError: String?
  @State private var selectedReportID: UUID?

  private var selectedReport: DecisionEvaluationReport? {
    reports.first { $0.id == selectedReportID } ?? reports.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "Decision Evaluation & Routing Policies")
      Text("同じ正解付きケースを複数モデルで比較します。低confidence時のLLM／人へのフォールバックは記録だけを行うシミュレーションです。")
        .font(.caption).foregroundStyle(.secondary)
      HSplitView {
        editor.frame(minWidth: 500, idealWidth: 560, maxHeight: .infinity)
        reportPanel.frame(minWidth: 390, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(20)
    .task {
      if modelNames.isEmpty { modelNames = availableModels.map(\.name).joined(separator: ", ") }
      await refresh()
    }
  }

  private var editor: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        GroupBox("比較環境") {
          VStack(alignment: .leading, spacing: 8) {
            Text("モデル名（カンマまたは改行区切り）").font(.caption).foregroundStyle(.secondary)
            TextField("laya, winnow", text: $modelNames).textFieldStyle(.roundedBorder)
            Text("Provider: \(provider.kind.rawValue) / \(provider.baseURL)")
              .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        GroupBox("既定ルーティング") {
          HStack {
            Text("confidence閾値")
            Slider(value: $threshold, in: 0...1, step: 0.05)
            Text(threshold, format: .number.precision(.fractionLength(2))).monospacedDigit()
            Picker("低confidence時", selection: $fallback) {
              fallbackOptions
            }.frame(width: 190)
          }
        }
        HStack {
          Text("モデル／質問別override").font(.headline)
          Spacer()
          Button("追加", systemImage: "plus") { overrides.append(DecisionOverrideDraft()) }
        }
        ForEach($overrides) { $override in
          HStack {
            TextField("モデル（空欄=全て）", text: $override.model)
            TextField("質問ID（空欄=全て）", text: $override.questionID)
            Slider(value: $override.threshold, in: 0...1, step: 0.05).frame(width: 90)
            Text(override.threshold, format: .number.precision(.fractionLength(2))).monospacedDigit()
            Picker("Fallback", selection: $override.fallback) { fallbackOptions }.labelsHidden().frame(width: 105)
            Button("削除", systemImage: "minus") { overrides.removeAll { $0.id == override.id } }
              .labelStyle(.iconOnly)
          }
        }
        HStack {
          Text("正解付き評価ケース").font(.headline)
          Spacer()
          Button("追加", systemImage: "plus") {
            var draft = DecisionEvaluationCaseDraft()
            draft.name = "ケース \(cases.count + 1)"
            cases.append(draft)
          }
        }
        ForEach($cases) { $draft in
          GroupBox(draft.name.isEmpty ? "評価ケース" : draft.name) {
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                TextField("ケース名", text: $draft.name)
                TextField("質問ID", text: $draft.questionID)
                Picker("種類", selection: $draft.type) {
                  Text("Choice").tag(DecisionQuestionType.choice)
                  Text("Score").tag(DecisionQuestionType.score)
                  Text("Noul").tag(DecisionQuestionType.noul)
                }.frame(width: 145)
                Button("削除", systemImage: "minus") { cases.removeAll { $0.id == draft.id } }
                  .labelStyle(.iconOnly).disabled(cases.count == 1)
              }
              TextField("判断してほしい内容", text: $draft.instructions)
              Text("状態（テキスト、またはJSON）").font(.caption).foregroundStyle(.secondary)
              TextEditor(text: $draft.state).frame(minHeight: 55)
                .padding(4).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6))
              if draft.type != .noul {
                Text(draft.type == .choice ? "選択肢（label: 説明）" : "評価段階（1行ずつ）")
                  .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.criteria).frame(minHeight: 55)
                  .padding(4).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 6))
              }
              expectedEditor($draft)
            }
          }
        }
        if let localError { Text(localError).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
        HStack {
          Spacer()
          Button("比較評価を実行", systemImage: "play.fill") { Task { await execute() } }
            .buttonStyle(.borderedProminent).disabled(running || modelNames.isEmpty || cases.isEmpty)
        }
      }.padding(.trailing, 14)
    }
  }

  @ViewBuilder private func expectedEditor(_ draft: Binding<DecisionEvaluationCaseDraft>) -> some View {
    switch draft.wrappedValue.type {
    case .choice:
      TextField("正解ラベル", text: draft.expectedChoice).textFieldStyle(.roundedBorder)
    case .score:
      HStack {
        TextField("正解の最小値", text: draft.minimumScore).textFieldStyle(.roundedBorder)
        TextField("正解の最大値", text: draft.maximumScore).textFieldStyle(.roundedBorder)
      }
    case .noul:
      Toggle("期待値: \(draft.wrappedValue.expectedNoul ? "Yes" : "No")", isOn: draft.expectedNoul)
    }
  }

  private var reportPanel: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("評価レポート").font(.headline)
        Text("\(reports.count)件").foregroundStyle(.secondary)
        Spacer()
        Button("更新", systemImage: "arrow.clockwise") { Task { await refresh() } }
        Button("クリア", systemImage: "trash") { Task { await clear() } }.disabled(reports.isEmpty)
      }
      if reports.isEmpty {
        ContentUnavailableView("評価レポートはありません", systemImage: "chart.bar.xaxis")
      } else {
        List(selection: $selectedReportID) {
          ForEach(reports) { report in
            VStack(alignment: .leading) {
              Text(report.createdAt.formatted(date: .abbreviated, time: .standard))
              Text("\(report.environments.count)モデル × \(report.cases.count)ケース")
                .font(.caption).foregroundStyle(.secondary)
            }.tag(Optional(report.id))
          }
        }.frame(height: 150)
        if let report = selectedReport {
          List {
            ForEach(report.summaries) { summary in
              VStack(alignment: .leading, spacing: 5) {
                Text(summary.model).font(.headline)
                Text("正解率 \(summary.accuracy.formatted(.percent.precision(.fractionLength(1))))  /  calibration error \(summary.calibrationError.formatted(.number.precision(.fractionLength(3))))")
                Text("平均 \(summary.averageDurationMilliseconds.formatted(.number.precision(.fractionLength(0))))ms  /  fallback \(summary.escalationRate.formatted(.percent.precision(.fractionLength(1))))  /  完了 \(summary.completedCount)/\(summary.totalCount)")
                  .foregroundStyle(.secondary)
              }.font(.caption)
            }
            Section("ケース別") {
              ForEach(report.entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                  HStack {
                    Text(entry.model).fontWeight(.semibold)
                    Spacer()
                    Text(entry.correct == true ? "正解" : entry.correct == false ? "不正解" : "失敗")
                      .foregroundStyle(entry.correct == true ? Color.green : Color.red)
                  }
                  Text("\(entry.questionID): \(entry.predictedValue ?? entry.error ?? "回答なし")")
                  Text("confidence \(entry.confidence?.formatted(.number.precision(.fractionLength(3))) ?? "-") / 閾値 \(entry.appliedThreshold.formatted(.number.precision(.fractionLength(2)))) / \(entry.durationMilliseconds)ms")
                    .foregroundStyle(.secondary)
                  if entry.escalated {
                    Text("→ \(fallbackName(entry.simulatedFallback))へフォールバック（シミュレーション）")
                      .foregroundStyle(.orange)
                  }
                }.font(.caption)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder private var fallbackOptions: some View {
    Text("なし").tag(DecisionFallbackTarget.none)
    Text("LLM").tag(DecisionFallbackTarget.languageModel)
    Text("人").tag(DecisionFallbackTarget.human)
  }

  private func fallbackName(_ target: DecisionFallbackTarget) -> String {
    switch target { case .none: return "なし"; case .languageModel: return "LLM"; case .human: return "人" }
  }

  @MainActor private func execute() async {
    running = true
    defer { running = false }
    do {
      let names = modelNames.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      guard !names.isEmpty else { throw StreamError(message: "評価するモデルを入力してください。") }
      let environments = names.map {
        DecisionEvaluationEnvironment(name: $0, provider: provider, model: $0)
      }
      let mappedCases = try cases.map { draft -> DecisionEvaluationCase in
        let state: JSONValue
        if let data = draft.state.data(using: .utf8),
          let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) { state = parsed }
        else { state = .string(draft.state) }
        let lines = draft.criteria.split(whereSeparator: \.isNewline).map(String.init)
          .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let criteria: JSONValue?
        let expected: DecisionExpectedAnswer
        switch draft.type {
        case .choice:
          var choices: [String: JSONValue] = [:]
          for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            let label = parts[0].trimmingCharacters(in: .whitespaces)
            choices[label] = .string(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : label)
          }
          criteria = .object(choices)
          expected = DecisionExpectedAnswer(choice: draft.expectedChoice)
        case .score:
          guard let minimum = Double(draft.minimumScore), let maximum = Double(draft.maximumScore) else {
            throw StreamError(message: "Scoreケースの正解範囲は数値で入力してください。")
          }
          criteria = .array(lines.map(JSONValue.string))
          expected = DecisionExpectedAnswer(minimumScore: minimum, maximumScore: maximum)
        case .noul:
          criteria = nil
          expected = DecisionExpectedAnswer(noul: draft.expectedNoul)
        }
        return DecisionEvaluationCase(
          name: draft.name, state: state, questionID: draft.questionID,
          question: DecisionQuestion(type: draft.type, instructions: .string(draft.instructions), criteria: criteria),
          expected: expected)
      }
      let policyOverrides = overrides.map {
        DecisionThresholdOverride(
          model: $0.model.isEmpty ? nil : $0.model,
          questionID: $0.questionID.isEmpty ? nil : $0.questionID,
          threshold: $0.threshold, fallback: $0.fallback)
      }
      let result = await run(DecisionEvaluationRequest(
        environments: environments, cases: mappedCases,
        policy: DecisionRoutingPolicy(
          defaultThreshold: threshold, defaultFallback: fallback, overrides: policyOverrides)))
      selectedReportID = result?.id
      localError = result == nil ? "評価を完了できませんでした。" : nil
    } catch { localError = error.localizedDescription }
  }
}

private struct MCPAuditView: View {
  let entries: [KnowledgeToolAuditEntry]
  let refresh: () async -> Void
  let clear: () async -> Void

  private var executablePath: String {
    let bundled = Bundle.main.bundleURL
      .appending(path: "Contents", directoryHint: .isDirectory)
      .appending(path: "MacOS", directoryHint: .isDirectory)
      .appending(path: "onigiri-mcp")
    if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
    return "/tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/onigiri-mcp"
  }

  private var setupCommand: String {
    "codex mcp add onigiri-rag -- '\(executablePath.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetTitleBar(title: "Codex Inbound / MCP")
      GroupBox("Codexへ登録") {
        VStack(alignment: .leading, spacing: 8) {
          Text("Onigiriを起動した状態で、次のコマンドをターミナルで1回実行します。")
          HStack {
            Text(setupCommand)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .lineLimit(2)
            Spacer()
            Button("コピー", systemImage: "doc.on.doc") { copyToPasteboard(setupCommand) }
          }
          Text("公開されるToolはsearchKnowledgeとgetKnowledgeChunkだけで、どちらも読み取り専用です。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        Text("Tool呼び出し監査ログ").font(.headline)
        Text("\(entries.count)件").foregroundStyle(.secondary)
        Spacer()
        Button("更新", systemImage: "arrow.clockwise") { Task { await refresh() } }
        Button("クリア", systemImage: "trash") { Task { await clear() } }
          .disabled(entries.isEmpty)
      }

      if entries.isEmpty {
        ContentUnavailableView(
          "Tool呼び出しはありません", systemImage: "point.3.connected.trianglepath.dotted",
          description: Text("CodexがOnigiriのMCP Toolを使うと、ここに記録されます。"))
      } else {
        List(entries) { entry in
          VStack(alignment: .leading, spacing: 5) {
            HStack {
              Label(
                entry.toolName,
                systemImage: entry.success ? "checkmark.circle.fill" : "xmark.octagon.fill"
              )
              .foregroundStyle(entry.success ? Color.green : Color.red)
              Text(entry.source.uppercased())
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule())
              Text("読み取り専用").font(.caption).foregroundStyle(.secondary)
              Spacer()
              Text(entry.createdAt.formatted(date: .abbreviated, time: .standard))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(entry.requestSummary).lineLimit(2).textSelection(.enabled)
            HStack {
              Text("\(entry.durationMilliseconds)ms")
              if let count = entry.resultCount { Text("結果 \(count)件") }
              if let error = entry.error { Text(error).foregroundStyle(.red) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 3)
        }
      }
    }
    .padding(20)
    .task {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}

private struct DataManagementView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var preparation: StoragePreparationReport?
  @State private var message = "保存領域を確認しています…"
  @State private var pendingRestoreURL: URL?
  @State private var showingRestoreConfirmation = false
  @State private var working = false

  private let vault = OnigiriDataVault()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("データ管理").font(.title2.bold())
        Spacer()
        Button("閉じる", systemImage: "xmark") { dismiss() }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
      }

      GroupBox("保存状態") {
        VStack(alignment: .leading, spacing: 7) {
          Label(
            preparation?.corruptFiles.isEmpty == false ? "確認が必要です" : "正常です",
            systemImage: preparation?.corruptFiles.isEmpty == false
              ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
            .foregroundStyle(preparation?.corruptFiles.isEmpty == false ? .orange : .green)
          Text("保存形式 version \(preparation?.formatVersion ?? OnigiriDataVault.currentFormatVersion)")
          Text(OnigiriDataVault.defaultRootURL.path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          if let corrupt = preparation?.corruptFiles, !corrupt.isEmpty {
            Text("読めないJSON: \(corrupt.joined(separator: ", "))")
              .font(.caption)
              .foregroundStyle(.orange)
              .textSelection(.enabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      GroupBox("バックアップと復元") {
        VStack(alignment: .leading, spacing: 10) {
          Text("会話、Profile、資料、評価、AIタスク履歴をチェックサム付きの1ファイルに保存します。復元前には現在データのロールバック用コピーを自動作成します。")
            .font(.caption)
            .foregroundStyle(.secondary)
          HStack {
            Button("バックアップを書き出す", systemImage: "square.and.arrow.up") {
              exportBackup()
            }
            Button("バックアップから復元", systemImage: "square.and.arrow.down") {
              chooseBackupToRestore()
            }
            .disabled(working)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Spacer()
    }
    .padding(20)
    .task { refreshStatus() }
    .confirmationDialog(
      "バックアップを復元しますか？", isPresented: $showingRestoreConfirmation,
      titleVisibility: .visible
    ) {
      Button("復元する", role: .destructive) { restoreSelectedBackup() }
      Button("キャンセル", role: .cancel) { pendingRestoreURL = nil }
    } message: {
      Text("現在の保存データを置き換えます。復元後はOnigiriを再起動してください。")
    }
  }

  private func refreshStatus() {
    do {
      preparation = try vault.prepareStorage()
      message = preparation?.corruptFiles.isEmpty == false
        ? "破損している可能性があるファイルを確認してください。"
        : "保存データを読み取れます。"
    } catch {
      message = error.localizedDescription
    }
  }

  private func exportBackup() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Onigiri-Backup-\(Date.now.formatted(.iso8601.year().month().day())).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    working = true
    defer { working = false }
    do {
      let summary = try vault.createBackup(at: url)
      message = "\(summary.fileCount)ファイル（\(summary.totalBytes) bytes）をバックアップしました。"
    } catch {
      message = error.localizedDescription
    }
  }

  private func chooseBackupToRestore() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    pendingRestoreURL = url
    showingRestoreConfirmation = true
  }

  private func restoreSelectedBackup() {
    guard let url = pendingRestoreURL else { return }
    working = true
    defer { working = false; pendingRestoreURL = nil }
    do {
      let summary = try vault.restoreBackup(from: url)
      message = "\(summary.fileCount)ファイルを復元しました。Onigiriを再起動してください。"
      refreshStatus()
    } catch {
      message = error.localizedDescription
    }
  }
}

private struct CodexTasksView: View {
  let availabilities: [CodexAvailability]
  let tasks: [CodexTaskRecord]
  let refresh: () async -> Void
  let start: (CodexTaskRequest) async -> Bool
  let cancel: (UUID) async -> Void

  @State private var prompt = ""
  @State private var selectedProvider = AITaskProvider.codex
  @State private var workingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
  @State private var model = ""
  @State private var sandboxMode = CodexSandboxMode.readOnly
  @State private var timeoutSeconds = 600
  @State private var selectedTaskID: UUID?
  @State private var starting = false

  private var selectedTask: CodexTaskRecord? {
    guard let selectedTaskID else { return tasks.first }
    return tasks.first { $0.id == selectedTaskID } ?? tasks.first
  }

  private var selectedAvailability: CodexAvailability? {
    availabilities.first { $0.provider == selectedProvider }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      SheetTitleBar(title: "AIタスク")
      availabilityBanner
      HSplitView {
        taskComposer
          .frame(minWidth: 310, idealWidth: 350, maxWidth: 420, maxHeight: .infinity)
        taskHistory
          .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(20)
    .task {
      while !Task.isCancelled {
        await refresh()
        try? await Task.sleep(for: .seconds(1))
      }
    }
  }

  private var availabilityBanner: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        ForEach(AITaskProvider.allCases) { provider in
          let status = availabilities.first { $0.provider == provider }
          Button {
            selectedProvider = provider
          } label: {
            Label(
              provider.name,
              systemImage: status?.available == true
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          }
          .buttonStyle(.bordered)
          .tint(selectedProvider == provider ? .accentColor : nil)
        }
        Spacer()
        Button("再確認", systemImage: "arrow.clockwise") { Task { await refresh() } }
      }
      HStack(spacing: 6) {
        Image(systemName: selectedAvailability?.available == true
          ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
          .foregroundStyle(selectedAvailability?.available == true ? Color.green : Color.orange)
        Text(selectedAvailability?.detail ?? "\(selectedProvider.name)を確認しています…")
        if let path = selectedAvailability?.executablePath {
          Text(path)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
        }
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private var taskComposer: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("新しいタスク").font(.headline)
      Picker("実行AI", selection: $selectedProvider) {
        ForEach(AITaskProvider.allCases) { provider in
          Text(provider.name).tag(provider)
        }
      }
      .pickerStyle(.menu)
      Text("指示")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: $prompt)
        .font(.body)
        .frame(minHeight: 150)
        .padding(5)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))

      Text("作業フォルダ").font(.caption).foregroundStyle(.secondary)
      HStack {
        TextField("作業フォルダ", text: $workingDirectory)
          .textFieldStyle(.roundedBorder)
        Button("選択", systemImage: "folder") { chooseWorkingDirectory() }
          .labelStyle(.iconOnly)
          .help("作業フォルダを選択")
      }

      TextField("モデル（未指定なら\(selectedProvider.name)の既定値）", text: $model)
        .textFieldStyle(.roundedBorder)

      Picker("アクセス", selection: $sandboxMode) {
        Text("読み取り専用").tag(CodexSandboxMode.readOnly)
        Text("作業フォルダへ書き込み").tag(CodexSandboxMode.workspaceWrite)
      }
      .pickerStyle(.segmented)

      Stepper("タイムアウト: \(timeoutSeconds)秒", value: $timeoutSeconds, in: 30...3_600, step: 30)

      Text(
        sandboxMode == .readOnly
          ? "ファイルを変更しない調査・レビュー向けです。"
          : writeAccessDescription
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Spacer()
        Button("開始", systemImage: "play.fill") {
          Task {
            starting = true
            let request = CodexTaskRequest(
              provider: selectedProvider, prompt: prompt, workingDirectory: workingDirectory,
              model: model.isEmpty ? nil : model, sandboxMode: sandboxMode,
              timeoutSeconds: timeoutSeconds)
            if await start(request) { prompt = "" }
            starting = false
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          starting || selectedAvailability?.available != true
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      Spacer()
    }
    .padding(.trailing, 14)
  }

  private var taskHistory: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("実行履歴").font(.headline)
      if tasks.isEmpty {
        ContentUnavailableView(
          "AIタスクはありません", systemImage: "terminal",
          description: Text("左側に指示を入力して開始してください。"))
      } else {
        HSplitView {
          List(selection: $selectedTaskID) {
            ForEach(tasks) { task in
              VStack(alignment: .leading, spacing: 4) {
                Text(task.request.prompt).lineLimit(2)
                HStack(spacing: 6) {
                  Text(task.request.provider.name)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(Capsule())
                  CodexTaskStatusLabel(status: task.status)
                  Text(task.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
              }
              .padding(.vertical, 3)
              .tag(Optional(task.id))
            }
          }
          .frame(minWidth: 190, idealWidth: 220)
          taskDetail
            .frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  @ViewBuilder private var taskDetail: some View {
    if let task = selectedTask {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            CodexTaskStatusLabel(status: task.status)
            Spacer()
            if task.status == .running {
              Button("キャンセル", systemImage: "stop.fill") {
                Task { await cancel(task.id) }
              }
            }
          }
          GroupBox("指示") {
            Text(task.request.prompt).frame(maxWidth: .infinity, alignment: .leading)
              .textSelection(.enabled)
          }
          GroupBox("実行設定") {
            VStack(alignment: .leading, spacing: 4) {
              Text("実行AI: \(task.request.provider.name)")
              Text("モデル: \(task.request.model ?? "既定値")")
              Text("アクセス: \(task.request.sandboxMode == .readOnly ? "読み取り専用" : "作業フォルダへ書き込み")")
              Text("作業フォルダ: \(task.request.workingDirectory)")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
          }
          if let result = task.result {
            GroupBox("結果") {
              Text(result).frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
          }
          if let error = task.error {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
          }
          if !task.progress.isEmpty {
            GroupBox("進行状況") {
              VStack(alignment: .leading, spacing: 7) {
                ForEach(task.progress.suffix(50)) { event in
                  VStack(alignment: .leading, spacing: 2) {
                    Text(event.kind).font(.caption.bold()).foregroundStyle(.secondary)
                    Text(event.message).textSelection(.enabled)
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
          }
        }
        .padding(.leading, 14)
      }
    } else {
      ContentUnavailableView("タスクを選択", systemImage: "list.bullet.rectangle")
    }
  }

  private var writeAccessDescription: String {
    if selectedProvider == .antigravity {
      return "Antigravityが権限確認を自動承認し、選択した作業フォルダを変更できます。"
    }
    return "\(selectedProvider.name)が選択した作業フォルダ内のファイルを変更できます。"
  }

  private func chooseWorkingDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "選択"
    if panel.runModal() == .OK, let url = panel.url { workingDirectory = url.path }
  }
}

private struct CodexTaskStatusLabel: View {
  let status: CodexTaskStatus

  var body: some View {
    Label(title, systemImage: icon)
      .font(.caption.bold())
      .foregroundStyle(color)
  }

  private var title: String {
    switch status {
    case .running: return "実行中"
    case .completed: return "完了"
    case .failed: return "失敗"
    case .cancelled: return "キャンセル"
    case .timedOut: return "タイムアウト"
    }
  }

  private var icon: String {
    switch status {
    case .running: return "hourglass"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.octagon.fill"
    case .cancelled: return "stop.circle.fill"
    case .timedOut: return "clock.badge.exclamationmark.fill"
    }
  }

  private var color: Color {
    switch status {
    case .running: return .blue
    case .completed: return .green
    case .failed, .timedOut: return .red
    case .cancelled: return .secondary
    }
  }
}

private struct ProductProfilesView: View {
  @Binding var profiles: [ProductProfile]
  @Binding var defaultProfileID: UUID?
  let selectedProfileID: UUID?
  let providerOptions: [ProviderOption]
  @State private var editingProfileID: UUID?
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "Profiles")
      HStack(alignment: .top, spacing: 16) {
        VStack(spacing: 8) {
          List(selection: $editingProfileID) {
            ForEach(profiles) { profile in
              HStack {
                Text(profile.name)
                Spacer()
                if profile.id == defaultProfileID {
                  Image(systemName: "star.fill").foregroundStyle(.secondary)
                }
                if profile.id == selectedProfileID {
                  Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
              }
              .tag(Optional(profile.id))
            }
          }
          .frame(width: 230)

          HStack {
            Button("追加", systemImage: "plus") { addProfile() }
            Button("複製", systemImage: "plus.square.on.square") { duplicateProfile() }
              .disabled(editingProfileID == nil)
            Button("削除", systemImage: "trash") { deleteProfile() }
              .disabled(profiles.count <= 1 || editingProfileID == nil)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.bordered)
        }

        Divider()

        if let index = editingIndex {
          profileEditor(profile: $profiles[index])
        } else {
          ContentUnavailableView("Profileを選択してください", systemImage: "person.crop.square")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
    .padding(20)
    .onAppear { editingProfileID = selectedProfileID ?? profiles.first?.id }
  }

  private var editingIndex: Int? {
    guard let editingProfileID else { return nil }
    return profiles.firstIndex { $0.id == editingProfileID }
  }

  @ViewBuilder private func profileEditor(profile: Binding<ProductProfile>) -> some View {
    Form {
      Section("基本設定") {
        TextField("Profile名", text: profile.name)
        Picker("Provider", selection: profile.providerID) {
          ForEach(providerOptions, id: \.id) { option in
            Text(option.name).tag(option.id)
          }
        }
        TextField("Base URL", text: profile.baseURL)
          .disabled(profile.wrappedValue.providerID == "apple-foundation-models")
        TextField("Model ID", text: profile.modelID)
          .disabled(profile.wrappedValue.providerID == "apple-foundation-models")
        Button(
          profile.wrappedValue.id == defaultProfileID ? "既定のProfile" : "既定に設定",
          systemImage: profile.wrappedValue.id == defaultProfileID ? "star.fill" : "star"
        ) {
          defaultProfileID = profile.wrappedValue.id
        }
        .disabled(profile.wrappedValue.id == defaultProfileID)
      }

      Section("会話") {
        TextEditor(text: profile.systemInstructions)
          .frame(minHeight: 82)
        Picker("RAGモード", selection: profile.ragMode) {
          Text("使用しない").tag(RAGMode.disabled)
          Text("常に検索").tag(RAGMode.always)
          Text("AIが判断").tag(RAGMode.agentic)
        }
        Stepper(
          "コンテキスト上限: \(profile.wrappedValue.contextLimit)文字",
          value: profile.contextLimit, in: 2_000...50_000, step: 500)
      }

      Section("検索") {
        Stepper(
          "取得数: \(profile.wrappedValue.searchSettings.limit)",
          value: searchLimitBinding(profile), in: 1...20)
        Stepper(
          "最低スコア: \(profile.wrappedValue.searchSettings.minScore)",
          value: searchMinScoreBinding(profile), in: 0...1_000)
        HStack {
          TextField(
            "Keyword重み", value: searchKeywordWeightBinding(profile),
            format: .number.precision(.fractionLength(1)))
          TextField(
            "Embedding重み", value: searchEmbeddingWeightBinding(profile),
            format: .number.precision(.fractionLength(1)))
        }
      }
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func searchLimitBinding(_ profile: Binding<ProductProfile>) -> Binding<Int> {
    Binding(
      get: { profile.wrappedValue.searchSettings.limit },
      set: { value in updateSearchSettings(profile) { $0.limit = value } })
  }

  private func searchMinScoreBinding(_ profile: Binding<ProductProfile>) -> Binding<Int> {
    Binding(
      get: { profile.wrappedValue.searchSettings.minScore },
      set: { value in updateSearchSettings(profile) { $0.minScore = value } })
  }

  private func searchKeywordWeightBinding(_ profile: Binding<ProductProfile>) -> Binding<Double> {
    Binding(
      get: { profile.wrappedValue.searchSettings.keywordWeight },
      set: { value in updateSearchSettings(profile) { $0.keywordWeight = value } })
  }

  private func searchEmbeddingWeightBinding(_ profile: Binding<ProductProfile>) -> Binding<Double> {
    Binding(
      get: { profile.wrappedValue.searchSettings.embeddingWeight },
      set: { value in updateSearchSettings(profile) { $0.embeddingWeight = value } })
  }

  private func updateSearchSettings(
    _ profile: Binding<ProductProfile>, update: (inout SearchSettingsDraft) -> Void
  ) {
    var draft = SearchSettingsDraft(profile.wrappedValue.searchSettings)
    update(&draft)
    profile.wrappedValue.searchSettings = KnowledgeSearchSettings(
      limit: draft.limit, minScore: draft.minScore,
      keywordWeight: max(0, draft.keywordWeight),
      embeddingWeight: max(0, draft.embeddingWeight))
  }

  private func addProfile() {
    let profile = ProductProfile(name: "新しいProfile", providerID: "apple-foundation-models")
    profiles.append(profile)
    editingProfileID = profile.id
  }

  private func duplicateProfile() {
    guard let index = editingIndex else { return }
    let source = profiles[index]
    let copy = ProductProfile(
      name: "\(source.name) のコピー", providerID: source.providerID,
      baseURL: source.baseURL, modelID: source.modelID,
      systemInstructions: source.systemInstructions, ragMode: source.ragMode,
      searchSettings: source.searchSettings, contextLimit: source.contextLimit)
    profiles.append(copy)
    editingProfileID = copy.id
  }

  private func deleteProfile() {
    guard profiles.count > 1, let id = editingProfileID else { return }
    profiles.removeAll { $0.id == id }
    if defaultProfileID == id { defaultProfileID = profiles.first?.id }
    editingProfileID = profiles.first?.id
  }

  private struct SearchSettingsDraft {
    var limit: Int
    var minScore: Int
    var keywordWeight: Double
    var embeddingWeight: Double

    init(_ settings: KnowledgeSearchSettings) {
      limit = settings.limit
      minScore = settings.minScore
      keywordWeight = settings.keywordWeight
      embeddingWeight = settings.embeddingWeight
    }
  }
}

private struct KnowledgeMatchesView: View {
  let query: String
  let matches: [KnowledgeChunkMatch]
  let useSelected: ([KnowledgeChunkMatch]) -> Void
  let rateMatch: (KnowledgeChunkMatch, KnowledgeSearchFeedback.Rating) -> Void
  let showCitation: (KnowledgeChunkMatch) -> Void
  @State private var recordedFeedback: String?
  @State private var selectedIDs: Set<String> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "関連チャンク")
      Text("検索: \(query)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      HStack {
        Text("回答に使うチャンクを最大3件選択")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("選択した\(selectedIDs.count)件を次の質問に使う") {
          useSelected(matches.filter { selectedIDs.contains($0.id) })
        }
        .disabled(selectedIDs.isEmpty)
      }
      if let recordedFeedback {
        Text(recordedFeedback)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if matches.isEmpty {
        ContentUnavailableView("一致する資料がありません", systemImage: "doc.text.magnifyingglass")
      } else {
        List(matches) { match in
          VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
              Button {
                if !selectedIDs.insert(match.id).inserted { selectedIDs.remove(match.id) }
              } label: {
                Image(systemName: selectedIDs.contains(match.id) ? "checkmark.square.fill" : "square")
              }
              .buttonStyle(.plain)
              .disabled(!selectedIDs.contains(match.id) && selectedIDs.count >= 3)
              .accessibilityLabel(selectedIDs.contains(match.id) ? "選択を解除" : "回答に使う")
              Text("[\(match.citationIndex)] \(match.title) #\(match.chunkIndex)")
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
              Spacer()
              Button("開く", systemImage: "arrow.up.right.square") {
                showCitation(match)
              }
              Button("良い", systemImage: "hand.thumbsup") {
                rateMatch(match, .good)
                recordedFeedback = "[\(match.citationIndex)] を良い検索結果として記録しました。"
              }
              Button("違う", systemImage: "hand.thumbsdown") {
                rateMatch(match, .bad)
                recordedFeedback = "[\(match.citationIndex)] を違う検索結果として記録しました。"
              }
              SearchModeBadge(mode: match.searchMode)
              Text("score \(match.score)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SearchDiagnosticsSummary(diagnostics: match.diagnostics)
            Text(match.text)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
          .padding(.vertical, 4)
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct KnowledgeSelectionHistoryView: View {
  let entries: [KnowledgeSelectionHistory]
  let reuse: (KnowledgeSelectionHistory) -> Void
  let togglePinned: (KnowledgeSelectionHistory) -> Void
  let delete: (KnowledgeSelectionHistory) -> Void
  let addEvaluationCase: (KnowledgeSelectionHistory) -> Void
  @State private var searchText = ""

  private var filteredEntries: [KnowledgeSelectionHistory] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !query.isEmpty else { return entries }
    return entries.filter { entry in
      entry.query.lowercased().contains(query)
        || entry.matches.contains {
          $0.title.lowercased().contains(query) || $0.text.lowercased().contains(query)
        }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "チャンク選択履歴")

      TextField("検索語、資料名、本文で絞り込み", text: $searchText)
        .textFieldStyle(.roundedBorder)

      if filteredEntries.isEmpty {
        ContentUnavailableView(
          entries.isEmpty ? "選択履歴がありません" : "一致する履歴がありません",
          systemImage: "clock.arrow.circlepath"
        )
      } else {
        List(filteredEntries) { entry in
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              if entry.isPinned {
                Image(systemName: "pin.fill")
                  .foregroundStyle(.tint)
                  .accessibilityLabel("固定済み")
              }
              Text(entry.query)
                .font(.headline)
                .lineLimit(1)
              Spacer()
              Text(entry.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(entry.createdAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
              Button(entry.isPinned ? "固定解除" : "固定", systemImage: entry.isPinned ? "pin.slash" : "pin") {
                togglePinned(entry)
              }
              Button("再選択", systemImage: "arrow.uturn.backward") {
                reuse(entry)
              }
              Button("評価ケース", systemImage: "chart.bar.xaxis") {
                addEvaluationCase(entry)
              }
              Button("削除", systemImage: "trash") {
                delete(entry)
              }
            }

            ForEach(entry.matches) { match in
              Text("[\(match.citationIndex)] \(match.title) #\(match.chunkIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .padding(.vertical, 5)
        }
      }
    }
    .padding(20)
  }
}

private struct RAGEvaluationView: View {
  let cases: [RAGEvaluationCase]
  let documents: [KnowledgeDocumentSummary]
  let profiles: [RAGEvaluationProfile]
  let reports: [RAGEvaluationReport]
  let suites: [RAGEvaluationSuite]
  let selectedSuiteID: UUID?
  let automationSettings: RAGEvaluationAutomationSettings
  let runningCaseIDs: Set<UUID>
  let matrixRunning: Bool
  let matrixProgress: String?
  let runAll: () -> Void
  let run: (RAGEvaluationCase) -> Void
  let importCases: ([RAGEvaluationCase]) -> RAGEvaluationImportSummary
  let registerCurrentEnvironment: () -> Void
  let updateProfile: (RAGEvaluationProfile) -> Void
  let deleteProfile: (RAGEvaluationProfile) -> Void
  let runMatrix: () -> Void
  let selectSuite: (UUID?) -> Void
  let createSuite: () -> Void
  let updateSuite: (RAGEvaluationSuite) -> Void
  let deleteSuite: (RAGEvaluationSuite) -> Void
  let toggleCaseInSuite: (RAGEvaluationCase, RAGEvaluationSuite) -> Void
  let updateAutomationSettings: (RAGEvaluationAutomationSettings) -> Void
  let updateCriteria: (RAGEvaluationCase, RAGEvaluationCriteria) -> Void
  let updateExpectedSearch: (RAGEvaluationCase, Bool) -> Void
  let addNoSearchCase: (String) -> Void
  let updateAnswerRules: (RAGEvaluationCase, [String], [String]) -> Void
  let updateTags: (RAGEvaluationCase, [String]) -> Void
  let suggestAnswerPoints: (RAGEvaluationCase) -> Void
  let duplicate: (RAGEvaluationCase) -> Void
  let generateCandidates: (KnowledgeDocumentSummary) async -> [RAGEvaluationGeneratedCandidate]
  let addGeneratedCandidates: ([RAGEvaluationGeneratedCandidate]) -> Void
  let setBaseline: (RAGEvaluationCase, RAGEvaluationRun) -> Void
  let delete: (RAGEvaluationCase) -> Void
  @State private var exportMessage: String?
  @State private var noSearchQuestion = ""

  private var selectedSuite: RAGEvaluationSuite? {
    suites.first { $0.id == selectedSuiteID }
  }

  private var visibleCases: [RAGEvaluationCase] {
    guard let selectedSuite else { return cases }
    let ids = Set(selectedSuite.caseIDs)
    return cases.filter { ids.contains($0.id) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "RAG評価")
      HStack {
        Text("評価ケースを一括実行し、保存した基準結果と品質・速度を比較できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("全件実行", systemImage: "play.fill") { runAll() }
          .disabled(visibleCases.isEmpty || !runningCaseIDs.isEmpty || matrixRunning)
        Button("JSON取込", systemImage: "square.and.arrow.down") { importJSON() }
        Button("JSON書き出し", systemImage: "square.and.arrow.up") { exportJSON() }
          .disabled(cases.isEmpty)
        Button("CSV書き出し", systemImage: "tablecells") { exportCSV() }
          .disabled(cases.isEmpty)
      }

      if let exportMessage {
        Text(exportMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        TextField("検索不要ケースの質問（例: こんにちは）", text: $noSearchQuestion)
          .textFieldStyle(.roundedBorder)
        Button("検索不要ケースを追加", systemImage: "plus") {
          addNoSearchCase(noSearchQuestion)
          noSearchQuestion = ""
        }
        .disabled(noSearchQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }

      RAGEvaluationSuiteView(
        suites: suites, selectedSuiteID: selectedSuiteID, cases: cases,
        select: selectSuite, create: createSuite, update: updateSuite,
        delete: deleteSuite, toggleCase: toggleCaseInSuite)

      RAGEvaluationCoverageView(documents: documents, cases: cases, suites: suites)

      RAGEvaluationCandidateGeneratorView(
        documents: documents, generate: generateCandidates, add: addGeneratedCandidates)

      RAGEvaluationMatrixView(
        profiles: profiles, hasCases: !visibleCases.isEmpty, isRunning: matrixRunning,
        progress: matrixProgress, registerCurrent: registerCurrentEnvironment,
        update: updateProfile, delete: deleteProfile, run: runMatrix)

      RAGEvaluationAutomationView(
        settings: automationSettings,
        canRun: !visibleCases.isEmpty && profiles.contains(where: \.isSelected),
        update: updateAutomationSettings)

      if !reports.isEmpty {
        RAGEvaluationReportsView(reports: reports)
      }

      if visibleCases.contains(where: { !$0.runs.isEmpty }) {
        RAGEvaluationDashboardView(cases: visibleCases)
      }

      let regressions = RAGEvaluationRegressionAlert.alerts(in: cases)
      if !regressions.isEmpty {
        RAGEvaluationRegressionAlertsView(alerts: regressions)
      }

      if visibleCases.isEmpty {
        ContentUnavailableView(
          selectedSuite == nil ? "評価ケースがありません" : "スイートに評価ケースがありません",
          systemImage: "chart.bar.xaxis",
          description: Text(
            selectedSuite == nil
              ? "選択履歴の「評価ケース」から追加してください。"
              : "上の「ケースを選択」から、このスイートに含めるケースを選んでください。")
        )
      } else {
        List(visibleCases) { evaluationCase in
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(evaluationCase.question)
                .font(.headline)
              Spacer()
              if runningCaseIDs.contains(evaluationCase.id) {
                ProgressView().controlSize(.small)
              }
              Button("実行", systemImage: "play.fill") {
                run(evaluationCase)
              }
              .disabled(!runningCaseIDs.isEmpty || matrixRunning)
              Button("複製", systemImage: "plus.square.on.square") {
                duplicate(evaluationCase)
              }
              .disabled(matrixRunning)
              Button("削除", systemImage: "trash") {
                delete(evaluationCase)
              }
              .disabled(runningCaseIDs.contains(evaluationCase.id) || matrixRunning)
            }

            TextField(
              "タグ（カンマ区切り）",
              text: Binding(
                get: { evaluationCase.tags.joined(separator: ", ") },
                set: { updateTags(evaluationCase, Self.tags(from: $0)) }))
              .font(.caption)
              .textFieldStyle(.roundedBorder)

            Toggle(
              "この質問では資料検索が必要",
              isOn: Binding(
                get: { evaluationCase.expectedSearch },
                set: { updateExpectedSearch(evaluationCase, $0) }))
              .toggleStyle(.checkbox)
              .font(.caption)

            Text(evaluationCase.expectedSearch ? "期待する根拠" : "検索不要ケース")
              .font(.caption.bold())
              .foregroundStyle(.secondary)
            ForEach(evaluationCase.expectedMatches) { match in
              Text("• \(match.title) #\(match.chunkIndex)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if !evaluationCase.expectedSearch {
              Text("Agentic RAGが検索を省略すれば検索判断は合格です。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            RAGEvaluationAnswerRulesView(
              expectedPoints: evaluationCase.expectedAnswerPoints,
              forbiddenPhrases: evaluationCase.forbiddenAnswerPhrases,
              update: { expectedPoints, forbiddenPhrases in
                updateAnswerRules(evaluationCase, expectedPoints, forbiddenPhrases)
              })
            Button("最新回答から要点候補を作成", systemImage: "wand.and.stars") {
              suggestAnswerPoints(evaluationCase)
            }
            .font(.caption)
            .disabled(evaluationCase.runs.isEmpty || matrixRunning)

            Text("合格基準")
              .font(.caption.bold())
            RAGEvaluationCriteriaView(
              criteria: evaluationCase.criteria,
              update: { updateCriteria(evaluationCase, $0) })

            if evaluationCase.runs.isEmpty {
              Text("まだ実行されていません")
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else {
              let baseline = evaluationCase.runs.first {
                $0.id == evaluationCase.baselineRunID
              }
              ForEach(evaluationCase.runs) { evaluationRun in
                RAGEvaluationRunView(
                  run: evaluationRun,
                  criteria: evaluationCase.criteria,
                  baseline: baseline,
                  isBaseline: evaluationRun.id == evaluationCase.baselineRunID,
                  setBaseline: { setBaseline(evaluationCase, evaluationRun) })
              }
            }
          }
          .padding(.vertical, 6)
        }
      }
    }
    .padding(20)
  }

  private static func tags(from text: String) -> [String] {
    var seen: Set<String> = []
    return text.split(whereSeparator: { $0 == "," || $0 == "、" }).compactMap {
      let tag = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return tag.isEmpty || !seen.insert(tag).inserted ? nil : tag
    }
  }

  private func exportJSON() {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let suite = RAGEvaluationSuiteFile(formatVersion: 1, exportedAt: Date(), cases: cases)
      try save(encoder.encode(suite), defaultName: "onigiri-rag-evaluation.json")
    } catch {
      exportMessage = "JSONを書き出せませんでした: \(error.localizedDescription)"
    }
  }

  private func importJSON() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let data = try Data(contentsOf: url)
      let importedCases = try decodeSuite(data)
      guard !importedCases.isEmpty else {
        exportMessage = "評価ケースが含まれていません。"
        return
      }
      let summary = importCases(importedCases)
      exportMessage = summary.skippedCount == 0
        ? "\(summary.importedCount)件の評価ケースを取り込みました。"
        : "\(summary.importedCount)件を取り込み、現在の資料に対応しない\(summary.skippedCount)件を除外しました。"
    } catch {
      exportMessage = "JSONを取り込めませんでした: \(error.localizedDescription)"
    }
  }

  private func decodeSuite(_ data: Data) throws -> [RAGEvaluationCase] {
    let isoDecoder = JSONDecoder()
    isoDecoder.dateDecodingStrategy = .iso8601
    if let suite = try? isoDecoder.decode(RAGEvaluationSuiteFile.self, from: data) {
      return suite.cases
    }
    if let legacyExport = try? isoDecoder.decode([RAGEvaluationCase].self, from: data) {
      return legacyExport
    }
    return try JSONDecoder().decode([RAGEvaluationCase].self, from: data)
  }

  private func exportCSV() {
    var rows = [
      [
        "case_id", "question", "expected_chunk_ids", "run_id", "created_at", "provider",
        "provider_id", "base_url", "model", "rag_mode", "expected_search",
        "did_search", "search_decision_correct", "agentic_queries", "diagnostics",
        "search_limit", "search_min_score",
        "keyword_weight", "embedding_weight", "passed", "baseline", "expected_ranks", "retrieval_recall",
        "citation_precision", "citation_recall", "expected_answer_points",
        "forbidden_answer_phrases", "answer_point_coverage", "grounded_answer_point_coverage",
        "forbidden_phrase_hits", "retrieval_ms", "generation_ms", "total_ms", "answer",
      ].map(csvField).joined(separator: ",")
    ]
    let formatter = ISO8601DateFormatter()
    for evaluationCase in cases {
      for run in evaluationCase.runs {
        let fields: [String] = [
          evaluationCase.id.uuidString,
          evaluationCase.question,
          evaluationCase.expectedMatches.map(\.id).joined(separator: " | "),
          run.id.uuidString,
          formatter.string(from: run.createdAt),
          run.result.providerName,
          run.environment?.providerID ?? run.result.providerID,
          run.environment?.baseURL ?? "",
          run.result.modelID ?? "",
          run.result.ragMode.rawValue,
          String(run.result.expectedSearch),
          String(run.result.didSearch),
          String(run.result.searchDecisionCorrect),
          run.result.agenticTrace?.queries.joined(separator: " | ") ?? "",
          run.result.diagnostics.map { $0.title }.joined(separator: " | "),
          run.environment.map { String($0.searchSettings.limit) } ?? "",
          run.environment.map { String($0.searchSettings.minScore) } ?? "",
          run.environment.map { String($0.searchSettings.keywordWeight) } ?? "",
          run.environment.map { String($0.searchSettings.embeddingWeight) } ?? "",
          run.result.passes(evaluationCase.criteria) ? "true" : "false",
          run.id == evaluationCase.baselineRunID ? "true" : "false",
          run.result.expectedRanks.map { $0.rank.map(String.init) ?? "outside" }
            .joined(separator: " | "),
          String(run.result.retrievalRecall),
          String(run.result.citationPrecision),
          String(run.result.citationRecall),
          evaluationCase.expectedAnswerPoints.joined(separator: " | "),
          evaluationCase.forbiddenAnswerPhrases.joined(separator: " | "),
          String(run.result.answerPointCoverage),
          String(run.result.groundedAnswerPointCoverage),
          run.result.forbiddenPhraseHits.joined(separator: " | "),
          String(run.result.retrievalMilliseconds),
          String(run.result.generationMilliseconds),
          String(run.result.totalMilliseconds),
          run.result.answer,
        ]
        rows.append(fields.map(csvField).joined(separator: ","))
      }
    }
    do {
      try save(Data(rows.joined(separator: "\n").utf8), defaultName: "onigiri-rag-evaluation.csv")
    } catch {
      exportMessage = "CSVを書き出せませんでした: \(error.localizedDescription)"
    }
  }

  private func csvField(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }

  private func save(_ data: Data, defaultName: String) throws {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultName
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try data.write(to: url, options: .atomic)
    exportMessage = "\(url.lastPathComponent) を書き出しました。"
  }
}

private struct RAGEvaluationCoverageView: View {
  let documents: [KnowledgeDocumentSummary]
  let cases: [RAGEvaluationCase]
  let suites: [RAGEvaluationSuite]
  @State private var isExpanded = true

  private var coverage: RAGEvaluationCoverageReport {
    let coverageDocuments = documents.map { document in
      RAGEvaluationCoverageDocument(
        id: document.id, title: document.title,
        chunkIDs: (0..<document.chunkCount).map { "\(document.id.uuidString)-\($0)" })
    }
    let coverageCases = cases.map { evaluationCase in
      RAGEvaluationCoverageCase(
        id: evaluationCase.id, question: evaluationCase.question,
        expectedChunkIDs: evaluationCase.expectedMatches.map(\.id),
        retrievedChunkIDs: Array(Set(evaluationCase.runs.flatMap { $0.result.matches.map(\.id) })),
        tags: evaluationCase.tags,
        suiteIDs: suites.filter { $0.caseIDs.contains(evaluationCase.id) }.map(\.id))
    }
    return RAGEvaluationCoverageAnalyzer.analyze(
      documents: coverageDocuments, cases: coverageCases,
      suiteNames: Dictionary(uniqueKeysWithValues: suites.map { ($0.id, $0.name) }))
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          metric(
            title: "資料", value: coverage.documentCoverage,
            detail: "\(coverage.coveredDocumentCount)/\(coverage.documentCount)件")
          metric(
            title: "期待チャンク", value: coverage.expectedChunkCoverage,
            detail: "\(coverage.expectedChunkCount)/\(coverage.chunkCount)件")
          metric(
            title: "検索到達", value: coverage.retrievalCoverage,
            detail: "\(coverage.retrievedChunkCount)/\(coverage.chunkCount)件")
        }

        if !coverage.uncoveredDocuments.isEmpty {
          Label(
            "未評価の資料: \(coverage.uncoveredDocuments.map(\.title).joined(separator: "、"))",
            systemImage: "doc.badge.ellipsis")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
        }

        if coverage.chunkCount > 0 {
          Text("検索に一度も現れていないチャンク: \(coverage.neverRetrievedChunkIDs.count)件")
            .font(.caption)
            .foregroundStyle(
              coverage.neverRetrievedChunkIDs.isEmpty ? Color.secondary : Color.orange)
        }

        if !coverage.tagGroups.isEmpty || !coverage.suiteGroups.isEmpty {
          HStack(alignment: .top, spacing: 18) {
            if !coverage.tagGroups.isEmpty {
              groupSummary("タグ", groups: coverage.tagGroups)
            }
            if !coverage.suiteGroups.isEmpty {
              groupSummary("スイート", groups: coverage.suiteGroups)
            }
          }
        }

        if !coverage.duplicateCases.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            Label("重複候補 \(coverage.duplicateCases.count)組", systemImage: "square.on.square")
              .font(.caption.bold())
            ForEach(coverage.duplicateCases.prefix(5)) { duplicate in
              Text(
                "• \(duplicate.firstQuestion) / \(duplicate.secondQuestion)（\(percent(duplicate.similarity))）")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Text("評価カバレッジ").font(.headline)
    }
  }

  private func metric(title: String, value: Double, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title).font(.caption.bold())
        Spacer()
        Text(percent(value)).font(.caption).monospacedDigit()
      }
      ProgressView(value: value)
      Text(detail).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private func groupSummary(_ title: String, groups: [RAGEvaluationCoverageGroup]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.caption.bold())
      ForEach(groups.prefix(8)) { group in
        Text("\(group.name): \(group.caseCount)ケース / \(group.documentCount)資料")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }
}

private struct RAGEvaluationCandidateGeneratorView: View {
  let documents: [KnowledgeDocumentSummary]
  let generate: (KnowledgeDocumentSummary) async -> [RAGEvaluationGeneratedCandidate]
  let add: ([RAGEvaluationGeneratedCandidate]) -> Void
  @State private var isExpanded = false
  @State private var selectedDocumentID: UUID?
  @State private var candidateCount = 5
  @State private var candidates: [RAGEvaluationGeneratedCandidate] = []
  @State private var selectedCandidateIDs: Set<String> = []
  @State private var isGenerating = false
  @State private var message: String?

  private var selectedDocument: KnowledgeDocumentSummary? {
    documents.first { $0.id == selectedDocumentID } ?? documents.first
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Picker(
            "資料",
            selection: Binding(
              get: { selectedDocument?.id },
              set: { selectedDocumentID = $0; candidates = []; message = nil })
          ) {
            ForEach(documents) { document in
              Text(document.title).tag(Optional(document.id))
            }
          }
          .frame(maxWidth: 420)
          Stepper("\(candidateCount)件", value: $candidateCount, in: 1...20)
            .fixedSize()
          Button("候補を作成", systemImage: "wand.and.stars") {
            guard let document = selectedDocument else { return }
            isGenerating = true
            message = nil
            Task {
              let generated = await generate(document)
              candidates = Self.evenlySpaced(generated, count: candidateCount)
              selectedCandidateIDs = Set(candidates.map(\.id))
              message = candidates.isEmpty
                ? "この資料には未評価のチャンクがありません。"
                : "未評価チャンクから\(candidates.count)件の候補を作成しました。"
              isGenerating = false
            }
          }
          .disabled(documents.isEmpty || isGenerating)
          Button("全資料から一括作成", systemImage: "square.stack.3d.up") {
            isGenerating = true
            message = nil
            Task {
              var generated: [RAGEvaluationGeneratedCandidate] = []
              for document in documents {
                generated.append(contentsOf: await generate(document))
              }
              candidates = Self.evenlySpaced(generated, count: candidateCount)
              selectedCandidateIDs = Set(candidates.map(\.id))
              message = candidates.isEmpty
                ? "未評価のチャンクはありません。"
                : "カバレッジがないチャンクから\(candidates.count)件を一括生成しました。"
              isGenerating = false
            }
          }
          .disabled(documents.isEmpty || isGenerating)
          if isGenerating { ProgressView().controlSize(.small) }
          Spacer()
          Button("選択した\(selectedCandidateIDs.count)件を追加", systemImage: "plus") {
            let selected = candidates.filter { selectedCandidateIDs.contains($0.id) }
            add(selected)
            candidates = []
            selectedCandidateIDs = []
            message = "\(selected.count)件を評価ケースへ追加しました。"
          }
          .disabled(selectedCandidateIDs.isEmpty || isGenerating)
        }

        if let message {
          Text(message).font(.caption).foregroundStyle(.secondary)
        }

        ForEach(candidates) { candidate in
          HStack(alignment: .top, spacing: 8) {
            Toggle(
              "選択",
              isOn: Binding(
                get: { selectedCandidateIDs.contains(candidate.id) },
                set: { selected in
                  if selected { selectedCandidateIDs.insert(candidate.id) }
                  else { selectedCandidateIDs.remove(candidate.id) }
                }))
              .labelsHidden()
              .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
              Text(candidate.question).font(.caption.bold()).lineLimit(1)
              Text("#\(candidate.expectedMatch.chunkIndex) • \(candidate.expectedAnswerPoint)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Text("資料から評価ケース候補を作成").font(.headline)
    }
  }

  private static func evenlySpaced(
    _ candidates: [RAGEvaluationGeneratedCandidate], count: Int
  ) -> [RAGEvaluationGeneratedCandidate] {
    guard candidates.count > count else { return candidates }
    return (0..<count).map { offset in
      let index = Int(Double(offset) * Double(candidates.count) / Double(count))
      return candidates[index]
    }
  }
}

private struct RAGEvaluationSuiteView: View {
  let suites: [RAGEvaluationSuite]
  let selectedSuiteID: UUID?
  let cases: [RAGEvaluationCase]
  let select: (UUID?) -> Void
  let create: () -> Void
  let update: (RAGEvaluationSuite) -> Void
  let delete: (RAGEvaluationSuite) -> Void
  let toggleCase: (RAGEvaluationCase, RAGEvaluationSuite) -> Void

  private var selectedSuite: RAGEvaluationSuite? {
    suites.first { $0.id == selectedSuiteID }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("評価スイート").font(.headline)
        Picker(
          "評価スイート",
          selection: Binding(get: { selectedSuiteID }, set: select)
        ) {
          Text("すべてのケース").tag(Optional<UUID>.none)
          ForEach(suites) { suite in
            Text(suite.name).tag(Optional(suite.id))
          }
        }
        .labelsHidden()
        .frame(maxWidth: 230)
        Button("追加", systemImage: "plus") { create() }
        if let suite = selectedSuite {
          TextField(
            "スイート名",
            text: Binding(
              get: { suite.name },
              set: { value in
                var changed = suite
                changed.name = value
                update(changed)
              }))
            .frame(maxWidth: 220)
          Menu("ケースを選択", systemImage: "checklist") {
            if cases.isEmpty {
              Text("評価ケースがありません")
            } else {
              ForEach(cases) { evaluationCase in
                let included = suite.caseIDs.contains(evaluationCase.id)
                Button {
                  toggleCase(evaluationCase, suite)
                } label: {
                  Label(
                    evaluationCase.question,
                    systemImage: included ? "checkmark.circle.fill" : "circle")
                }
              }
            }
          }
          Button("削除", systemImage: "trash") { delete(suite) }
            .labelStyle(.iconOnly)
        }
        Spacer()
      }
      Text(selectedSuite.map { "\($0.caseIDs.count)件のケースを実行対象にしています。" }
        ?? "全評価ケースを実行対象にしています。")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct RAGEvaluationAutomationView: View {
  let settings: RAGEvaluationAutomationSettings
  let canRun: Bool
  let update: (RAGEvaluationAutomationSettings) -> Void

  var body: some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 16) {
          Toggle("毎日自動実行", isOn: binding(\.isEnabled))
            .toggleStyle(.checkbox)
          DatePicker(
            "実行時刻", selection: scheduledTime,
            displayedComponents: [.hourAndMinute])
            .disabled(!settings.isEnabled)
          Stepper("保持 \(settings.retentionDays)日", value: binding(\.retentionDays), in: 1...365)
          Toggle("回帰を通知", isOn: binding(\.notifyOnRegression))
            .toggleStyle(.checkbox)
        }
        if settings.isEnabled && !canRun {
          Text("自動実行には、評価ケースと選択済みの評価環境が必要です。")
            .font(.caption).foregroundStyle(.orange)
        } else if let lastRun = settings.lastScheduledRunAt {
          Text("前回の自動実行: \(lastRun.formatted(date: .abbreviated, time: .shortened))")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("アプリの起動中に指定時刻を過ぎると、1日1回実行します。")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
    } label: {
      Label("自動評価", systemImage: "clock.badge.checkmark")
        .font(.headline)
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<RAGEvaluationAutomationSettings, Value>)
    -> Binding<Value>
  {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { value in
        var changed = settings
        changed[keyPath: keyPath] = value
        update(changed)
      })
  }

  private var scheduledTime: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: settings.scheduledHour, minute: settings.scheduledMinute,
          second: 0, of: Date()) ?? Date()
      },
      set: { value in
        let components = Calendar.current.dateComponents([.hour, .minute], from: value)
        var changed = settings
        changed.scheduledHour = components.hour ?? settings.scheduledHour
        changed.scheduledMinute = components.minute ?? settings.scheduledMinute
        update(changed)
      })
  }
}

private struct RAGEvaluationReportsView: View {
  let reports: [RAGEvaluationReport]
  @State private var selectedReportID: UUID?
  @State private var failedOnly = false
  @State private var exportMessage: String?
  @State private var isExpanded = true

  private var orderedReports: [RAGEvaluationReport] {
    reports.sorted { $0.completedAt < $1.completedAt }
  }

  private var selectedReport: RAGEvaluationReport? {
    let id = selectedReportID ?? reports.first?.id
    return reports.first { $0.id == id }
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Picker("実行", selection: Binding(
            get: { selectedReportID ?? reports.first?.id },
            set: { selectedReportID = $0 }))
          {
            ForEach(reports) { report in
              Text("[\(report.trigger.label)] \(report.completedAt.formatted(date: .abbreviated, time: .shortened))")
                .tag(Optional(report.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: 230)
          Toggle("不合格のみ", isOn: $failedOnly)
            .toggleStyle(.checkbox)
          Spacer()
          Button("Markdown書き出し", systemImage: "doc.text") { exportMarkdown() }
        }

        HStack(spacing: 16) {
          metricChart(
            title: "合格率", values: orderedReports.map { $0.passRate * 100 },
            color: .green, suffix: "%")
          metricChart(
            title: "平均処理時間", values: orderedReports.map { Double($0.averageTotalMilliseconds) },
            color: .blue, suffix: "ms")
        }
        .frame(height: 92)

        if let report = selectedReport {
          let entries = failedOnly ? report.entries.filter { !$0.passed } : report.entries
          HStack(spacing: 14) {
            Text(report.trigger.label)
            if let suiteName = report.suiteName { Text("スイート: \(suiteName)") }
            Text("合格 \(report.passedCount)/\(report.entries.count)")
            Text("平均 \(report.averageTotalMilliseconds)ms")
            Text("検索判断 P \(report.searchDecisionPrecision.formatted(.percent.precision(.fractionLength(0)))) / R \(report.searchDecisionRecall.formatted(.percent.precision(.fractionLength(0))))")
            Text("誤検索 \(report.unnecessarySearchCount) / 漏れ \(report.missedSearchCount)")
            Text("環境 \(Set(report.entries.map(\.profileName)).count)件")
            if let snapshot = report.knowledgeSnapshot {
              Text("資料版 \(snapshot.versionID.prefix(8))")
            }
          }
          .font(.caption.bold())
          if let previous = reports
            .filter({ $0.completedAt < report.completedAt })
            .max(by: { $0.completedAt < $1.completedAt })
          {
            let regressions = report.regressions(comparedTo: previous)
            if !regressions.isEmpty {
              VStack(alignment: .leading, spacing: 3) {
                Label("前回からの回帰 \(regressions.count)件", systemImage: "exclamationmark.triangle.fill")
                  .font(.caption.bold()).foregroundStyle(.orange)
                ForEach(regressions) { regression in
                  Text("• \(regression.question) / \(regression.profileName): \(regression.detail)")
                    .font(.caption2).foregroundStyle(.red)
                }
              }
            }
            if let currentSnapshot = report.knowledgeSnapshot,
              let previousSnapshot = previous.knowledgeSnapshot
            {
              let knowledgeChanges = currentSnapshot.differences(comparedTo: previousSnapshot)
              if !knowledgeChanges.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                  Label("前回からの資料変更", systemImage: "doc.text.magnifyingglass")
                    .font(.caption.bold()).foregroundStyle(.blue)
                  ForEach(knowledgeChanges, id: \.self) { change in
                    Text("• \(change)").font(.caption2).foregroundStyle(.secondary)
                  }
                }
              }
            }
          }
          if entries.isEmpty {
            Text(failedOnly ? "不合格ケースはありません。" : "結果がありません。")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(entries) { entry in
                  HStack {
                    Image(systemName: entry.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                      .foregroundStyle(entry.passed ? .green : .red)
                    Text(entry.question).lineLimit(1)
                    Spacer()
                    Text(entry.profileName).foregroundStyle(.secondary).lineLimit(1)
                    Text("\(entry.result.totalMilliseconds)ms")
                      .monospacedDigit().foregroundStyle(.secondary)
                  }
                  .font(.caption)
                }
              }
            }
            .frame(maxHeight: 105)
          }
        }
        if let exportMessage {
          Text(exportMessage).font(.caption).foregroundStyle(.secondary)
        }
      }
      .padding(.top, 6)
    } label: {
      Text("実行レポート（\(reports.count)件）").font(.headline)
    }
  }

  private func metricChart(
    title: String, values: [Double], color: Color, suffix: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(title).font(.caption.bold())
        Spacer()
        if let value = values.last {
          Text("\(Int(value.rounded()))\(suffix)").font(.caption).monospacedDigit()
        }
      }
      Chart(Array(values.enumerated()), id: \.offset) { item in
        LineMark(x: .value("実行", item.offset + 1), y: .value(title, item.element))
          .foregroundStyle(color)
        PointMark(x: .value("実行", item.offset + 1), y: .value(title, item.element))
          .foregroundStyle(color)
      }
      .chartXAxis(.hidden)
      .chartYAxis(.hidden)
    }
    .padding(8)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private func exportMarkdown() {
    guard let report = selectedReport else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    panel.nameFieldStringValue = "onigiri-rag-report.md"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Data(report.markdown(failedOnly: failedOnly).utf8).write(to: url, options: .atomic)
      exportMessage = "\(url.lastPathComponent) を書き出しました。"
    } catch {
      exportMessage = "Markdownを書き出せませんでした: \(error.localizedDescription)"
    }
  }
}

private struct RAGEvaluationMatrixView: View {
  let profiles: [RAGEvaluationProfile]
  let hasCases: Bool
  let isRunning: Bool
  let progress: String?
  let registerCurrent: () -> Void
  let update: (RAGEvaluationProfile) -> Void
  let delete: (RAGEvaluationProfile) -> Void
  let run: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("モデルマトリクス").font(.headline)
        Spacer()
        Button("現在の環境を登録", systemImage: "plus") { registerCurrent() }
          .disabled(isRunning)
        Button("選択環境で全件実行", systemImage: "rectangle.stack.badge.play") { run() }
          .disabled(!hasCases || profiles.allSatisfy { !$0.isSelected } || isRunning)
      }
      if let progress {
        HStack(spacing: 6) {
          if isRunning { ProgressView().controlSize(.small) }
          Text(progress).font(.caption).foregroundStyle(.secondary)
        }
      }
      if profiles.isEmpty {
        Text("現在のモデルと検索設定を登録すると、複数環境を順番に評価できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(profiles) { profile in
              VStack(alignment: .leading, spacing: 5) {
                HStack {
                  Toggle(
                    "選択",
                    isOn: Binding(
                      get: { profile.isSelected },
                      set: { value in
                        var changed = profile
                        changed.isSelected = value
                        update(changed)
                      }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                  TextField(
                    "環境名",
                    text: Binding(
                      get: { profile.name },
                      set: { value in
                        var changed = profile
                        changed.name = value
                        update(changed)
                      }))
                    .textFieldStyle(.plain)
                    .font(.caption.bold())
                  Button("削除", systemImage: "trash") { delete(profile) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .disabled(isRunning)
                }
                Text(environmentLabel(profile.environment))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              .padding(8)
              .frame(width: 260, alignment: .leading)
              .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }
    }
  }

  private func environmentLabel(_ environment: RAGEvaluationEnvironment) -> String {
    let model = environment.modelID.flatMap { $0.isEmpty ? nil : $0 }
      ?? environment.providerName
    let settings = environment.searchSettings
    return "\(model) / \(environment.ragMode.displayName) / 上位\(settings.limit)件・閾値\(settings.minScore)・K \(settings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / E \(settings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))"
  }
}

private struct RAGEvaluationRegressionAlert: Identifiable {
  let id: String
  let question: String
  let detail: String

  static func alerts(in cases: [RAGEvaluationCase]) -> [Self] {
    cases.compactMap { evaluationCase in
      guard let baselineID = evaluationCase.baselineRunID,
        let baseline = evaluationCase.runs.first(where: { $0.id == baselineID }),
        let latest = evaluationCase.runs.first(where: { $0.id != baselineID })
      else { return nil }
      var changes: [String] = []
      if baseline.result.passes(evaluationCase.criteria)
        && !latest.result.passes(evaluationCase.criteria)
      {
        changes.append("合格から不合格")
      }
      if baseline.result.searchDecisionCorrect && !latest.result.searchDecisionCorrect {
        changes.append("検索判断が不一致")
      }
      appendDrop("検索", latest.result.retrievalRecall, baseline.result.retrievalRecall, to: &changes)
      appendDrop("引用", latest.result.citationRecall, baseline.result.citationRecall, to: &changes)
      appendDrop("要点", latest.result.answerPointCoverage, baseline.result.answerPointCoverage, to: &changes)
      appendDrop(
        "裏付け", latest.result.groundedAnswerPointCoverage,
        baseline.result.groundedAnswerPointCoverage, to: &changes)
      if latest.result.totalMilliseconds > max(
        baseline.result.totalMilliseconds + 250,
        Int(Double(baseline.result.totalMilliseconds) * 1.2))
      {
        changes.append("合計時間 +\(latest.result.totalMilliseconds - baseline.result.totalMilliseconds)ms")
      }
      guard !changes.isEmpty else { return nil }
      return Self(
        id: evaluationCase.id.uuidString, question: evaluationCase.question,
        detail: changes.joined(separator: " / "))
    }
  }

  private static func appendDrop(
    _ name: String, _ current: Double, _ baseline: Double, to changes: inout [String]
  ) {
    let drop = baseline - current
    if drop >= 0.01 { changes.append("\(name) -\(Int((drop * 100).rounded()))pt") }
  }
}

private struct RAGEvaluationRegressionAlertsView: View {
  let alerts: [RAGEvaluationRegressionAlert]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Label("回帰アラート", systemImage: "exclamationmark.triangle.fill")
        .font(.headline)
        .foregroundStyle(.orange)
      ForEach(alerts) { alert in
        Text("• \(alert.question): \(alert.detail)")
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .padding(10)
    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }
}

private struct RAGEvaluationEnvironmentSummary: Identifiable {
  let id: String
  let modelLabel: String
  let settingsLabel: String
  let runCount: Int
  let passRate: Double
  let retrievalRecall: Double
  let answerPointCoverage: Double
  let groundedAnswerPointCoverage: Double
  let totalMilliseconds: Int
}

private struct RAGEvaluationDashboardView: View {
  let cases: [RAGEvaluationCase]

  private var summaries: [RAGEvaluationEnvironmentSummary] {
    var grouped: [String: [(RAGEvaluationRun, RAGEvaluationCriteria)]] = [:]
    for evaluationCase in cases {
      for run in evaluationCase.runs {
        grouped[environmentKey(for: run), default: []].append((run, evaluationCase.criteria))
      }
    }
    return grouped.map { key, values in
      let first = values[0].0
      let count = Double(values.count)
      let environment = first.environment
      let baseModel = first.result.modelID.map { "\(first.result.providerName) / \($0)" }
        ?? first.result.providerName
      let model = "\(baseModel) [\(first.result.ragMode.displayName)]"
      let settings = environment.map {
        "上位\($0.searchSettings.limit)件・閾値\($0.searchSettings.minScore)・K \($0.searchSettings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / E \($0.searchSettings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))"
      } ?? "検索設定の記録なし"
      return RAGEvaluationEnvironmentSummary(
        id: key, modelLabel: model, settingsLabel: settings,
        runCount: values.count,
        passRate: Double(values.filter { $0.0.result.passes($0.1) }.count) / count,
        retrievalRecall: values.map { $0.0.result.retrievalRecall }.reduce(0, +) / count,
        answerPointCoverage: values.map { $0.0.result.answerPointCoverage }.reduce(0, +) / count,
        groundedAnswerPointCoverage:
          values.map { $0.0.result.groundedAnswerPointCoverage }.reduce(0, +) / count,
        totalMilliseconds: Int(
          (Double(values.map { $0.0.result.totalMilliseconds }.reduce(0, +)) / count).rounded()))
    }.sorted { $0.modelLabel == $1.modelLabel ? $0.settingsLabel < $1.settingsLabel : $0.modelLabel < $1.modelLabel }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("環境別比較").font(.headline)
      ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 10) {
          ForEach(summaries) { summary in
            VStack(alignment: .leading, spacing: 5) {
              Text(summary.modelLabel).font(.caption.bold()).lineLimit(1)
              Text(summary.settingsLabel).font(.caption2).foregroundStyle(.secondary)
              Text("\(summary.runCount)回 / 合格 \(percent(summary.passRate))")
              Text("検索 \(percent(summary.retrievalRecall)) / 要点 \(percent(summary.answerPointCoverage))")
              Text("裏付け \(percent(summary.groundedAnswerPointCoverage)) / 平均 \(summary.totalMilliseconds)ms")
            }
            .font(.caption)
            .padding(10)
            .frame(width: 270, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
          }
        }
      }
    }
  }

  private func environmentKey(for run: RAGEvaluationRun) -> String {
    guard let environment = run.environment else {
      return "legacy|\(run.result.providerID)|\(run.result.modelID ?? "")|\(run.result.ragMode.rawValue)"
    }
    let settings = environment.searchSettings
    return [
      environment.providerID, environment.baseURL ?? "", environment.modelID ?? "",
      run.result.ragMode.rawValue,
      String(settings.limit), String(settings.minScore), String(settings.keywordWeight),
      String(settings.embeddingWeight),
    ].joined(separator: "|")
  }

  private func percent(_ value: Double) -> String {
    value.formatted(.percent.precision(.fractionLength(0)))
  }
}

private struct RAGEvaluationAnswerRulesView: View {
  let expectedPoints: [String]
  let forbiddenPhrases: [String]
  let update: ([String], [String]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("回答内容の採点")
        .font(.caption.bold())
      Text("1行を1項目として、回答と期待する根拠チャンク内の部分一致で判定します。")
        .font(.caption2)
        .foregroundStyle(.secondary)
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("含める要点").font(.caption)
          TextField(
            "例: 茨城で次回ワークショップを開催",
            text: Binding(
              get: { expectedPoints.joined(separator: "\n") },
              set: { update(Self.lines($0), forbiddenPhrases) }),
            axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
        }
        VStack(alignment: .leading, spacing: 4) {
          Text("含めてはいけない表現").font(.caption)
          TextField(
            "例: 東京で開催",
            text: Binding(
              get: { forbiddenPhrases.joined(separator: "\n") },
              set: { update(expectedPoints, Self.lines($0)) }),
            axis: .vertical)
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
        }
      }
    }
  }

  private static func lines(_ text: String) -> [String] {
    var seen: Set<String> = []
    return text.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
      return trimmed
    }
  }
}

private struct RAGEvaluationCriteriaView: View {
  let criteria: RAGEvaluationCriteria
  let update: (RAGEvaluationCriteria) -> Void

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
      percentageRow("検索再現率", value: criteria.minimumRetrievalRecall) {
        makeCriteria(retrievalRecall: $0)
      }
      percentageRow("引用精度", value: criteria.minimumCitationPrecision) {
        makeCriteria(citationPrecision: $0)
      }
      percentageRow("引用再現率", value: criteria.minimumCitationRecall) {
        makeCriteria(citationRecall: $0)
      }
      percentageRow("回答要点", value: criteria.minimumAnswerPointCoverage) {
        makeCriteria(answerPointCoverage: $0)
      }
      percentageRow("資料裏付け", value: criteria.minimumGroundedAnswerPointCoverage) {
        makeCriteria(groundedAnswerPointCoverage: $0)
      }
      GridRow {
        Text("禁止表現")
        Toggle(
          "0件を必須",
          isOn: Binding(
            get: { criteria.requireNoForbiddenPhrases },
            set: { makeCriteria(requireNoForbiddenPhrases: $0) }))
          .toggleStyle(.checkbox)
      }
      GridRow {
        Text("合計時間の上限")
        Stepper(
          "\(criteria.maximumTotalMilliseconds / 1_000)秒",
          value: Binding(
            get: { max(criteria.maximumTotalMilliseconds / 1_000, 1) },
            set: { makeCriteria(maximumSeconds: $0) }),
          in: 1...300)
      }
    }
    .font(.caption)
  }

  private func percentageRow(
    _ label: String, value: Double, updateValue: @escaping (Double) -> Void
  ) -> some View {
    GridRow {
      Text(label)
      Stepper(
        value.formatted(.percent.precision(.fractionLength(0))),
        value: Binding(get: { value }, set: updateValue),
        in: 0...1, step: 0.05)
    }
  }

  private func makeCriteria(
    retrievalRecall: Double? = nil,
    citationPrecision: Double? = nil,
    citationRecall: Double? = nil,
    answerPointCoverage: Double? = nil,
    groundedAnswerPointCoverage: Double? = nil,
    requireNoForbiddenPhrases: Bool? = nil,
    maximumSeconds: Int? = nil
  ) {
    update(RAGEvaluationCriteria(
      minimumRetrievalRecall: retrievalRecall ?? criteria.minimumRetrievalRecall,
      minimumCitationPrecision: citationPrecision ?? criteria.minimumCitationPrecision,
      minimumCitationRecall: citationRecall ?? criteria.minimumCitationRecall,
      minimumAnswerPointCoverage:
        answerPointCoverage ?? criteria.minimumAnswerPointCoverage,
      minimumGroundedAnswerPointCoverage:
        groundedAnswerPointCoverage ?? criteria.minimumGroundedAnswerPointCoverage,
      requireNoForbiddenPhrases:
        requireNoForbiddenPhrases ?? criteria.requireNoForbiddenPhrases,
      maximumTotalMilliseconds: (maximumSeconds ?? criteria.maximumTotalMilliseconds / 1_000) * 1_000))
  }
}

private struct RAGEvaluationRunView: View {
  let run: RAGEvaluationRun
  let criteria: RAGEvaluationCriteria
  let baseline: RAGEvaluationRun?
  let isBaseline: Bool
  let setBaseline: () -> Void

  private var modelLabel: String {
    if let modelID = run.result.modelID, !modelID.isEmpty {
      return "\(run.result.providerName) / \(modelID)"
    }
    return run.result.providerName
  }

  private var rankLabel: String {
    run.result.expectedRanks.map { expected in
      expected.rank.map { "#\($0)" } ?? "圏外"
    }.joined(separator: ", ")
  }

  private var deltaLabel: String? {
    guard let baseline, baseline.id != run.id else { return nil }
    let retrieval = percentagePointDelta(
      run.result.retrievalRecall - baseline.result.retrievalRecall)
    let precision = percentagePointDelta(
      run.result.citationPrecision - baseline.result.citationPrecision)
    let recall = percentagePointDelta(run.result.citationRecall - baseline.result.citationRecall)
    let answer = percentagePointDelta(
      run.result.answerPointCoverage - baseline.result.answerPointCoverage)
    let grounded = percentagePointDelta(
      run.result.groundedAnswerPointCoverage - baseline.result.groundedAnswerPointCoverage)
    let time = run.result.totalMilliseconds - baseline.result.totalMilliseconds
    return "基準比: 検索 \(retrieval) / 引用精度 \(precision) / 引用再現 \(recall) / 要点 \(answer) / 裏付け \(grounded) / 合計 \(signed(time))ms"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 10) {
        Text(modelLabel).font(.caption.bold())
        Text("RAG: \(run.result.ragMode.displayName)")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(run.createdAt, style: .date).font(.caption2).foregroundStyle(.secondary)
        Text(run.createdAt, style: .time).font(.caption2).foregroundStyle(.secondary)
        Text(run.result.passes(criteria) ? "合格" : "不合格")
          .font(.caption.bold())
          .foregroundStyle(run.result.passes(criteria) ? .green : .red)
        if isBaseline {
          Text("基準結果")
            .font(.caption.bold())
            .foregroundStyle(.tint)
        }
        Spacer()
        Text("順位 \(rankLabel)")
        Text("検索 \(run.result.retrievalRecall.formatted(.percent.precision(.fractionLength(0))))")
        Text("引用精度 \(run.result.citationPrecision.formatted(.percent.precision(.fractionLength(0))))")
        Text("引用再現 \(run.result.citationRecall.formatted(.percent.precision(.fractionLength(0))))")
      }
      .font(.caption)

      HStack(spacing: 10) {
        Text("検索期待: \(run.result.expectedSearch ? "必要" : "不要")")
        Text("判断: \(run.result.searchDecisionCorrect ? "一致" : "不一致")")
          .foregroundStyle(run.result.searchDecisionCorrect ? Color.green : Color.red)
        if let trace = run.result.agenticTrace {
          Text("Tool \(trace.toolCallCount)回")
          if !trace.queries.isEmpty {
            Text("検索語: \(trace.queries.joined(separator: " → "))").lineLimit(1)
          }
        }
      }
      .font(.caption2)

      HStack(spacing: 10) {
        Text(
          "回答要点 \(run.result.answerPointCoverage.formatted(.percent.precision(.fractionLength(0))))"
        )
        Text(
          "資料裏付け \(run.result.groundedAnswerPointCoverage.formatted(.percent.precision(.fractionLength(0))))"
        )
        Text("禁止表現 \(run.result.forbiddenPhraseHits.count)件")
          .foregroundStyle(run.result.forbiddenPhraseHits.isEmpty ? Color.secondary : Color.red)
      }
      .font(.caption)

      if let deltaLabel {
        Text(deltaLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(
        "検索 \(run.result.retrievalMilliseconds)ms / 回答 \(run.result.generationMilliseconds)ms / 合計 \(run.result.totalMilliseconds)ms"
      )
      .font(.caption2)
      .foregroundStyle(.secondary)

      if let environment = run.environment {
        Text(
          "環境: 上位\(environment.searchSettings.limit)件 / 閾値\(environment.searchSettings.minScore) / K \(environment.searchSettings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / E \(environment.searchSettings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))\(environment.baseURL.map { " / \($0)" } ?? "")"
        )
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
      }

      Text(run.result.answer.isEmpty ? "回答がありません" : run.result.answer)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(4)
        .textSelection(.enabled)

      if !run.result.expectedAnswerPointResults.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("回答要点の判定").font(.caption2.bold())
          ForEach(run.result.expectedAnswerPointResults) { point in
            HStack(spacing: 5) {
              Image(systemName: point.foundInAnswer ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(point.foundInAnswer ? Color.green : Color.red)
              Image(
                systemName: point.supportedByExpectedChunks
                  ? "doc.text.fill" : "doc.text.magnifyingglass")
                .foregroundStyle(point.supportedByExpectedChunks ? Color.secondary : Color.orange)
              Text(point.point)
            }
            .font(.caption2)
          }
        }
      }

      if !run.result.forbiddenPhraseHits.isEmpty {
        Text("禁止表現を検出: \(run.result.forbiddenPhraseHits.joined(separator: "、"))")
          .font(.caption2.bold())
          .foregroundStyle(.red)
      }

      if !run.result.diagnostics.isEmpty {
        VStack(alignment: .leading, spacing: 3) {
          Text("RAG診断").font(.caption2.bold())
          ForEach(run.result.diagnostics) { finding in
            Text("• \(finding.title): \(finding.detail)")
              .font(.caption2)
              .foregroundStyle(finding.code == .retryRecovered ? Color.green : Color.orange)
          }
        }
      }

      Button(isBaseline ? "基準を解除" : "基準結果に設定", systemImage: "flag") {
        setBaseline()
      }
      .font(.caption)
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }

  private func percentagePointDelta(_ value: Double) -> String {
    signed(Int((value * 100).rounded())) + "pt"
  }

  private func signed(_ value: Int) -> String {
    value > 0 ? "+\(value)" : String(value)
  }
}

private struct KnowledgeCitationDetailView: View {
  let citation: KnowledgeChunkMatch
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("[\(citation.citationIndex)] \(citation.title) #\(citation.chunkIndex)")
          .font(.title2.bold())
        Spacer()
        SearchModeBadge(mode: citation.searchMode)
        Text("score \(citation.score)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Button("閉じる", systemImage: "xmark") {
          dismiss()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
        .help("閉じる")
      }
      Text(citation.documentID.uuidString)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      SearchDiagnosticsDetail(score: citation.score, diagnostics: citation.diagnostics)
      ScrollView {
        Text(citation.text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct SearchDiagnosticsSummary: View {
  let diagnostics: KnowledgeChunkDiagnostics

  var body: some View {
    HStack(spacing: 8) {
      DiagnosticPill(label: "Keyword", value: diagnostics.weightedKeywordScore)
      DiagnosticPill(label: "Embedding", value: diagnostics.weightedEmbeddingScore)
      Text("raw K \(diagnostics.rawKeywordScore) / E \(diagnostics.rawEmbeddingScore)")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}

private struct SearchDiagnosticsDetail: View {
  let score: Int
  let diagnostics: KnowledgeChunkDiagnostics

  private var totalWeightedScore: Double {
    diagnostics.weightedKeywordScore + diagnostics.weightedEmbeddingScore
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("検索診断").font(.headline)
      HStack(spacing: 8) {
        DiagnosticPill(label: "合計", value: Double(score))
        DiagnosticPill(label: "Keyword", value: diagnostics.weightedKeywordScore)
        DiagnosticPill(label: "Embedding", value: diagnostics.weightedEmbeddingScore)
      }
      HStack(spacing: 8) {
        Text("素点 Keyword \(diagnostics.rawKeywordScore)")
        Text("素点 Embedding \(diagnostics.rawEmbeddingScore)")
        Text("加重合計 \(totalWeightedScore.formatted(.number.precision(.fractionLength(1))))")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      Text("score は Keyword と Embedding の加重スコアを合算して丸めた値です。検索設定の重みを変えると、この内訳の寄与が変わります。")
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct DiagnosticPill: View {
  let label: String
  let value: Double

  var body: some View {
    Text("\(label) \(value.formatted(.number.precision(.fractionLength(1))))")
      .font(.caption2.bold())
      .foregroundStyle(.secondary)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(Color.secondary.opacity(0.12))
      .clipShape(Capsule())
  }
}

private struct SearchFeedbackLogView: View {
  enum Filter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case good = "良い"
    case bad = "違う"
    var id: String { rawValue }
  }

  let entries: [KnowledgeSearchFeedback]
  let applySettings: (KnowledgeSearchSettings) -> Void
  let deleteFeedback: (KnowledgeSearchFeedback) -> Void
  let deleteFeedbackEntries: ([KnowledgeSearchFeedback]) -> Void
  let showCitation: (KnowledgeSearchFeedback) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var filter: Filter = .all
  @State private var searchText = ""
  @State private var exportMessage: String?

  private var searchedEntries: [KnowledgeSearchFeedback] {
    let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty else { return entries }
    return entries.filter { feedback in
      [
        feedback.query,
        feedback.match.title,
        feedback.match.text,
        feedback.match.searchMode,
      ].contains { $0.lowercased().contains(trimmed) }
    }
  }

  private var goodEntries: [KnowledgeSearchFeedback] {
    searchedEntries.filter { $0.rating == .good }
  }

  private var badEntries: [KnowledgeSearchFeedback] {
    searchedEntries.filter { $0.rating == .bad }
  }

  private var filteredEntries: [KnowledgeSearchFeedback] {
    switch filter {
    case .all: return searchedEntries
    case .good: return searchedEntries.filter { $0.rating == .good }
    case .bad: return searchedEntries.filter { $0.rating == .bad }
    }
  }

  private var suggestedSettings: KnowledgeSearchSettings? {
    guard !goodEntries.isEmpty else { return nil }
    let count = Double(goodEntries.count)
    let limit = Int((goodEntries.map { Double($0.settings.limit) }.reduce(0, +) / count).rounded())
    let minScore = Int(
      (goodEntries.map { Double($0.settings.minScore) }.reduce(0, +) / count).rounded())
    let keywordWeight = goodEntries.map(\.settings.keywordWeight).reduce(0, +) / count
    let embeddingWeight = goodEntries.map(\.settings.embeddingWeight).reduce(0, +) / count
    return KnowledgeSearchSettings(
      limit: limit,
      minScore: minScore,
      keywordWeight: keywordWeight,
      embeddingWeight: embeddingWeight
    )
  }

  private var modeSummaries: [(mode: String, good: Int, bad: Int)] {
    let modes = Set(searchedEntries.map(\.match.searchMode)).sorted()
    return modes.map { mode in
      (
        mode: mode,
        good: searchedEntries.filter { $0.match.searchMode == mode && $0.rating == .good }.count,
        bad: searchedEntries.filter { $0.match.searchMode == mode && $0.rating == .bad }.count
      )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("検索評価ログ").font(.title2.bold())
        Spacer()
        Picker("表示", selection: $filter) {
          ForEach(Filter.allCases) { item in
            Text(item.rawValue).tag(item)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        Button("閉じる", systemImage: "xmark") {
          dismiss()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
        .help("閉じる")
      }

      HStack {
        TextField("クエリ、資料名、本文で検索", text: $searchText)
          .textFieldStyle(.roundedBorder)
        Button("JSON 書き出し", systemImage: "square.and.arrow.up") {
          exportJSON(filteredEntries)
        }
        .disabled(filteredEntries.isEmpty)
        Button("CSV 書き出し", systemImage: "tablecells") {
          exportCSV(filteredEntries)
        }
        .disabled(filteredEntries.isEmpty)
        Button("表示分を削除", systemImage: "trash") {
          deleteFeedbackEntries(filteredEntries)
        }
        .disabled(filteredEntries.isEmpty)
      }

      if let exportMessage {
        Text(exportMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      FeedbackSummaryView(
        goodCount: goodEntries.count,
        badCount: badEntries.count,
        modeSummaries: modeSummaries,
        suggestedSettings: suggestedSettings,
        applySettings: applySettings
      )

      if filteredEntries.isEmpty {
        ContentUnavailableView("評価ログがありません", systemImage: "list.clipboard")
      } else {
        List(filteredEntries) { feedback in
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              FeedbackBadge(rating: feedback.rating)
              Text(feedback.query)
                .font(.headline)
                .lineLimit(1)
              Spacer()
              Text(feedback.createdAt, style: .date)
                .font(.caption)
                .foregroundStyle(.secondary)
              Text(feedback.createdAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
              Text(
                "[\(feedback.match.citationIndex)] \(feedback.match.title) #\(feedback.match.chunkIndex)"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              SearchModeBadge(mode: feedback.match.searchMode)
              Text("score \(feedback.match.score)")
                .font(.caption)
                .foregroundStyle(.secondary)
              Spacer()
              Button("開く", systemImage: "arrow.up.right.square") {
                showCitation(feedback)
              }
              Button("削除", systemImage: "trash") {
                deleteFeedback(feedback)
              }
            }

            Text(feedback.match.text)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .textSelection(.enabled)

            Text(
              "件数 \(feedback.settings.limit) / 最小 \(feedback.settings.minScore) / Keyword \(feedback.settings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / Embedding \(feedback.settings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
          }
          .padding(.vertical, 6)
        }
      }
    }
    .padding(20)
  }

  private func exportJSON(_ entries: [KnowledgeSearchFeedback]) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(entries)
      try export(data: data, filename: "onigiri-search-feedback.json")
    } catch {
      exportMessage = error.localizedDescription
    }
  }

  private func exportCSV(_ entries: [KnowledgeSearchFeedback]) {
    let header = [
      "createdAt", "rating", "query", "title", "chunkIndex", "score", "mode", "limit",
      "minScore", "keywordWeight", "embeddingWeight", "text",
    ]
    let rows = entries.map { feedback in
      [
        feedback.createdAt.ISO8601Format(),
        feedback.rating.rawValue,
        feedback.query,
        feedback.match.title,
        "\(feedback.match.chunkIndex)",
        "\(feedback.match.score)",
        feedback.match.searchMode,
        "\(feedback.settings.limit)",
        "\(feedback.settings.minScore)",
        feedback.settings.keywordWeight.formatted(.number.precision(.fractionLength(1))),
        feedback.settings.embeddingWeight.formatted(.number.precision(.fractionLength(1))),
        feedback.match.text,
      ].map(Self.csvField).joined(separator: ",")
    }
    let csv = ([header.joined(separator: ",")] + rows).joined(separator: "\n")
    do {
      try export(data: Data(csv.utf8), filename: "onigiri-search-feedback.csv")
    } catch {
      exportMessage = error.localizedDescription
    }
  }

  private func export(data: Data, filename: String) throws {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = filename
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try data.write(to: url, options: .atomic)
    exportMessage = "\(url.lastPathComponent) に書き出しました。"
  }

  private static func csvField(_ value: String) -> String {
    "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
  }
}

private struct FeedbackSummaryView: View {
  let goodCount: Int
  let badCount: Int
  let modeSummaries: [(mode: String, good: Int, bad: Int)]
  let suggestedSettings: KnowledgeSearchSettings?
  let applySettings: (KnowledgeSearchSettings) -> Void

  private var totalCount: Int { goodCount + badCount }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        FeedbackMetric(label: "合計", value: "\(totalCount)", color: .secondary)
        FeedbackMetric(label: "良い", value: "\(goodCount)", color: .green)
        FeedbackMetric(label: "違う", value: "\(badCount)", color: .red)
        if totalCount > 0 {
          let rate = Double(goodCount) / Double(totalCount) * 100
          FeedbackMetric(
            label: "良い率",
            value: "\(Int(rate.rounded()))%",
            color: rate >= 50 ? .green : .orange
          )
        }
        Spacer()
        if let suggestedSettings {
          Button("推奨設定を適用", systemImage: "wand.and.sparkles") {
            applySettings(suggestedSettings)
          }
        }
      }

      if !modeSummaries.isEmpty {
        HStack(spacing: 8) {
          ForEach(modeSummaries, id: \.mode) { summary in
            HStack(spacing: 4) {
              SearchModeBadge(mode: summary.mode)
              Text("良い \(summary.good) / 違う \(summary.bad)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      if let suggestedSettings {
        Text(
          "推奨: 件数 \(suggestedSettings.limit) / 最小 \(suggestedSettings.minScore) / Keyword \(suggestedSettings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / Embedding \(suggestedSettings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        Text("良い評価を記録すると、推奨設定を算出できます。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}

private struct FeedbackMetric: View {
  let label: String
  let value: String
  let color: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.headline)
        .foregroundStyle(color)
    }
    .frame(minWidth: 48, alignment: .leading)
  }
}

private struct FeedbackBadge: View {
  let rating: KnowledgeSearchFeedback.Rating

  var body: some View {
    Text(rating == .good ? "良い" : "違う")
      .font(.caption2.bold())
      .foregroundStyle(rating == .good ? .green : .red)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background((rating == .good ? Color.green : Color.red).opacity(0.12))
      .clipShape(Capsule())
  }
}

private struct ChunkingSettingsView: View {
  @Binding var maxCharacters: Int
  @Binding var overlapCharacters: Int
  let apply: () -> Void

  private var effectiveSettings: KnowledgeChunkingSettings {
    KnowledgeChunkingSettings(maxCharacters: maxCharacters, overlapCharacters: overlapCharacters)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SheetTitleBar(title: "分割設定")

      VStack(alignment: .leading, spacing: 8) {
        Stepper("チャンクサイズ \(maxCharacters)文字", value: $maxCharacters, in: 400...4_000, step: 100)
        Stepper(
          "オーバーラップ \(overlapCharacters)文字", value: $overlapCharacters, in: 0...1_000, step: 20)
        Text(
          "適用後: チャンクサイズ \(effectiveSettings.maxCharacters)文字 / オーバーラップ \(effectiveSettings.overlapCharacters)文字"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Text("設定を適用すると、追加済み資料をすべて再分割します。既存のEmbeddingは分割後のチャンクに合わせて再作成が必要になります。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Button("標準に戻す") {
          maxCharacters = KnowledgeChunkingSettings.default.maxCharacters
          overlapCharacters = KnowledgeChunkingSettings.default.overlapCharacters
        }
        Spacer()
        Button("再分割して適用", systemImage: "arrow.triangle.2.circlepath") {
          apply()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(20)
  }
}

private struct SearchSettingsView: View {
  @Binding var limit: Int
  @Binding var minScore: Int
  @Binding var keywordWeight: Double
  @Binding var embeddingWeight: Double
  let customPresets: [SearchPreset]
  let applyPreset: (SearchPreset) -> Void
  let savePreset: (String) -> Void
  let deletePreset: (SearchPreset) -> Void
  @State private var presetName = ""

  private var presets: [SearchPreset] {
    SearchPreset.builtIns + customPresets
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SheetTitleBar(title: "検索設定")

      VStack(alignment: .leading, spacing: 8) {
        Text("プリセット").font(.headline)
        List(presets) { preset in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              HStack {
                Text(preset.name)
                if preset.isBuiltIn {
                  Text("標準")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                }
              }
              Text(
                "件数 \(preset.settings.limit) / 最小 \(preset.settings.minScore) / Keyword \(preset.settings.keywordWeight.formatted(.number.precision(.fractionLength(1)))) / Embedding \(preset.settings.embeddingWeight.formatted(.number.precision(.fractionLength(1))))"
              )
              .font(.caption2)
              .foregroundStyle(.secondary)
            }
            Spacer()
            Button("適用") {
              applyPreset(preset)
            }
            if !preset.isBuiltIn {
              Button("削除", systemImage: "trash") {
                deletePreset(preset)
              }
            }
          }
          .padding(.vertical, 3)
        }
        .frame(height: 150)

        HStack {
          TextField("プリセット名", text: $presetName)
            .textFieldStyle(.roundedBorder)
          Button("現在値を保存", systemImage: "plus") {
            savePreset(presetName)
            presetName = ""
          }
          .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }

      Stepper("表示件数 \(limit)", value: $limit, in: 1...20)
      Stepper("最小スコア \(minScore)", value: $minScore, in: 1...100)

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Keyword 重み")
          Spacer()
          Text(keywordWeight, format: .number.precision(.fractionLength(1)))
            .foregroundStyle(.secondary)
        }
        Slider(value: $keywordWeight, in: 0...3, step: 0.1)
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Embedding 重み")
          Spacer()
          Text(embeddingWeight, format: .number.precision(.fractionLength(1)))
            .foregroundStyle(.secondary)
        }
        Slider(value: $embeddingWeight, in: 0...3, step: 0.1)
      }

      Button("標準に戻す") {
        limit = 5
        minScore = 1
        keywordWeight = 1
        embeddingWeight = 1
      }
    }
    .padding(20)
  }
}

private struct SearchModeBadge: View {
  let mode: String

  private var label: String {
    switch mode {
    case "embedding": return "Embedding"
    case "hybrid": return "Hybrid"
    default: return "Keyword"
    }
  }

  private var color: Color {
    switch mode {
    case "embedding": return .purple
    case "hybrid": return .blue
    default: return .secondary
    }
  }

  var body: some View {
    Text(label)
      .font(.caption2.bold())
      .foregroundStyle(color)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(color.opacity(0.12))
      .clipShape(Capsule())
  }
}

private struct KnowledgeDocumentsView: View {
  let documents: [KnowledgeDocumentSummary]
  let searchDocument: (KnowledgeDocumentSummary) -> Void
  let showChunks: (KnowledgeDocumentSummary) -> Void
  let deleteDocument: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "資料一覧")
      List(documents) { document in
        VStack(alignment: .leading, spacing: 6) {
          Text(document.title)
            .font(.headline)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          HStack {
            Text("\(document.chunkCount)チャンク / 埋め込み \(document.embeddedChunkCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("検索", systemImage: "magnifyingglass") {
              searchDocument(document)
            }
            Button("チャンク", systemImage: "list.bullet.rectangle") {
              showChunks(document)
            }
            Button("削除", systemImage: "trash") {
              deleteDocument(document.id)
            }
          }
          Text(document.preview)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .textSelection(.enabled)
        }
        .padding(.vertical, 4)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
}

private struct KnowledgeChunksView: View {
  let response: KnowledgeChunksResponse
  let settings: KnowledgeSearchSettings
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var searchResponse: KnowledgeChunkSearchResponse?
  @State private var isSearching = false
  @State private var searchError: String?

  private var title: String {
    response.document?.title ?? response.chunks.first?.title ?? "資料チャンク"
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.title2.bold())
          if let document = response.document {
            Text("\(document.chunkCount)チャンク / Embedding作成済み \(document.embeddedChunkCount)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button("閉じる", systemImage: "xmark") {
          dismiss()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)
        .help("閉じる")
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("資料内検索テスト").font(.headline)
        HStack {
          TextField("この資料内で試す質問やキーワード", text: $query)
            .textFieldStyle(.roundedBorder)
            .onSubmit { Task { await searchChunks() } }
          Button("検索", systemImage: "magnifyingglass") {
            Task { await searchChunks() }
          }
          .disabled(trimmedQuery.isEmpty || isSearching || response.document == nil)
        }
        Text("現在の検索設定で、この資料のチャンクだけを順位付けします。")
          .font(.caption2)
          .foregroundStyle(.secondary)
        if let searchError {
          Text(searchError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(10)
      .background(Color.secondary.opacity(0.08))
      .clipShape(RoundedRectangle(cornerRadius: 8))

      if let searchResponse {
        ChunkSearchResultsView(response: searchResponse)
      } else {
        ChunkListView(chunks: response.chunks)
      }
    }
    .padding(20)
  }

  @MainActor private func searchChunks() async {
    guard let documentID = response.document?.id, !trimmedQuery.isEmpty else { return }
    isSearching = true
    searchError = nil
    defer { isSearching = false }

    do {
      var request = URLRequest(
        url: OnigiriEndpoint.url("knowledge/documents/\(documentID.uuidString)/search"))
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONEncoder().encode(
        KnowledgeChunkSearchRequest(
          query: trimmedQuery,
          limit: 20,
          minScore: settings.minScore,
          keywordWeight: settings.keywordWeight,
          embeddingWeight: settings.embeddingWeight
        ))
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        let apiError = try? JSONDecoder().decode(APIError.self, from: data)
        throw StreamError(message: apiError?.error ?? "チャンク検索に失敗しました。")
      }
      searchResponse = try JSONDecoder().decode(KnowledgeChunkSearchResponse.self, from: data)
    } catch {
      searchError = error.localizedDescription
    }
  }
}

private struct ChunkListView: View {
  let chunks: [KnowledgeChunkSummary]

  var body: some View {
    if chunks.isEmpty {
      ContentUnavailableView("チャンクがありません", systemImage: "doc.text.magnifyingglass")
    } else {
      List(chunks) { chunk in
        ChunkSummaryRow(chunk: chunk)
      }
    }
  }
}

private struct ChunkSearchResultsView: View {
  let response: KnowledgeChunkSearchResponse

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("検索結果: \(response.query)")
          .font(.headline)
        Spacer()
        Text("\(response.results.count)件")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if response.results.isEmpty {
        ContentUnavailableView("一致するチャンクがありません", systemImage: "doc.text.magnifyingglass")
      } else {
        List(response.results) { result in
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
              Text("\(result.rank)位").font(.headline)
              Text("#\(result.chunk.chunkIndex)").font(.headline)
              SearchModeBadge(mode: result.searchMode)
              Text(result.passedMinScore ? "しきい値通過" : "しきい値未満")
                .font(.caption2.bold())
                .foregroundStyle(result.passedMinScore ? .green : .orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background((result.passedMinScore ? Color.green : Color.orange).opacity(0.12))
                .clipShape(Capsule())
              Spacer()
              Text("score \(result.score)")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SearchDiagnosticsSummary(diagnostics: result.diagnostics)
            ChunkSummaryRow(chunk: result.chunk, includeHeader: false)
          }
          .padding(.vertical, 6)
        }
      }
    }
  }
}

private struct ChunkSummaryRow: View {
  let chunk: KnowledgeChunkSummary
  var includeHeader = true

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if includeHeader {
        HStack(spacing: 8) {
          Text("#\(chunk.chunkIndex)").font(.headline)
          Text(chunk.isEmbedded ? "Embedding済み" : "Embedding未作成")
            .font(.caption2.bold())
            .foregroundStyle(chunk.isEmbedded ? .green : .orange)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((chunk.isEmbedded ? Color.green : Color.orange).opacity(0.12))
            .clipShape(Capsule())
          Spacer()
          Text("\(chunk.text.count)文字")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }

      if !chunk.keywords.isEmpty {
        FlowLayout(spacing: 6) {
          ForEach(chunk.keywords, id: \.self) { keyword in
            Text(keyword)
              .font(.caption2)
              .padding(.horizontal, 7)
              .padding(.vertical, 3)
              .background(Color.secondary.opacity(0.12))
              .clipShape(Capsule())
          }
        }
      } else {
        Text("検索語句候補なし")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Text(chunk.text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding(.vertical, includeHeader ? 6 : 0)
  }
}

private struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGSize {
    let maxWidth = proposal.width ?? 400
    var size = CGSize.zero
    var lineWidth: CGFloat = 0
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let subviewSize = subview.sizeThatFits(.unspecified)
      if lineWidth > 0, lineWidth + spacing + subviewSize.width > maxWidth {
        size.width = max(size.width, lineWidth)
        size.height += lineHeight + spacing
        lineWidth = subviewSize.width
        lineHeight = subviewSize.height
      } else {
        lineWidth += (lineWidth == 0 ? 0 : spacing) + subviewSize.width
        lineHeight = max(lineHeight, subviewSize.height)
      }
    }
    size.width = max(size.width, lineWidth)
    size.height += lineHeight
    return size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var origin = bounds.origin
    var lineHeight: CGFloat = 0

    for subview in subviews {
      let subviewSize = subview.sizeThatFits(.unspecified)
      if origin.x > bounds.minX, origin.x + subviewSize.width > bounds.maxX {
        origin.x = bounds.minX
        origin.y += lineHeight + spacing
        lineHeight = 0
      }
      subview.place(at: origin, proposal: ProposedViewSize(subviewSize))
      origin.x += subviewSize.width + spacing
      lineHeight = max(lineHeight, subviewSize.height)
    }
  }
}

private struct ConversationRow: View {
  @Environment(\.locale) private var locale
  let conversation: StoredConversation

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(conversation.title)
        .font(.headline)
        .lineLimit(2)
      HStack {
        Text(messageCountLabel)
        Spacer()
        Text(conversation.updatedAt, style: .date)
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }

  private var messageCountLabel: String {
    if locale.identifier.lowercased().hasPrefix("en") {
      let count = conversation.messages.count
      return "\(count) \(count == 1 ? "message" : "messages")"
    }
    return "\(conversation.messages.count)件"
  }
}

@MainActor
private final class WebResearchBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
  let webView: WKWebView
  @Published var location = ""
  @Published var title = "Webリサーチ"
  @Published var isLoading = false

  override init() {
    let configuration = WKWebViewConfiguration()
    webView = WKWebView(frame: .zero, configuration: configuration)
    super.init()
    webView.navigationDelegate = self
  }

  func load(address: String) {
    let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let url: URL?
    if let direct = URL(string: trimmed), direct.scheme != nil {
      url = direct
    } else if trimmed.contains(".") && !trimmed.contains(" ") {
      url = URL(string: "https://\(trimmed)")
    } else {
      var components = URLComponents(string: "https://search.brave.com/search")
      components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
      url = components?.url
    }
    guard let url else { return }
    location = url.absoluteString
    webView.load(URLRequest(url: url))
  }

  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    isLoading = true
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    isLoading = false
    location = webView.url?.absoluteString ?? location
    title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Webページ"
  }

  func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    isLoading = false
  }

  func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    isLoading = false
  }

  func captureCurrentPage() async throws -> WebResearchSource {
    guard let url = webView.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
      throw StreamError(message: "Webページを開いてから追加してください。")
    }
    let value = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
    let rawText = value as? String ?? ""
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw StreamError(message: "ページ本文を取得できませんでした。")
    }
    let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? url.host
      ?? "Webページ"
    return WebResearchSource(
      // The loopback chat API limits request bodies to 32 KiB. Keep each
      // selected page well below that boundary even for multibyte text.
      title: pageTitle, url: url.absoluteString,
      text: String(decoding: text.utf8.prefix(4_000), as: UTF8.self))
  }
}

private struct WebResearchBrowser: NSViewRepresentable {
  @ObservedObject var model: WebResearchBrowserModel

  func makeNSView(context: Context) -> WKWebView { model.webView }
  func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct WebSearchResult: Identifiable {
  let title: String
  let url: String
  let content: String?
  let provider: String

  var id: String { "\(provider):\(url)" }
}

private struct WebResearchView: View {
  @Binding var sources: [WebResearchSource]
  @Environment(\.dismiss) private var dismiss
  @AppStorage("onigiri.searxng.enabled") private var searXNGEnabled = false
  @AppStorage("onigiri.searxng.baseURL") private var searXNGBaseURL = "http://127.0.0.1:8080"
  @AppStorage("onigiri.tavily.enabled") private var tavilyEnabled = false
  @StateObject private var browser = WebResearchBrowserModel()
  @State private var address = ""
  @State private var errorMessage: String?
  @State private var capturing = false
  @State private var searching = false
  @State private var searchResults: [WebSearchResult] = []
  @State private var tavilyAPIKey = ""
  @State private var tavilyKeychainMessage: String?
  private let secretStore = KeychainSecretStore()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      SheetTitleBar(title: "Webリサーチ")
      Text("ページを開き、「このページを会話に使う」を押すと、URL・取得日時・本文を次の質問だけに添付します。ページ本文は参考資料として扱われ、ページ内の指示は実行しません。")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("URLまたは検索語", text: $address)
          .textFieldStyle(.roundedBorder)
          .onSubmit { openAddress() }
        Button("開く", systemImage: "arrow.right.circle") { openAddress() }
        if browser.isLoading || searching { ProgressView().controlSize(.small) }
      }

      DisclosureGroup("SearXNGローカル連携") {
        Toggle("SearXNGを検索に使う", isOn: $searXNGEnabled)
          .onChange(of: searXNGEnabled) { _, enabled in if enabled { tavilyEnabled = false } }
        TextField("SearXNG URL", text: $searXNGBaseURL)
          .textFieldStyle(.roundedBorder)
        Text("このMacで起動したSearXNGのloopback URLだけを使います。例: http://127.0.0.1:8080")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .font(.caption)

      DisclosureGroup("Tavily連携") {
        Toggle("Tavilyを検索に使う", isOn: $tavilyEnabled)
          .onChange(of: tavilyEnabled) { _, enabled in if enabled { searXNGEnabled = false } }
        HStack(spacing: 6) {
          SecureField("Tavily API key（Keychain）", text: $tavilyAPIKey)
            .textFieldStyle(.roundedBorder)
          Button("Keychainへ保存", systemImage: "key.fill") { saveTavilyAPIKey() }
            .labelStyle(.iconOnly)
            .help("Tavily API keyをKeychainへ保存")
          Button("Keychainから読み込む", systemImage: "arrow.down.to.line") {
            loadTavilyAPIKey()
          }
          .labelStyle(.iconOnly)
          .help("Tavily API keyをKeychainから読み込む")
          Button("Keychainから削除", systemImage: "trash") { deleteTavilyAPIKey() }
            .labelStyle(.iconOnly)
            .help("保存済みのTavily API keyをKeychainから削除")
        }
        Text("Tavilyへは検索語だけを送ります。検索結果を会話に使うには、ページを開いて明示的に追加してください。")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let tavilyKeychainMessage {
          Text(tavilyKeychainMessage).font(.caption).foregroundStyle(.secondary)
        }
      }
      .font(.caption)

      if !searchResults.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text(searchResults.first?.provider == "Tavily" ? "Tavily検索結果" : "SearXNG検索結果")
            .font(.caption.bold())
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
              ForEach(searchResults) { result in
                Button {
                  address = result.url
                  browser.load(address: result.url)
                  searchResults = []
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    Text(result.title).font(.caption.bold()).lineLimit(1)
                    Text(result.url).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let content = result.content, !content.isEmpty {
                      Text(content).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                  }
                  .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                Divider()
              }
            }
          }
          .frame(maxHeight: 170)
        }
      }

      WebResearchBrowser(model: browser)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

      if let errorMessage {
        Text(errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }

      if !sources.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          Text("次の質問に使うWebページ")
            .font(.caption.bold())
          ForEach(sources) { source in
            HStack(spacing: 6) {
              Text(source.title).lineLimit(1)
              Spacer()
              Button("解除", systemImage: "xmark") {
                sources.removeAll { $0.id == source.id }
              }
              .labelStyle(.iconOnly)
              .buttonStyle(.borderless)
            }
            .font(.caption)
          }
        }
      }

      HStack {
        Text(browser.location)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("このページを会話に使う", systemImage: "text.badge.plus") {
          Task {
            capturing = true
            defer { capturing = false }
            do {
              let source = try await browser.captureCurrentPage()
              if !sources.contains(where: { $0.url == source.url }) { sources.append(source) }
              errorMessage = nil
            } catch {
              errorMessage = error.localizedDescription
            }
          }
        }
        .disabled(capturing)
        Button("閉じる") { dismiss() }
      }
    }
    .padding(16)
    .onAppear {
      if address.isEmpty { address = browser.location }
      loadTavilyAPIKey()
    }
  }

  private func openAddress() {
    let query = address.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    guard (searXNGEnabled || tavilyEnabled), isSearchQuery(query) else {
      searchResults = []
      browser.load(address: query)
      return
    }
    Task {
      if tavilyEnabled {
        await searchTavily(query)
      } else {
        await searchSearXNG(query)
      }
    }
  }

  private func isSearchQuery(_ value: String) -> Bool {
    !value.contains("://") && !(value.contains(".") && !value.contains(" "))
  }

  private func searchSearXNG(_ query: String) async {
    searching = true
    defer { searching = false }
    do {
      let configuration = SearXNGConfiguration(baseURL: searXNGBaseURL)
      let url = try configuration.searchURL(for: query)
      let (data, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse else { throw SearXNGError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else {
        throw SearXNGError.server(statusCode: http.statusCode)
      }
      let decoded = try JSONDecoder().decode(SearXNGSearchResponse.self, from: data)
      searchResults = decoded.results.filter {
        guard let url = URL(string: $0.url) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      }.prefix(8).map { WebSearchResult(title: $0.title, url: $0.url, content: $0.content, provider: "SearXNG") }
      errorMessage = searchResults.isEmpty ? "SearXNG検索結果がありません。" : nil
    } catch {
      errorMessage = error.localizedDescription
      searchResults = []
    }
  }

  private func searchTavily(_ query: String) async {
    searching = true
    defer { searching = false }
    do {
      let request = try TavilySearchAPI.makeRequest(query: query, apiKey: tavilyAPIKey)
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else { throw TavilyError.invalidResponse }
      guard (200..<300).contains(http.statusCode) else {
        throw TavilyError.server(statusCode: http.statusCode)
      }
      let decoded = try JSONDecoder().decode(TavilySearchResponse.self, from: data)
      searchResults = decoded.results.filter {
        guard let url = URL(string: $0.url) else { return false }
        return ["http", "https"].contains(url.scheme?.lowercased() ?? "")
      }.prefix(8).map { WebSearchResult(title: $0.title, url: $0.url, content: $0.content, provider: "Tavily") }
      errorMessage = searchResults.isEmpty ? "Tavily検索結果がありません。" : nil
    } catch {
      errorMessage = error.localizedDescription
      searchResults = []
    }
  }

  private func loadTavilyAPIKey() {
    do {
      tavilyAPIKey = try secretStore.read(account: "web-research.tavily") ?? ""
      tavilyKeychainMessage = tavilyAPIKey.isEmpty ? "Keychainに保存済みのTavily API keyはありません。" : "Tavily API keyをKeychainから読み込みました。"
    } catch {
      tavilyKeychainMessage = error.localizedDescription
    }
  }

  private func saveTavilyAPIKey() {
    let key = tavilyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      tavilyKeychainMessage = "保存するTavily API keyを入力してください。"
      return
    }
    do {
      try secretStore.save(key, account: "web-research.tavily")
      tavilyKeychainMessage = "Tavily API keyをKeychainへ保存しました。"
    } catch {
      tavilyKeychainMessage = error.localizedDescription
    }
  }

  private func deleteTavilyAPIKey() {
    do {
      try secretStore.delete(account: "web-research.tavily")
      tavilyAPIKey = ""
      tavilyKeychainMessage = "Tavily API keyをKeychainから削除しました。"
    } catch {
      tavilyKeychainMessage = error.localizedDescription
    }
  }
}

private struct MessageRow: View {
  let message: DisplayMessage
  let showCitation: (KnowledgeChunkMatch) -> Void

  var body: some View {
    HStack {
      if message.role == .user { Spacer(minLength: 72) }
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(message.role == .user ? "あなた" : "Onigiri")
            .font(.caption.bold()).foregroundStyle(.secondary)
          if let ragMode = message.ragMode {
            Text(LocalizedStringKey(ragMode.displayName))
              .font(.caption2)
              .padding(.horizontal, 6)
              .padding(.vertical, 2)
              .background(Color.secondary.opacity(0.12))
              .clipShape(Capsule())
          }
          Spacer()
          Button("コピー", systemImage: "doc.on.doc") {
            copyToPasteboard(message.content)
          }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
          .help(message.role == .user ? "入力内容をコピー" : "出力結果をコピー")
          .disabled(message.content.isEmpty)
        }
        if message.content.isEmpty {
          ProgressView().controlSize(.small)
        } else {
          Text(message.content).textSelection(.enabled)
        }
        if !message.citations.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(message.citations) { citation in
              Button {
                showCitation(citation)
              } label: {
                HStack(spacing: 6) {
                  Text("[\(citation.citationIndex)] \(citation.title)")
                    .lineLimit(1)
                  SearchModeBadge(mode: citation.searchMode)
                }
              }
              .buttonStyle(.link)
            }
          }
          .font(.caption)
          .padding(.top, 4)
        }
        if let webSources = message.webSources, !webSources.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Web情報源")
              .font(.caption.bold())
            ForEach(webSources) { source in
              if let url = URL(string: source.url) {
                Link(destination: url) {
                  webSourceLabel(source)
                }
              } else {
                webSourceLabel(source)
              }
            }
          }
          .font(.caption)
          .padding(.top, 4)
        }
        if let trace = message.ragTrace {
          VStack(alignment: .leading, spacing: 2) {
            Text(agenticDecisionLabel(trace.decision))
              .font(.caption.bold())
            Text(trace.reason)
            if !trace.queries.isEmpty {
              Text("検索語: \(trace.queries.joined(separator: " → "))")
            }
            Text("Tool \(trace.toolCallCount)回 / \(trace.elapsedMilliseconds)ms\(trace.usedFallback ? " / alwaysへフォールバック" : "")")
          }
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.top, 4)
          .textSelection(.enabled)
        }
      }
      .padding(12)
      .background(
        message.role == .user ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.10)
      )
      .clipShape(RoundedRectangle(cornerRadius: 12))
      if message.role == .assistant { Spacer(minLength: 72) }
    }
    .frame(maxWidth: .infinity)
  }

  private func agenticDecisionLabel(_ decision: AgenticRAGDecision) -> String {
    switch decision {
    case .search: return "資料検索を実行"
    case .skipped: return "資料検索を省略"
    case .explicitSelection: return "選択した資料を使用"
    }
  }

  @ViewBuilder private func webSourceLabel(_ source: WebResearchCitation) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(source.title).lineLimit(1)
      Text("\(source.url) ・ \(source.retrievedAt.formatted(date: .abbreviated, time: .shortened))")
        .font(.caption2)
        .lineLimit(1)
    }
  }
}
