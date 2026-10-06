import Foundation
import Testing

@testable import OnigiriCore

private struct SuccessfulCodexAdapter: CodexAdapter {
  func availability() async -> CodexAvailability {
    CodexAvailability(available: true, executablePath: "/test/codex", detail: "ready")
  }

  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    await onProgress(CodexTaskProgress(kind: "item.completed", message: "調査しました。"))
    return CodexAdapterResult(result: "完了結果", threadID: "thread-1", exitCode: 0)
  }
}

private struct BlockingCodexAdapter: CodexAdapter {
  func availability() async -> CodexAvailability {
    CodexAvailability(available: true, executablePath: "/test/codex", detail: "ready")
  }

  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    await onProgress(CodexTaskProgress(kind: "turn.started", message: "実行中"))
    try await Task.sleep(for: .seconds(30))
    return CodexAdapterResult(result: "unexpected", threadID: nil, exitCode: 0)
  }
}

private struct UnavailableCodexAdapter: CodexAdapter {
  func availability() async -> CodexAvailability {
    CodexAvailability(available: false, executablePath: nil, detail: "Codex CLIなし")
  }

  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    Issue.record("利用不可のadapterが実行されました。")
    return CodexAdapterResult(result: "", threadID: nil, exitCode: 1)
  }
}

private actor CLIChatAdapterProbe {
  private(set) var requests: [CodexTaskRequest] = []

  func record(_ request: CodexTaskRequest) -> Int {
    requests.append(request)
    return requests.count
  }

  func recordedRequests() -> [CodexTaskRequest] { requests }
}

private struct CLIChatRecordingAdapter: CodexAdapter {
  let provider: AITaskProvider
  let probe: CLIChatAdapterProbe

  func availability() async -> CodexAvailability {
    CodexAvailability(
      provider: provider, available: true, executablePath: "/test/\(provider.rawValue)",
      detail: "ready")
  }

  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    let count = await probe.record(request)
    return CodexAdapterResult(result: "reply-\(count)", threadID: nil, exitCode: 0)
  }
}

private actor AITaskExecutionProbe {
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var providers: Set<AITaskProvider> = []

  func begin(_ provider: AITaskProvider) {
    active += 1
    maximumActive = max(maximumActive, active)
    providers.insert(provider)
  }

  func end() { active -= 1 }
}

private struct ProbedAITaskAdapter: CodexAdapter {
  let provider: AITaskProvider
  let probe: AITaskExecutionProbe

  func availability() async -> CodexAvailability {
    CodexAvailability(
      provider: provider, available: true, executablePath: "/test/\(provider.rawValue)", detail: "ready")
  }

  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    await probe.begin(request.provider)
    try await Task.sleep(for: .milliseconds(80))
    await probe.end()
    return CodexAdapterResult(result: request.provider.name, threadID: nil, exitCode: 0)
  }
}

private func temporaryCodexStore() -> URL {
  FileManager.default.temporaryDirectory
    .appending(path: "onigiri-codex-tests-(UUID().uuidString)")
    .appending(path: "tasks.json")
}

private func waitForCodexTask(
  _ id: UUID, in manager: CodexAgentManager, status: CodexTaskStatus
) async -> CodexTaskRecord? {
  for _ in 0..<100 {
    if let record = await manager.list().tasks.first(where: { $0.id == id }),
      record.status == status
    {
      return record
    }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return nil
}

@Test func codexAgentCompletesAndPersistsSeparateTaskHistory() async throws {
  let storeURL = temporaryCodexStore()
  defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
  let manager = CodexAgentManager(adapter: SuccessfulCodexAdapter(), storeURL: storeURL)
  let request = CodexTaskRequest(
    prompt: "構成を調査して", workingDirectory: FileManager.default.temporaryDirectory.path)

  let started = try await manager.start(request)
  let completed = await waitForCodexTask(started.id, in: manager, status: .completed)

  #expect(completed?.result == "完了結果")
  #expect(completed?.threadID == "thread-1")
  #expect(completed?.progress.contains(where: { $0.kind == "item.completed" }) == true)

  let restored = CodexAgentManager(adapter: SuccessfulCodexAdapter(), storeURL: storeURL)
  #expect(await restored.list().tasks.first?.id == started.id)
  #expect(await restored.list().tasks.first?.status == .completed)
}

@Test func codexAgentCancellationStopsRunningTask() async throws {
  let manager = CodexAgentManager(adapter: BlockingCodexAdapter(), storeURL: nil)
  let started = try await manager.start(
    CodexTaskRequest(
      prompt: "長い調査", workingDirectory: FileManager.default.temporaryDirectory.path))

  let cancelled = try await manager.cancel(started.id)
  #expect(cancelled.status == .cancelled)
  #expect(cancelled.error?.contains("キャンセル") == true)
  #expect(await waitForCodexTask(started.id, in: manager, status: .cancelled) != nil)
}

@Test func codexAgentRejectsStartWhenCLIIsUnavailable() async {
  let manager = CodexAgentManager(adapter: UnavailableCodexAdapter(), storeURL: nil)
  do {
    _ = try await manager.start(
      CodexTaskRequest(
        prompt: "調査", workingDirectory: FileManager.default.temporaryDirectory.path))
    Issue.record("利用不可のCodexタスクが開始されました。")
  } catch let error as CodexAgentError {
    #expect(error.localizedDescription == "Codex CLIなし")
  } catch {
    Issue.record("予期しないエラー: \(error)")
  }
}

@Test func legacyCodexTaskRequestDefaultsToCodexProvider() throws {
  let json = #"{"prompt":"調査","workingDirectory":"/tmp","sandboxMode":"read-only","timeoutSeconds":60}"#
  let request = try JSONDecoder().decode(CodexTaskRequest.self, from: Data(json.utf8))
  #expect(request.provider == .codex)
}

@Test func cliAgentsAreAvailableAsChatModelProviders() async throws {
  let ids = Set(ModelProviderFactory.options.map(\.id))
  #expect(ids.isSuperset(of: ["codex", "antigravity", "claude-code"]))
  #expect(ModelProviderFactory.make(from: ProviderConfig(providerID: "codex")).id == "codex")
  #expect(
    ModelProviderFactory.make(from: ProviderConfig(providerID: "antigravity")).id
      == "antigravity")
  #expect(
    ModelProviderFactory.make(from: ProviderConfig(providerID: "claude-code")).id
      == "claude-code")
}

@Test func cliChatProviderUsesReadOnlyModeAndRetainsConversation() async throws {
  let probe = CLIChatAdapterProbe()
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-cli-chat-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  defer { try? FileManager.default.removeItem(at: directory) }
  let provider = CLIChatModelProvider(
    provider: .codex, configuredModelID: "gpt-test",
    adapter: CLIChatRecordingAdapter(provider: .codex, probe: probe),
    workingDirectory: directory)
  let status = await provider.status()
  #expect(status.available)
  #expect(provider.configuration.modelID == "gpt-test")

  let session = try await provider.makeSession(
    instructions: "Answer briefly.", contextLimit: 2_000)
  var first = ""
  try await session.streamResponse(to: "remember blue") { first = $0 }
  var second = ""
  try await session.streamResponse(to: "what color?") { second = $0 }
  #expect(first == "reply-1")
  #expect(second == "reply-2")

  let requests = await probe.recordedRequests()
  #expect(requests.count == 2)
  #expect(requests.allSatisfy { $0.sandboxMode == .readOnly })
  #expect(requests.allSatisfy { $0.model == "gpt-test" })
  #expect(requests.allSatisfy { $0.workingDirectory == directory.path })
  #expect(requests[1].prompt.contains("User: remember blue"))
  #expect(requests[1].prompt.contains("Assistant: reply-1"))
  #expect(requests[1].prompt.contains("User: what color?"))
}

@Test func codexCLIUsesNonInteractiveApprovalWithExplicitSandbox() {
  let request = CodexTaskRequest(
    prompt: "read only", workingDirectory: "/tmp", sandboxMode: .readOnly)
  let arguments = CodexCLIAdapter.arguments(for: request)

  #expect(arguments.starts(with: ["-a", "never", "-s", "read-only"]))
  #expect(!arguments.contains("--approve-for-me"))
  #expect(arguments.contains("exec"))
}

@Test func antigravityAdapterKeepsAgentResponseWhenResultEventIsMissing() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-antigravity-test-\(UUID().uuidString)", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appending(path: "agy")
  let script = """
    #!/bin/sh
    printf '%s\\n' '{"event":"step_update","step_update":{"conversation_id":"test-session","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"TASK-SEED-7319"}}'
    """
  try Data(script.utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755], ofItemAtPath: executable.path)
  let adapter = AntigravityCLIAdapter(executablePath: executable.path)

  let result = try await adapter.run(
    request: CodexTaskRequest(
      provider: .antigravity, prompt: "seed", workingDirectory: directory.path,
      sandboxMode: .readOnly, timeoutSeconds: 10),
    onProgress: { _ in })

  #expect(result.result == "TASK-SEED-7319")
  #expect(result.threadID == "test-session")
}

@Test func antigravityReadOnlyModeCanFinishHeadlessInsideSandbox() {
  let request = CodexTaskRequest(
    provider: .antigravity, prompt: "read only", workingDirectory: "/tmp",
    sandboxMode: .readOnly)
  let arguments = AntigravityCLIAdapter.arguments(for: request)

  #expect(arguments.contains("plan"))
  #expect(arguments.contains("--sandbox"))
  #expect(arguments.contains("--dangerously-skip-permissions"))
  #expect(!arguments.contains("accept-edits"))
}

@Test func aiTaskManagerRoutesDifferentProvidersConcurrently() async throws {
  let probe = AITaskExecutionProbe()
  let manager = CodexAgentManager(
    adapters: [
      .codex: ProbedAITaskAdapter(provider: .codex, probe: probe),
      .antigravity: ProbedAITaskAdapter(provider: .antigravity, probe: probe),
    ],
    storeURL: nil)
  let directory = FileManager.default.temporaryDirectory.path

  let codex = try await manager.start(
    CodexTaskRequest(provider: .codex, prompt: "Codex", workingDirectory: directory))
  let antigravity = try await manager.start(
    CodexTaskRequest(provider: .antigravity, prompt: "Antigravity", workingDirectory: directory))

  #expect(await waitForCodexTask(codex.id, in: manager, status: .completed)?.result == "Codex")
  #expect(
    await waitForCodexTask(antigravity.id, in: manager, status: .completed)?.result
      == "Antigravity")
  #expect(await probe.maximumActive >= 2)
  #expect(await probe.providers == Set([.codex, .antigravity]))
}

@Test func aiTaskRejectsRootDirectoryForWorkspaceWrite() async {
  let manager = CodexAgentManager(adapter: SuccessfulCodexAdapter(), storeURL: nil)
  do {
    _ = try await manager.start(
      CodexTaskRequest(
        prompt: "変更", workingDirectory: "/", sandboxMode: .workspaceWrite))
    Issue.record("ルートフォルダへの書き込みタスクが開始されました。")
  } catch let error as CodexAgentError {
    #expect(error.localizedDescription.contains("ルートフォルダ"))
  } catch {
    Issue.record("予期しないエラー: \(error)")
  }
}
