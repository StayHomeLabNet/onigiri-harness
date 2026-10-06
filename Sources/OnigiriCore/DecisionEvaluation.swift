import Foundation

public enum DecisionFallbackTarget: String, Codable, Sendable, CaseIterable {
  case none
  case languageModel
  case human
}

public struct DecisionThresholdOverride: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let model: String?
  public let questionID: String?
  public let threshold: Double
  public let fallback: DecisionFallbackTarget?

  public init(
    id: UUID = UUID(), model: String? = nil, questionID: String? = nil,
    threshold: Double, fallback: DecisionFallbackTarget? = nil
  ) {
    self.id = id
    self.model = model
    self.questionID = questionID
    self.threshold = min(max(threshold, 0), 1)
    self.fallback = fallback
  }
}

public struct DecisionRoutingPolicy: Codable, Sendable, Equatable {
  public let defaultThreshold: Double
  public let defaultFallback: DecisionFallbackTarget
  public let overrides: [DecisionThresholdOverride]

  public init(
    defaultThreshold: Double = 0.7, defaultFallback: DecisionFallbackTarget = .human,
    overrides: [DecisionThresholdOverride] = []
  ) {
    self.defaultThreshold = min(max(defaultThreshold, 0), 1)
    self.defaultFallback = defaultFallback
    self.overrides = overrides
  }

  public func rule(model: String, questionID: String) -> (threshold: Double, fallback: DecisionFallbackTarget) {
    let ranked = overrides.compactMap { override -> (Int, DecisionThresholdOverride)? in
      guard override.model == nil || override.model == model,
        override.questionID == nil || override.questionID == questionID
      else { return nil }
      return ((override.model == nil ? 0 : 1) + (override.questionID == nil ? 0 : 2), override)
    }.sorted { $0.0 > $1.0 }
    guard let override = ranked.first?.1 else { return (defaultThreshold, defaultFallback) }
    return (override.threshold, override.fallback ?? defaultFallback)
  }
}

public struct DecisionExpectedAnswer: Codable, Sendable, Equatable {
  public let choice: String?
  public let minimumScore: Double?
  public let maximumScore: Double?
  public let noul: Bool?

  public init(
    choice: String? = nil, minimumScore: Double? = nil, maximumScore: Double? = nil,
    noul: Bool? = nil
  ) {
    self.choice = choice
    self.minimumScore = minimumScore
    self.maximumScore = maximumScore
    self.noul = noul
  }
}

public struct DecisionEvaluationCase: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let state: JSONValue
  public let questionID: String
  public let question: DecisionQuestion
  public let expected: DecisionExpectedAnswer

  public init(
    id: UUID = UUID(), name: String, state: JSONValue, questionID: String,
    question: DecisionQuestion, expected: DecisionExpectedAnswer
  ) {
    self.id = id
    self.name = name
    self.state = state
    self.questionID = questionID
    self.question = question
    self.expected = expected
  }
}

public struct DecisionEvaluationEnvironment: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let name: String
  public let provider: DecisionProviderConfig
  public let model: String

  public init(
    id: UUID = UUID(), name: String, provider: DecisionProviderConfig, model: String
  ) {
    self.id = id
    self.name = name
    self.provider = provider
    self.model = model
  }

  public var redacted: DecisionEvaluationEnvironment {
    DecisionEvaluationEnvironment(id: id, name: name, provider: provider.redacted, model: model)
  }
}

public struct DecisionEvaluationRequest: Codable, Sendable, Equatable {
  public let environments: [DecisionEvaluationEnvironment]
  public let cases: [DecisionEvaluationCase]
  public let policy: DecisionRoutingPolicy

  public init(
    environments: [DecisionEvaluationEnvironment], cases: [DecisionEvaluationCase],
    policy: DecisionRoutingPolicy
  ) {
    self.environments = environments
    self.cases = cases
    self.policy = policy
  }
}

public struct DecisionEvaluationEntry: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let environmentID: UUID
  public let caseID: UUID
  public let model: String
  public let questionID: String
  public let predictedValue: String?
  public let correct: Bool?
  public let confidence: Double?
  public let calibrationError: Double?
  public let durationMilliseconds: Int
  public let appliedThreshold: Double
  public let simulatedFallback: DecisionFallbackTarget
  public let escalated: Bool
  public let error: String?

  public init(
    id: UUID = UUID(), environmentID: UUID, caseID: UUID, model: String,
    questionID: String, predictedValue: String? = nil, correct: Bool? = nil,
    confidence: Double? = nil, calibrationError: Double? = nil,
    durationMilliseconds: Int, appliedThreshold: Double,
    simulatedFallback: DecisionFallbackTarget, escalated: Bool, error: String? = nil
  ) {
    self.id = id
    self.environmentID = environmentID
    self.caseID = caseID
    self.model = model
    self.questionID = questionID
    self.predictedValue = predictedValue
    self.correct = correct
    self.confidence = confidence
    self.calibrationError = calibrationError
    self.durationMilliseconds = durationMilliseconds
    self.appliedThreshold = appliedThreshold
    self.simulatedFallback = simulatedFallback
    self.escalated = escalated
    self.error = error
  }
}

public struct DecisionEvaluationSummary: Codable, Sendable, Equatable, Identifiable {
  public var id: String { model }
  public let model: String
  public let totalCount: Int
  public let completedCount: Int
  public let accuracy: Double
  public let calibrationError: Double
  public let averageDurationMilliseconds: Double
  public let escalationRate: Double

  public init(
    model: String, totalCount: Int, completedCount: Int, accuracy: Double,
    calibrationError: Double, averageDurationMilliseconds: Double, escalationRate: Double
  ) {
    self.model = model
    self.totalCount = totalCount
    self.completedCount = completedCount
    self.accuracy = accuracy
    self.calibrationError = calibrationError
    self.averageDurationMilliseconds = averageDurationMilliseconds
    self.escalationRate = escalationRate
  }
}

public struct DecisionEvaluationReport: Codable, Sendable, Equatable, Identifiable {
  public let id: UUID
  public let createdAt: Date
  public let environments: [DecisionEvaluationEnvironment]
  public let cases: [DecisionEvaluationCase]
  public let policy: DecisionRoutingPolicy
  public let entries: [DecisionEvaluationEntry]
  public let summaries: [DecisionEvaluationSummary]

  public init(
    id: UUID = UUID(), createdAt: Date = Date(),
    environments: [DecisionEvaluationEnvironment], cases: [DecisionEvaluationCase],
    policy: DecisionRoutingPolicy, entries: [DecisionEvaluationEntry]
  ) {
    self.id = id
    self.createdAt = createdAt
    self.environments = environments.map(\.redacted)
    self.cases = cases
    self.policy = policy
    self.entries = entries
    self.summaries = Self.summarize(entries)
  }

  private static func summarize(_ entries: [DecisionEvaluationEntry]) -> [DecisionEvaluationSummary] {
    Dictionary(grouping: entries, by: \.model).map { model, values in
      let completed = values.filter { $0.correct != nil }
      let accuracy = completed.isEmpty ? 0 : Double(completed.filter { $0.correct == true }.count) / Double(completed.count)
      let calibration = completed.compactMap(\.calibrationError)
      let durations = values.map(\.durationMilliseconds)
      return DecisionEvaluationSummary(
        model: model, totalCount: values.count, completedCount: completed.count,
        accuracy: accuracy,
        calibrationError: calibration.isEmpty ? 0 : calibration.reduce(0, +) / Double(calibration.count),
        averageDurationMilliseconds: durations.isEmpty ? 0 : Double(durations.reduce(0, +)) / Double(durations.count),
        escalationRate: values.isEmpty ? 0 : Double(values.filter(\.escalated).count) / Double(values.count))
    }.sorted { $0.model < $1.model }
  }
}

public struct DecisionEvaluationReportList: Codable, Sendable, Equatable {
  public let reports: [DecisionEvaluationReport]
  public init(reports: [DecisionEvaluationReport]) { self.reports = reports }
}

public enum DecisionEvaluationAnalyzer {
  public static func entry(
    record: DecisionExperimentRecord, environment: DecisionEvaluationEnvironment,
    evaluationCase: DecisionEvaluationCase, policy: DecisionRoutingPolicy
  ) -> DecisionEvaluationEntry {
    let rule = policy.rule(model: environment.model, questionID: evaluationCase.questionID)
    guard record.status == .completed,
      case .object(let root)? = record.response,
      case .object(let answers)? = root["answers"],
      case .object(let answer)? = answers[evaluationCase.questionID]
    else {
      return DecisionEvaluationEntry(
        environmentID: environment.id, caseID: evaluationCase.id, model: environment.model,
        questionID: evaluationCase.questionID, durationMilliseconds: record.durationMilliseconds,
        appliedThreshold: rule.threshold, simulatedFallback: rule.fallback,
        escalated: rule.fallback != .none, error: record.error ?? "回答を解析できませんでした。")
    }

    let result = evaluate(answer: answer, expected: evaluationCase.expected, type: evaluationCase.question.type)
    let escalated = (result.confidence ?? 0) < rule.threshold && rule.fallback != .none
    return DecisionEvaluationEntry(
      environmentID: environment.id, caseID: evaluationCase.id, model: environment.model,
      questionID: evaluationCase.questionID, predictedValue: result.value,
      correct: result.correct, confidence: result.confidence,
      calibrationError: result.confidence.map { abs($0 - (result.correct ? 1 : 0)) },
      durationMilliseconds: record.durationMilliseconds, appliedThreshold: rule.threshold,
      simulatedFallback: rule.fallback, escalated: escalated)
  }

  private static func evaluate(
    answer: [String: JSONValue], expected: DecisionExpectedAnswer, type: DecisionQuestionType
  ) -> (value: String?, correct: Bool, confidence: Double?) {
    switch type {
    case .choice:
      let choice = answer["choice"]?.stringValue
      return (choice, choice == expected.choice, answer["confidence"]?.numberValue)
    case .score:
      let score = answer["score"]?.numberValue
      let minimum = expected.minimumScore ?? -.infinity
      let maximum = expected.maximumScore ?? .infinity
      return (score.map { String($0) }, score.map { $0 >= minimum && $0 <= maximum } ?? false, answer["confidence"]?.numberValue)
    case .noul:
      let probability = answer["noul"]?.numberValue
      let predicted = probability.map { $0 >= 0.5 }
      let confidence = probability.map { abs($0 - 0.5) * 2 }
      return (predicted.map { String($0) }, predicted.map { $0 == expected.noul } ?? false, confidence)
    }
  }
}

public actor DecisionEvaluationManager {
  public static var defaultStoreURL: URL {
    DecisionLabManager.defaultStoreURL.deletingLastPathComponent()
      .appending(path: "decision-evaluation-reports.json")
  }

  private let storeURL: URL?
  private var reports: [DecisionEvaluationReport]

  public init(storeURL: URL? = DecisionEvaluationManager.defaultStoreURL) {
    self.storeURL = storeURL
    reports = storeURL.flatMap { try? Self.load(from: $0) } ?? []
  }

  public func list() -> DecisionEvaluationReportList {
    DecisionEvaluationReportList(reports: reports.sorted { $0.createdAt > $1.createdAt })
  }

  public func clear() -> DecisionEvaluationReportList {
    reports = []
    save()
    return DecisionEvaluationReportList(reports: [])
  }

  public func evaluate(
    _ request: DecisionEvaluationRequest,
    execute: @Sendable (DecisionExperimentRequest) async -> DecisionExperimentRecord
  ) async throws -> DecisionEvaluationReport {
    guard !request.environments.isEmpty, request.environments.count <= 20 else {
      throw DecisionLabError.invalidRequest("評価モデルは1〜20件で指定してください。")
    }
    guard !request.cases.isEmpty, request.cases.count <= 500 else {
      throw DecisionLabError.invalidRequest("評価ケースは1〜500件で指定してください。")
    }
    for evaluationCase in request.cases {
      guard !evaluationCase.questionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw DecisionLabError.invalidRequest("評価ケースの質問IDを入力してください。")
      }
      switch evaluationCase.question.type {
      case .choice:
        guard let choice = evaluationCase.expected.choice,
          !choice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw DecisionLabError.invalidRequest("Choice評価ケースの正解ラベルを入力してください。") }
      case .score:
        guard let minimum = evaluationCase.expected.minimumScore,
          let maximum = evaluationCase.expected.maximumScore, minimum <= maximum
        else { throw DecisionLabError.invalidRequest("Score評価ケースの正解範囲を入力してください。") }
      case .noul:
        guard evaluationCase.expected.noul != nil else {
          throw DecisionLabError.invalidRequest("Noul評価ケースの期待値を入力してください。")
        }
      }
    }
    var entries: [DecisionEvaluationEntry] = []
    for environment in request.environments {
      for evaluationCase in request.cases {
        let experiment = DecisionExperimentRequest(
          provider: environment.provider, model: environment.model,
          state: evaluationCase.state,
          questions: [evaluationCase.questionID: evaluationCase.question])
        let record = await execute(experiment)
        entries.append(
          DecisionEvaluationAnalyzer.entry(
            record: record, environment: environment, evaluationCase: evaluationCase,
            policy: request.policy))
      }
    }
    let report = DecisionEvaluationReport(
      environments: request.environments, cases: request.cases,
      policy: request.policy, entries: entries)
    reports.insert(report, at: 0)
    reports = Array(reports.prefix(100))
    save()
    return report
  }

  private func save() {
    guard let storeURL else { return }
    do {
      try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(reports).write(to: storeURL, options: .atomic)
    } catch {}
  }

  private static func load(from url: URL) throws -> [DecisionEvaluationReport] {
    try JSONDecoder().decode([DecisionEvaluationReport].self, from: Data(contentsOf: url))
  }
}

private extension JSONValue {
  var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  var numberValue: Double? {
    guard case .number(let value) = self else { return nil }
    return value
  }
}
