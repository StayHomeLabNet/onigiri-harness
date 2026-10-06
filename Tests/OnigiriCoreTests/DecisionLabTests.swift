import Foundation
import Testing

@testable import OnigiriCore

@Test func decisionLabSeparatesPersistsAndRedactsFailedExperiments() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-decision-lab-tests-\(UUID().uuidString)")
  let storeURL = directory.appending(path: "runs.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  let manager = DecisionLabManager(storeURL: storeURL)
  let request = DecisionExperimentRequest(
    provider: DecisionProviderConfig(
      kind: .typeSafeCompatible, baseURL: "invalid base URL", apiKey: "secret-key"),
    model: "jev-test",
    state: .object(["ticket": .string("refund requested")]),
    questions: [
      "route": DecisionQuestion(
        type: .choice, instructions: .string("Choose a route"),
        criteria: .object(["refund": .string("Refund desk"), "other": .string("Other")]))
    ])

  let record = await manager.run(request)

  #expect(record.status == .failed)
  #expect(record.request.provider.apiKey == nil)
  #expect(record.request.state == .object(["ticket": .string("refund requested")]))
  #expect(await manager.list().runs.count == 1)

  let restored = DecisionLabManager(storeURL: storeURL)
  #expect(await restored.list().runs.first == record)
  #expect(await restored.clear().runs.isEmpty)
}

@Test func decisionLabRejectsInvalidTypedQuestionCriteria() async {
  let manager = DecisionLabManager(storeURL: nil)
  let request = DecisionExperimentRequest(
    provider: DecisionProviderConfig(kind: .ollaya, baseURL: "http://127.0.0.1:11435"),
    model: "laya",
    state: .string("state"),
    questions: [
      "route": DecisionQuestion(type: .choice, criteria: .array([.string("only-one")]))
    ])

  let record = await manager.run(request)
  #expect(record.status == .failed)
  #expect(record.error?.contains("選択肢") == true)
}

@Test func decisionEvaluationScoresAccuracyCalibrationAndFallback() {
  let environment = DecisionEvaluationEnvironment(
    name: "Laya", provider: DecisionProviderConfig(kind: .ollaya, baseURL: "http://localhost:11435"),
    model: "laya")
  let evaluationCase = DecisionEvaluationCase(
    name: "Approve", state: .string("safe request"), questionID: "route",
    question: DecisionQuestion(
      type: .choice, criteria: .object(["approve": .string("Approve"), "reject": .string("Reject")])),
    expected: DecisionExpectedAnswer(choice: "approve"))
  let record = DecisionExperimentRecord(
    request: DecisionExperimentRequest(
      provider: environment.provider, model: environment.model, state: evaluationCase.state,
      questions: [evaluationCase.questionID: evaluationCase.question]),
    status: .completed,
    response: .object(["answers": .object(["route": .object([
      "choice": .string("approve"), "confidence": .number(0.62)
    ])])]), durationMilliseconds: 40)
  let policy = DecisionRoutingPolicy(defaultThreshold: 0.7, defaultFallback: .languageModel)

  let entry = DecisionEvaluationAnalyzer.entry(
    record: record, environment: environment, evaluationCase: evaluationCase, policy: policy)

  #expect(entry.correct == true)
  #expect(entry.confidence == 0.62)
  #expect(abs((entry.calibrationError ?? 0) - 0.38) < 0.0001)
  #expect(entry.escalated)
  #expect(entry.simulatedFallback == .languageModel)
}

@Test func decisionRoutingPolicyUsesMostSpecificOverride() {
  let policy = DecisionRoutingPolicy(
    defaultThreshold: 0.5, defaultFallback: .none,
    overrides: [
      DecisionThresholdOverride(model: "laya", threshold: 0.6, fallback: .languageModel),
      DecisionThresholdOverride(questionID: "route", threshold: 0.7, fallback: .human),
      DecisionThresholdOverride(model: "laya", questionID: "route", threshold: 0.9, fallback: .human),
    ])

  let exact = policy.rule(model: "laya", questionID: "route")
  let modelOnly = policy.rule(model: "laya", questionID: "other")
  #expect(exact.threshold == 0.9)
  #expect(exact.fallback == .human)
  #expect(modelOnly.threshold == 0.6)
  #expect(modelOnly.fallback == .languageModel)
}

@Test func decisionEvaluationPersistsReportsAndRedactsCredentials() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-decision-evaluation-tests-\(UUID().uuidString)")
  let storeURL = directory.appending(path: "reports.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  let manager = DecisionEvaluationManager(storeURL: storeURL)
  let environment = DecisionEvaluationEnvironment(
    name: "Test", provider: DecisionProviderConfig(
      kind: .typeSafeCompatible, baseURL: "http://localhost:8080", apiKey: "secret"),
    model: "decision-test")
  let evaluationCase = DecisionEvaluationCase(
    name: "Boolean", state: .string("is valid"), questionID: "valid",
    question: DecisionQuestion(type: .noul), expected: DecisionExpectedAnswer(noul: true))
  let request = DecisionEvaluationRequest(
    environments: [environment], cases: [evaluationCase],
    policy: DecisionRoutingPolicy(defaultThreshold: 0.8, defaultFallback: .human))

  let report = try await manager.evaluate(request) { experiment in
    DecisionExperimentRecord(
      request: experiment, status: .completed,
      response: .object(["answers": .object(["valid": .object(["noul": .number(0.95)])])]),
      durationMilliseconds: 20)
  }

  #expect(report.environments.first?.provider.apiKey == nil)
  #expect(report.summaries.first?.accuracy == 1)
  #expect(report.summaries.first?.completedCount == 1)
  #expect(report.summaries.first?.escalationRate == 0)
  let restored = DecisionEvaluationManager(storeURL: storeURL)
  #expect(await restored.list().reports.first?.id == report.id)
  #expect(await restored.clear().reports.isEmpty)
}

@Test func decisionEvaluationRejectsMissingExpectedAnswer() async {
  let manager = DecisionEvaluationManager(storeURL: nil)
  let environment = DecisionEvaluationEnvironment(
    name: "Test", provider: DecisionProviderConfig(kind: .ollaya, baseURL: "http://localhost:11435"),
    model: "laya")
  let evaluationCase = DecisionEvaluationCase(
    name: "Missing", state: .string("state"), questionID: "route",
    question: DecisionQuestion(type: .choice), expected: DecisionExpectedAnswer())
  do {
    _ = try await manager.evaluate(DecisionEvaluationRequest(
      environments: [environment], cases: [evaluationCase], policy: DecisionRoutingPolicy()
    )) { request in
      DecisionExperimentRecord(request: request, status: .failed, durationMilliseconds: 0)
    }
    Issue.record("Expected invalid request")
  } catch {
    #expect(error.localizedDescription.contains("正解ラベル"))
  }
}
