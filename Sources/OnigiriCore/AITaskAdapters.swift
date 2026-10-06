import Foundation

private struct CLIParsedEvent {
  var progress: [CodexTaskProgress] = []
  var result: String?
  var resultDelta: String?
  var sessionID: String?
  var failure: String?
}

private final class CLIResultState: @unchecked Sendable {
  var result = ""
  var sessionID: String?
  var failure: String?
}

private enum CLIAdapterSupport {
  static func findExecutable(configured: String?, names: [String]) -> String? {
    var candidates: [String] = []
    if let configured { candidates.append(configured) }
    for name in names {
      candidates.append(contentsOf: [
        NSHomeDirectory() + "/.local/bin/\(name)",
        "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)",
      ])
    }
    if let path = ProcessInfo.processInfo.environment["PATH"] {
      for directory in path.split(separator: ":") {
        candidates.append(contentsOf: names.map { "\(directory)/\($0)" })
      }
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  static func run(
    executablePath: String, arguments: [String], request: CodexTaskRequest,
    parse: @escaping (String) -> CLIParsedEvent,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    let outputURL = FileManager.default.temporaryDirectory
      .appending(path: "onigiri-agent-\(UUID().uuidString).jsonl")
    let errorURL = FileManager.default.temporaryDirectory
      .appending(path: "onigiri-agent-\(UUID().uuidString).stderr")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    FileManager.default.createFile(atPath: errorURL.path, contents: nil)
    defer {
      try? FileManager.default.removeItem(at: outputURL)
      try? FileManager.default.removeItem(at: errorURL)
    }
    let outputWriter = try FileHandle(forWritingTo: outputURL)
    let errorWriter = try FileHandle(forWritingTo: errorURL)
    defer { try? outputWriter.close(); try? errorWriter.close() }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: request.workingDirectory)
    process.standardOutput = outputWriter
    process.standardError = errorWriter
    try process.run()

    let state = CLIResultState()
    let startedAt = Date()
    var offset: UInt64 = 0
    var pending = ""
    while process.isRunning {
      if Task.isCancelled {
        process.terminate()
        throw CancellationError()
      }
      if Date().timeIntervalSince(startedAt) >= Double(request.timeoutSeconds) {
        process.terminate()
        throw CodexAgentError.timedOut
      }
      try await readEvents(
        from: outputURL, offset: &offset, pending: &pending, parse: parse,
        state: state, onProgress: onProgress)
      try await Task.sleep(for: .milliseconds(150))
    }
    process.waitUntilExit()
    try await readEvents(
      from: outputURL, offset: &offset, pending: &pending, flush: true, parse: parse,
      state: state, onProgress: onProgress)
    let stderr = (try? String(contentsOf: errorURL, encoding: .utf8))?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let failure = state.failure, !failure.isEmpty {
      throw CodexAgentError.processFailed(failure)
    }
    guard process.terminationStatus == 0 else {
      throw CodexAgentError.processFailed(
        stderr.isEmpty
          ? "\(request.provider.name)が終了コード\(process.terminationStatus)で終了しました。"
          : stderr)
    }
    return CodexAdapterResult(
      result: state.result.isEmpty ? "\(request.provider.name)タスクは完了しました。" : state.result,
      threadID: state.sessionID, exitCode: process.terminationStatus)
  }

  private static func readEvents(
    from url: URL, offset: inout UInt64, pending: inout String, flush: Bool = false,
    parse: @escaping (String) -> CLIParsedEvent, state: CLIResultState,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws {
    let reader = try FileHandle(forReadingFrom: url)
    defer { try? reader.close() }
    try reader.seek(toOffset: offset)
    let data = try reader.readToEnd() ?? Data()
    offset += UInt64(data.count)
    pending += String(decoding: data, as: UTF8.self)
    var lines = pending.components(separatedBy: .newlines)
    pending = flush ? "" : (lines.popLast() ?? "")
    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      let event = parse(line)
      if let result = event.result, !result.isEmpty { state.result = result }
      if let delta = event.resultDelta, !delta.isEmpty { state.result += delta }
      if let sessionID = event.sessionID { state.sessionID = sessionID }
      if let failure = event.failure { state.failure = failure }
      for progress in event.progress { await onProgress(progress) }
    }
  }
}

public struct AntigravityCLIAdapter: CodexAdapter {
  private let executablePath: String?

  public init(executablePath: String? = nil) {
    self.executablePath = executablePath ?? CLIAdapterSupport.findExecutable(
      configured: ProcessInfo.processInfo.environment["ONIGIRI_AGY_EXECUTABLE"], names: ["agy"])
  }

  public func availability() async -> CodexAvailability {
    guard let executablePath else {
      return CodexAvailability(
        provider: .antigravity, available: false, executablePath: nil,
        detail: "Antigravity CLIが見つかりません。agyをインストールしてログインしてください。")
    }
    return CodexAvailability(
      provider: .antigravity, available: true, executablePath: executablePath,
      detail: "Antigravity CLIを利用できます。")
  }

  public func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    guard let executablePath else {
      throw CodexAgentError.unavailable("Antigravity CLIが見つかりません。")
    }
    return try await CLIAdapterSupport.run(
      executablePath: executablePath, arguments: Self.arguments(for: request), request: request,
      parse: Self.parse, onProgress: onProgress)
  }

  static func arguments(for request: CodexTaskRequest) -> [String] {
    var arguments = [
      "--output-format", "stream-json", "--print-timeout", "\(request.timeoutSeconds)s",
    ]
    if let model = request.model { arguments.append(contentsOf: ["--model", model]) }
    switch request.sandboxMode {
    case .readOnly:
      // Print mode cannot display a permission prompt. Keep the plan-mode and
      // terminal sandbox restrictions, but auto-approve read-only tool calls so
      // the agent can finish with a result instead of returning an empty success.
      arguments.append(contentsOf: [
        "--mode", "plan", "--sandbox", "--dangerously-skip-permissions",
      ])
    case .workspaceWrite:
      arguments.append(contentsOf: ["--mode", "accept-edits", "--dangerously-skip-permissions"])
    }
    arguments.append(contentsOf: ["--print", request.prompt])
    return arguments
  }

  private static func parse(_ line: String) -> CLIParsedEvent {
    guard let data = line.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return CLIParsedEvent() }
    let eventName = root["event"] as? String ?? "event"
    var parsed = CLIParsedEvent()
    if let id = root["conversation_id"] as? String { parsed.sessionID = id }
    if let update = root["step_update"] as? [String: Any] {
      let kind = update["step_type"] as? String ?? eventName
      if let delta = update["text_delta"] as? String, !delta.isEmpty {
        parsed.progress.append(CodexTaskProgress(kind: kind, message: String(delta.prefix(4_000))))
        if kind == "agent_response" { parsed.resultDelta = delta }
      } else if let state = update["state"] as? String {
        parsed.progress.append(CodexTaskProgress(kind: kind, message: state))
      }
      if let id = update["conversation_id"] as? String { parsed.sessionID = id }
    }
    if let result = root["result"] as? [String: Any] {
      parsed.result = result["response"] as? String
      if let id = result["conversation_id"] as? String { parsed.sessionID = id }
      let status = (result["status"] as? String ?? "").uppercased()
      if ["ERROR", "CANCELED", "INTERRUPTED", "INVALID", "WAITING"].contains(status) {
        parsed.failure = result["error"] as? String ?? "Antigravityタスクは\(status)で終了しました。"
      }
    }
    return parsed
  }
}

public struct ClaudeCodeCLIAdapter: CodexAdapter {
  private let executablePath: String?

  public init(executablePath: String? = nil) {
    self.executablePath = executablePath ?? CLIAdapterSupport.findExecutable(
      configured: ProcessInfo.processInfo.environment["ONIGIRI_CLAUDE_EXECUTABLE"], names: ["claude"])
  }

  public func availability() async -> CodexAvailability {
    guard let executablePath else {
      return CodexAvailability(
        provider: .claudeCode, available: false, executablePath: nil,
        detail: "Claude Codeが見つかりません。インストールしてログインしてください。")
    }
    return CodexAvailability(
      provider: .claudeCode, available: true, executablePath: executablePath,
      detail: "Claude Codeを利用できます。")
  }

  public func run(
    request: CodexTaskRequest,
    onProgress: @escaping @Sendable (CodexTaskProgress) async -> Void
  ) async throws -> CodexAdapterResult {
    guard let executablePath else { throw CodexAgentError.unavailable("Claude Codeが見つかりません。") }
    var arguments = [
      "--print", request.prompt, "--output-format", "stream-json", "--verbose",
      "--include-partial-messages", "--no-session-persistence", "--permission-mode",
      request.sandboxMode == .readOnly ? "plan" : "acceptEdits",
    ]
    if let model = request.model { arguments.append(contentsOf: ["--model", model]) }
    return try await CLIAdapterSupport.run(
      executablePath: executablePath, arguments: arguments, request: request,
      parse: Self.parse, onProgress: onProgress)
  }

  private static func parse(_ line: String) -> CLIParsedEvent {
    guard let data = line.data(using: .utf8),
      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return CLIParsedEvent() }
    let type = root["type"] as? String ?? "event"
    var parsed = CLIParsedEvent()
    parsed.sessionID = root["session_id"] as? String
    if type == "result" {
      parsed.result = root["result"] as? String
      if root["is_error"] as? Bool == true {
        parsed.failure = parsed.result ?? "Claude Codeタスクに失敗しました。"
      }
    }
    if let message = root["message"] as? [String: Any],
      let content = message["content"] as? [[String: Any]]
    {
      for item in content where item["type"] as? String == "text" {
        if let text = item["text"] as? String, !text.isEmpty {
          parsed.progress.append(CodexTaskProgress(kind: type, message: String(text.prefix(4_000))))
        }
      }
    }
    if let event = root["event"] as? [String: Any],
      let delta = event["delta"] as? [String: Any],
      let text = delta["text"] as? String, !text.isEmpty
    {
      parsed.progress.append(CodexTaskProgress(kind: type, message: String(text.prefix(4_000))))
    }
    return parsed
  }
}
