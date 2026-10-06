import Foundation
import OnigiriCore

private struct EvaluationSuite: Decodable {
  let cases: [EvaluationCase]
}

private struct EvaluationCase: Decodable {
  let id: UUID
  let question: String
  let expectedMatches: [KnowledgeChunkMatch]
  let expectedSearch: Bool
  let criteria: RAGEvaluationCriteria
  let expectedAnswerPoints: [String]
  let forbiddenAnswerPhrases: [String]

  private enum CodingKeys: String, CodingKey {
    case id, question, expectedMatches, expectedSearch, criteria, expectedAnswerPoints
    case forbiddenAnswerPhrases
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    question = try container.decode(String.self, forKey: .question)
    expectedMatches = try container.decode([KnowledgeChunkMatch].self, forKey: .expectedMatches)
    expectedSearch =
      try container.decodeIfPresent(Bool.self, forKey: .expectedSearch)
      ?? !expectedMatches.isEmpty
    criteria = try container.decodeIfPresent(RAGEvaluationCriteria.self, forKey: .criteria) ?? .default
    expectedAnswerPoints =
      try container.decodeIfPresent([String].self, forKey: .expectedAnswerPoints) ?? []
    forbiddenAnswerPhrases =
      try container.decodeIfPresent([String].self, forKey: .forbiddenAnswerPhrases) ?? []
  }
}

private struct Options {
  enum OutputFormat: String { case markdown, json }

  let suiteURL: URL
  let serverURL: URL
  let outputURL: URL?
  let failedOnly: Bool
  let format: OutputFormat
  let providerID: String?
  let baseURL: String?
  let modelID: String?
  let ragMode: RAGMode
  let searchSettings: KnowledgeSearchSettings

  static func parse(_ arguments: [String]) throws -> Self {
    var suite: String?
    var server = "http://127.0.0.1:18080"
    var output: String?
    var failedOnly = false
    var format = OutputFormat.markdown
    var providerID: String?
    var baseURL: String?
    var modelID: String?
    var ragMode = RAGMode.always
    var limit = 5
    var minScore = 1
    var keywordWeight = 1.0
    var embeddingWeight = 1.0
    var index = 0
    while index < arguments.count {
      switch arguments[index] {
      case "--suite":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        suite = arguments[index]
      case "--server":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        server = arguments[index]
      case "--output":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        output = arguments[index]
      case "--failed-only": failedOnly = true
      case "--format":
        index += 1
        guard index < arguments.count, let value = OutputFormat(rawValue: arguments[index]) else {
          throw CLIError.invalidValue("--format は markdown または json を指定してください。")
        }
        format = value
      case "--provider":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        providerID = arguments[index]
      case "--base-url":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        baseURL = arguments[index]
      case "--model":
        index += 1
        guard index < arguments.count else { throw CLIError.usage }
        modelID = arguments[index]
      case "--rag-mode":
        index += 1
        guard index < arguments.count, let value = RAGMode(rawValue: arguments[index]) else {
          throw CLIError.invalidValue("--rag-mode は disabled、always、agentic のいずれかです。")
        }
        ragMode = value
      case "--limit":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]) else {
          throw CLIError.invalidValue("--limit は整数で指定してください。")
        }
        limit = value
      case "--min-score":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]) else {
          throw CLIError.invalidValue("--min-score は整数で指定してください。")
        }
        minScore = value
      case "--keyword-weight":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
          throw CLIError.invalidValue("--keyword-weight は数値で指定してください。")
        }
        keywordWeight = value
      case "--embedding-weight":
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
          throw CLIError.invalidValue("--embedding-weight は数値で指定してください。")
        }
        embeddingWeight = value
      case "--help", "-h": throw CLIError.help
      default: throw CLIError.invalidArgument(arguments[index])
      }
      index += 1
    }
    guard let suite else { throw CLIError.usage }
    guard let serverURL = URL(string: server) else { throw CLIError.invalidServer(server) }
    return Self(
      suiteURL: URL(fileURLWithPath: suite), serverURL: serverURL,
      outputURL: output.map(URL.init(fileURLWithPath:)), failedOnly: failedOnly,
      format: format, providerID: providerID, baseURL: baseURL, modelID: modelID,
      ragMode: ragMode,
      searchSettings: KnowledgeSearchSettings(
        limit: limit, minScore: minScore, keywordWeight: keywordWeight,
        embeddingWeight: embeddingWeight))
  }
}

private enum CLIError: LocalizedError {
  case usage, help, invalidArgument(String), invalidValue(String), invalidServer(String), server(String)

  var errorDescription: String? {
    switch self {
    case .usage: return "--suite <JSON> が必要です。"
    case .help: return nil
    case .invalidArgument(let value): return "不明な引数です: \(value)"
    case .invalidValue(let value): return value
    case .invalidServer(let value): return "サーバーURLが正しくありません: \(value)"
    case .server(let value): return value
    }
  }
}

@main
private enum OnigiriEvalCLI {
  static func main() async {
    do {
      let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
      let evaluationCases = try loadCases(options.suiteURL)
      guard !evaluationCases.isEmpty else { throw CLIError.server("評価ケースがありません。") }
      if let providerID = options.providerID {
        try await configureProvider(
          ProviderConfig(providerID: providerID, baseURL: options.baseURL, modelID: options.modelID),
          serverURL: options.serverURL)
      }
      let startedAt = Date()
      var entries: [RAGEvaluationReportEntry] = []
      for (offset, evaluationCase) in evaluationCases.enumerated() {
        FileHandle.standardError.write(
          Data("[\(offset + 1)/\(evaluationCases.count)] \(evaluationCase.question)\n".utf8))
        let result = try await run(
          evaluationCase, serverURL: options.serverURL,
          ragMode: options.ragMode, searchSettings: options.searchSettings)
        entries.append(RAGEvaluationReportEntry(
          profileName: options.modelID ?? options.providerID ?? result.modelID ?? result.providerName,
          caseID: evaluationCase.id, question: evaluationCase.question,
          searchSettings: options.searchSettings, criteria: evaluationCase.criteria, result: result))
      }
      let report = RAGEvaluationReport(
        createdAt: startedAt, trigger: .commandLine, entries: entries)
      let outputData: Data
      switch options.format {
      case .markdown:
        outputData = Data(report.markdown(failedOnly: options.failedOnly).utf8)
      case .json:
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        outputData = try encoder.encode(report)
      }
      if let outputURL = options.outputURL {
        try outputData.write(to: outputURL, options: .atomic)
        print("レポートを書き出しました: \(outputURL.path)")
      } else {
        FileHandle.standardOutput.write(outputData)
        FileHandle.standardOutput.write(Data("\n".utf8))
      }
      Foundation.exit(report.failedCount == 0 ? 0 : 1)
    } catch CLIError.help {
      printUsage()
    } catch {
      FileHandle.standardError.write(Data("エラー: \(error.localizedDescription)\n".utf8))
      printUsage(to: .standardError)
      Foundation.exit(2)
    }
  }

  private static func loadCases(_ url: URL) throws -> [EvaluationCase] {
    let data = try Data(contentsOf: url)
    let isoDecoder = JSONDecoder()
    isoDecoder.dateDecodingStrategy = .iso8601
    if let suite = try? isoDecoder.decode(EvaluationSuite.self, from: data) { return suite.cases }
    if let cases = try? isoDecoder.decode([EvaluationCase].self, from: data) { return cases }
    return try JSONDecoder().decode([EvaluationCase].self, from: data)
  }

  private static func run(
    _ evaluationCase: EvaluationCase, serverURL: URL,
    ragMode: RAGMode, searchSettings: KnowledgeSearchSettings
  ) async throws -> RAGEvaluationResponse {
    var request = URLRequest(url: serverURL.appending(path: "evaluation/run"))
    request.httpMethod = "POST"
    request.timeoutInterval = 180
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(RAGEvaluationRequest(
      question: evaluationCase.question,
      expectedChunkIDs: evaluationCase.expectedMatches.map(\.id),
      ragMode: ragMode, expectedSearch: evaluationCase.expectedSearch,
      searchSettings: searchSettings,
      expectedAnswerPoints: evaluationCase.expectedAnswerPoints,
      forbiddenAnswerPhrases: evaluationCase.forbiddenAnswerPhrases))
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let detail = (try? JSONDecoder().decode(APIError.self, from: data).error)
        ?? "RAG評価を実行できませんでした。"
      throw CLIError.server(detail)
    }
    return try JSONDecoder().decode(RAGEvaluationResponse.self, from: data)
  }

  private static func configureProvider(
    _ config: ProviderConfig, serverURL: URL
  ) async throws {
    var request = URLRequest(url: serverURL.appending(path: "provider"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(config)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let detail = (try? JSONDecoder().decode(APIError.self, from: data).error)
        ?? "評価環境へ切り替えられませんでした。"
      throw CLIError.server(detail)
    }
  }

  private static func printUsage(to handle: FileHandle = .standardOutput) {
    let text = """
      使い方: onigiri-eval --suite <評価JSON> [オプション]
        --server <URL>                    OnigiriServer（既定: http://127.0.0.1:18080）
        --provider <ID> [--base-url URL] [--model ID]
        --rag-mode disabled|always|agentic
        --limit N --min-score N --keyword-weight N --embedding-weight N
        --format markdown|json --output <ファイル> --failed-only
      実行中の OnigiriServer に評価ケースを送り、MarkdownまたはJSONレポートを生成します。
      """ + "\n"
    handle.write(Data(text.utf8))
  }
}
