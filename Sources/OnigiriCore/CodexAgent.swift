import Foundation

public enum AITaskProvider: String, Codable, Sendable, CaseIterable, Identifiable {
  case codex
  case antigravity
  case claudeCode

  public var id: String { rawValue }
  public var name: String {
    switch self {
    case .codex: return "Codex"
    case .antigravity: return "Antigravity"
    case .claudeCode: return "Claude Code"
    }
  }
}

public enum CodexTaskStatus: String, Codable, Sendable, CaseIterable {
  case running
  case completed
  case failed
  case cancelled
  case timedOut
}

public enum CodexSandboxMode: String, Codable, Sendable, CaseIterable {
  case readOnly = "read-only"
  case workspaceWrite = "workspace-write"
}

public struct CodexTaskRequest: Codable, Sendable, Equatable {
  public let provider: AITaskProvider
  public let prompt: String
  public let workingDirectory: String
  public let model: String?
  public let sandboxMode: CodexSandboxMode
  public let timeoutSeconds: Int

  public init(
    provider: AITaskProvider = .codex, prompt: String, workingDirectory: String, model: String? = nil,
    sandboxMode: CodexSandboxMode = .readOnly, timeoutSeconds: Int = 600
  ) {
    self.provider = provider
    self.prompt = prompt
    self.workingDirectory = workingDirectory
    self.model = model
    self.sandboxMode = sandboxMode
    self.timeoutSeconds = min(max(timeoutSeconds, 10), 3_600)
  }

  private enum CodingKeys: String, CodingKey {
    case provider, prompt, workingDirectory, model, sandboxMode, timeoutSeconds
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try values.decodeIfPresent(AITaskProvider.self, forKey: .provider) ?? .codex,
      prompt: try values.decode(String.self, forKey: .prompt),
      workingDirectory: try values.decode(String.self, forKey: .workingDirectory),
      model: try values.decodeIfPresent(String.self, forKey: .model),
      sandboxMode: try values.decodeIfPresent(CodexSandboxMode.self, forKey: .sandboxMode) ?? .readOnly,
      timeoutSeconds: try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 600)
  }
}

public struct CodexTaskProgress: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let kind: String
  public let message: String

  public init(
    id: UUID = UUID(), createdAt: Date = Date(), kind: String, message: String
  ) {
    self.id = id
    self.createdAt = createdAt
    self.kind = kind
    self.message = message
  }
}

public struct CodexTaskRecord: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public var updatedAt: Date
  public let request: CodexTaskRequest
  public var status: CodexTaskStatus
  public var progress: [CodexTaskProgress]
  public var result: String?
  public var error: String?
  public var threadID: String?
  public var exitCode: Int32?

  public init(
    id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(),
    request: CodexTaskRequest, status: CodexTaskStatus = .running,
    progress: [CodexTaskProgress] = [], result: String? = nil, error: String? = nil,
    threadID: String? = nil, exitCode: Int32? = nil
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.request = request
    self.status = status
    self.progress = progress
    self.result = result
    self.error = error
    self.threadID = threadID
    self.exitCode = exitCode
  }
}

public struct CodexTaskListResponse: Codable, Sendable, Equatable {
  public let tasks: [CodexTaskRecord]
  public init(tasks: [CodexTaskRecord]) { self.tasks = tasks }
}

public struct CodexAvailability: Codable, Sendable, Equatable {
  public let provider: AITaskProvider
  public let available: Bool
  public let executablePath: String?
  public let detail: String

  public init(
    provider: AITaskProvider = .codex, available: Bool, executablePath: String?, detail: String
  ) {
    self.provider = provider
    self.available = available
    self.executablePath = executablePath
    self.detail = detail
  }
}

public struct AITaskAvailabilityResponse: Codable, Sendable, Equatable {
  public let providers: [CodexAvailability]
  public init(providers: [CodexAvailability]) { self.providers = providers }
}

public struct CodexTaskActionRequest: Codable, Sendable, Equatable {
  public let id: UUID
  public init(id: UUID) { self.id = id }
}

public enum CodexAgentError: LocalizedError {
  case unavailable(String)
  case invalidRequest(String)
  case taskNotFound
  case timedOut
  case processFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let detail): return detail
    case .invalidRequest(let detail): return detail
    case .taskNotFound: return "AIタスクが見つかりません。"
    case .timedOut: return "AIタスクがタイムアウトしました。"
    case .processFailed(let detail): return detail
    }
  }
}

public struct CodexAdapterResult: Sendable, Equatable {
  public let result: String
  public let threadID: String?
  public let exitCode: Int32

  public init(result: String, threadID: String?, exitCode: Int32) {
    self.result = result
    self.threadID = threadID
    self.exitCode = exitCode
  }
}

public protocol CodexAdapter: Sendable {
  func availability() async -> CodexAvailability
  func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult
}

public actor CodexAgentManager {
  public static var defaultStoreURL: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appending(path: "OnigiriHarness", directoryHint: .isDirectory)
      .appending(path: "codex-tasks.json")
  }

  private let adapters: [AITaskProvider: any CodexAdapter]
  private let storeURL: URL?
  private var records: [CodexTaskRecord]
  private var activeTasks: [UUID: Task<Void, Never>] = [:]

  public init(
    adapter: (any CodexAdapter)? = nil,
    storeURL: URL? = CodexAgentManager.defaultStoreURL
  ) {
    if let adapter {
      adapters = [.codex: adapter]
    } else {
      adapters = [
        .codex: CodexCLIAdapter(),
        .antigravity: AntigravityCLIAdapter(),
        .claudeCode: ClaudeCodeCLIAdapter(),
      ]
    }
    self.storeURL = storeURL
    records = storeURL.flatMap { try? Self.load(from: $0) } ?? []
    for index in records.indices where records[index].status == .running {
      records[index].status = .failed
      records[index].error = "OnigiriServerの終了によりタスクが中断されました。"
      records[index].updatedAt = Date()
    }
  }

  public init(
    adapters: [AITaskProvider: any CodexAdapter],
    storeURL: URL? = CodexAgentManager.defaultStoreURL
  ) {
    self.adapters = adapters
    self.storeURL = storeURL
    records = storeURL.flatMap { try? Self.load(from: $0) } ?? []
    for index in records.indices where records[index].status == .running {
      records[index].status = .failed
      records[index].error = "OnigiriServerの終了によりタスクが中断されました。"
      records[index].updatedAt = Date()
    }
  }

  public func availability() async -> CodexAvailability {
    await adapters[.codex]?.availability()
      ?? CodexAvailability(available: false, executablePath: nil, detail: "Codex Adapterがありません。")
  }

  public func availabilities() async -> AITaskAvailabilityResponse {
    var results: [CodexAvailability] = []
    for provider in AITaskProvider.allCases {
      if let adapter = adapters[provider] {
        let availability = await adapter.availability()
        results.append(CodexAvailability(
          provider: provider, available: availability.available,
          executablePath: availability.executablePath, detail: availability.detail))
      } else {
        results.append(CodexAvailability(
          provider: provider, available: false, executablePath: nil,
          detail: "\(provider.name) Adapterがありません。"))
      }
    }
    return AITaskAvailabilityResponse(providers: results)
  }

  public func list() -> CodexTaskListResponse {
    CodexTaskListResponse(tasks: records.sorted { $0.updatedAt > $1.updatedAt })
  }

  public func start(_ request: CodexTaskRequest) async throws -> CodexTaskRecord {
    let validated = try Self.validate(request)
    guard let adapter = adapters[validated.provider] else {
      throw CodexAgentError.unavailable("\(validated.provider.name) Adapterがありません。")
    }
    let availability = await adapter.availability()
    guard availability.available else { throw CodexAgentError.unavailable(availability.detail) }
    let record = CodexTaskRecord(
      request: validated,
      progress: [CodexTaskProgress(
        kind: "task.started", message: "\(validated.provider.name)タスクを開始しました。")])
    records.insert(record, at: 0)
    trimAndSave()
    let id = record.id
    activeTasks[id] = Task { [weak self] in
      await self?.execute(id: id, request: validated, adapter: adapter)
    }
    return record
  }

  public func cancel(_ id: UUID) throws -> CodexTaskRecord {
    guard let index = records.firstIndex(where: { $0.id == id }) else {
      throw CodexAgentError.taskNotFound
    }
    guard records[index].status == .running else { return records[index] }
    activeTasks[id]?.cancel()
    records[index].status = .cancelled
    records[index].updatedAt = Date()
    records[index].error = "ユーザーがタスクをキャンセルしました。"
    records[index].progress.append(
      CodexTaskProgress(kind: "task.cancelled", message: "キャンセルしました。"))
    trimAndSave()
    return records[index]
  }

  private func execute(
    id: UUID, request: CodexTaskRequest, adapter: any CodexAdapter
  ) async {
    do {
      let result = try await adapter.run(request: request) { [weak self] progress in
        await self?.append(progress, to: id)
      }
      guard let index = records.firstIndex(where: { $0.id == id }),
        records[index].status == .running else { return }
      records[index].status = .completed
      records[index].updatedAt = Date()
      records[index].result = result.result
      records[index].threadID = result.threadID
      records[index].exitCode = result.exitCode
      records[index].progress.append(
        CodexTaskProgress(
          kind: "task.completed", message: "\(request.provider.name)タスクが完了しました。"))
    } catch is CancellationError {
      // cancel(_:) already records the user-facing state.
    } catch CodexAgentError.timedOut {
      updateFailure(id: id, status: .timedOut, message: CodexAgentError.timedOut.localizedDescription)
    } catch {
      updateFailure(id: id, status: .failed, message: error.localizedDescription)
    }
    activeTasks.removeValue(forKey: id)
    trimAndSave()
  }

  private func append(_ progress: CodexTaskProgress, to id: UUID) {
    guard let index = records.firstIndex(where: { $0.id == id }),
      records[index].status == .running else { return }
    records[index].progress.append(progress)
    if records[index].progress.count > 200 {
      records[index].progress.removeFirst(records[index].progress.count - 200)
    }
    records[index].updatedAt = Date()
    trimAndSave()
  }

  private func updateFailure(id: UUID, status: CodexTaskStatus, message: String) {
    guard let index = records.firstIndex(where: { $0.id == id }),
      records[index].status == .running else { return }
    records[index].status = status
    records[index].updatedAt = Date()
    records[index].error = message
    records[index].progress.append(CodexTaskProgress(kind: "task.\(status.rawValue)", message: message))
  }

  private func trimAndSave() {
    records = Array(records.sorted { $0.updatedAt > $1.updatedAt }.prefix(100))
    guard let storeURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(records).write(to: storeURL, options: .atomic)
    } catch {
      // A persistence failure must not terminate a running Codex process.
    }
  }

  private static func validate(_ request: CodexTaskRequest) throws -> CodexTaskRequest {
    let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, prompt.count <= 20_000 else {
      throw CodexAgentError.invalidRequest("AIへの指示は1〜20,000文字で入力してください。")
    }
    let directory = URL(fileURLWithPath: request.workingDirectory).standardizedFileURL
      .resolvingSymlinksInPath().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
      isDirectory.boolValue else {
      throw CodexAgentError.invalidRequest("作業フォルダが見つかりません。")
    }
    if request.sandboxMode == .workspaceWrite {
      guard directory != "/" else {
        throw CodexAgentError.invalidRequest("書き込みタスクではルートフォルダを指定できません。")
      }
      guard FileManager.default.isWritableFile(atPath: directory) else {
        throw CodexAgentError.invalidRequest("作業フォルダへの書き込み権限がありません。")
      }
    }
    let model = request.model?.trimmingCharacters(in: .whitespacesAndNewlines)
    return CodexTaskRequest(
      provider: request.provider, prompt: prompt, workingDirectory: directory,
      model: model?.isEmpty == false ? model : nil,
      sandboxMode: request.sandboxMode, timeoutSeconds: request.timeoutSeconds)
  }

  private static func load(from url: URL) throws -> [CodexTaskRecord] {
    try JSONDecoder().decode([CodexTaskRecord].self, from: Data(contentsOf: url))
  }
}

public struct CodexCLIAdapter: CodexAdapter {
  private let executablePath: String?

  public init(executablePath: String? = nil) {
    self.executablePath = executablePath ?? Self.findExecutable()
  }

  public func availability() async -> CodexAvailability {
    guard let executablePath else {
      return CodexAvailability(
        available: false, executablePath: nil,
        detail: "Codex CLIが見つかりません。Codex CLIをインストールしてログインしてください。")
    }
    return CodexAvailability(
      available: true, executablePath: executablePath,
      detail: "Codex CLIを利用できます。")
  }

  public func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    guard let executablePath else {
      throw CodexAgentError.unavailable("Codex CLIが見つかりません。")
    }
    let outputURL = FileManager.default.temporaryDirectory
      .appending(path: "onigiri-codex-\(UUID().uuidString).jsonl")
    let errorURL = FileManager.default.temporaryDirectory
      .appending(path: "onigiri-codex-\(UUID().uuidString).stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outputURL)
      try? FileManager.default.removeItem(at: errorURL)
    }
    let outputWriter = try FileHandle(forWritingTo: outputURL)
    let errorWriter = try FileHandle(forWritingTo: errorURL)
    defer {
      try? outputWriter.close()
      try? errorWriter.close()
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    let arguments = Self.arguments(for: request)
    process.arguments = arguments
    process.standardOutput = outputWriter
    process.standardError = errorWriter
    try process.run()

    let startedAt = Date()
    var offset: UInt64 = 0
    var pending = ""
    var finalResult = ""
    var threadID: String?
    while process.isRunning {
      if Task.isCancelled {
        process.terminate()
        throw CancellationError()
      }
      if Date().timeIntervalSince(startedAt) >= Double(request.timeoutSeconds) {
        process.terminate()
        throw CodexAgentError.timedOut
      }
      let parsed = try await readEvents(
        from: outputURL, offset: &offset, pending: &pending, onProgress: onProgress)
      if let result = parsed.result { finalResult = result }
      if let id = parsed.threadID { threadID = id }
      try await Task.sleep(for: .milliseconds(150))
    }
    process.waitUntilExit()
    let parsed = try await readEvents(
      from: outputURL, offset: &offset, pending: &pending, flush: true,
      onProgress: onProgress)
    if let result = parsed.result { finalResult = result }
    if let id = parsed.threadID { threadID = id }
    let stderr = (try? String(contentsOf: errorURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard process.terminationStatus == 0 else {
      throw CodexAgentError.processFailed(
        stderr.isEmpty ? "Codex CLIが終了コード\(process.terminationStatus)で終了しました。" : stderr)
    }
    return CodexAdapterResult(
      result: finalResult.isEmpty ? "Codexタスクは完了しました。" : finalResult,
      threadID: threadID, exitCode: process.terminationStatus)
  }

  static func arguments(for request: CodexTaskRequest) -> [String] {
    // `--approve-for-me` forces workspace-write in current Codex CLI releases and
    // cannot be combined with an explicit sandbox. AI tasks already have no
    // interactive approval channel, so fail commands instead of waiting for one.
    var arguments = ["-a", "never", "-s", request.sandboxMode.rawValue]
    if let model = request.model { arguments.append(contentsOf: ["-m", model]) }
    arguments.append(contentsOf: [
      "exec", "--json", "--color", "never", "--ephemeral", "--skip-git-repo-check",
      "-C", request.workingDirectory, request.prompt,
    ])
    return arguments
  }

  private func readEvents(
    from url: URL, offset: inout UInt64, pending: inout String, flush: Bool = false,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> (result: String?, threadID: String?) {
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    try reader.seek(toOffset: offset)
    let data = try reader.readToEnd() ?? Data()
    offset += UInt64(data.count)
    pending += String(decoding: data, as: UTF8.self)
    var lines = pending.components(separatedBy: .newlines)
    pending = flush ? "" : (lines.popLast() ?? "")
    var result: String?
    var threadID: String?
    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let data = line.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      let type = object["type"] as? String ?? "event"
      if type == "thread.started" { threadID = object["thread_id"] as? String }
      let item = object["item"] as? [String: Any]
      let message = Self.eventMessage(type: type, object: object, item: item)
      if type == "item.completed", item?["type"] as? String == "agent_message",
        let text = item?["text"] as? String
      {
        result = text
      }
      if let message, !message.isEmpty {
        await onProgress(CodexTaskProgress(kind: type, message: String(message.prefix(4_000))))
      }
    }
    return (result, threadID)
  }

  private static func eventMessage(
    type: String, object: [String: Any], item: [String: Any]?
  ) -> String? {
    if let text = item?["text"] as? String { return text }
    if let command = item?["command"] as? String { return command }
    if let message = object["message"] as? String { return message }
    if type == "turn.completed", let usage = object["usage"] as? [String: Any] {
      return "turn completed: \(usage)"
    }
    return nil
  }

  private static func findExecutable() -> String? {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    if let configured = environment["ONIGIRI_CODEX_EXECUTABLE"] { candidates.append(configured) }
    candidates.append(contentsOf: [
      NSHomeDirectory() + "/.local/bin/codex",
      "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex",
    ])
    if let path = environment["PATH"] {
      candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}
