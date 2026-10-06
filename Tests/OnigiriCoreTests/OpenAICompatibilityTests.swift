import Foundation
import Testing

@testable import OnigiriCore

@Test func compatibilityRequestExtractsSystemHistoryAndLatestUserMessage() throws {
  let request = OpenAIChatCompletionsRequest(
    model: "onigiri/current",
    messages: [
      OpenAICompatibleMessage(role: .system, content: "Answer briefly."),
      OpenAICompatibleMessage(role: .user, content: "My code is 42."),
      OpenAICompatibleMessage(role: .assistant, content: "Understood."),
      OpenAICompatibleMessage(role: .user, content: "What is my code?"),
    ])

  let conversation = try request.conversation()

  #expect(conversation.prompt == "What is my code?")
  #expect(conversation.systemInstructions == "Answer briefly.")
  #expect(conversation.history == [
    ChatHistoryMessage(role: .user, content: "My code is 42."),
    ChatHistoryMessage(role: .assistant, content: "Understood."),
  ])
}

@Test func compatibilityRequestRequiresUserMessage() {
  let request = OpenAIChatCompletionsRequest(
    model: "onigiri/current",
    messages: [OpenAICompatibleMessage(role: .system, content: "Only system")])
  #expect(throws: OpenAICompatibilityError.self) { try request.conversation() }
}

@Test func compatibilityResponseUsesOpenAIKeysAndOnigiriMetadata() throws {
  let response = OpenAIChatCompletionResponse(
    id: "chatcmpl-test", created: 1_000, model: "onigiri/current", content: "Hello",
    metadata: OpenAICompatibilityMetadata(ragMode: .disabled, matches: [], ragTrace: nil))
  let data = try JSONEncoder().encode(response)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let choices = try #require(object["choices"] as? [[String: Any]])

  #expect(object["object"] as? String == "chat.completion")
  #expect((choices.first?["finish_reason"] as? String) == "stop")
  #expect((object["onigiri"] as? [String: Any])?["rag_mode"] as? String == "disabled")
}

@Test func compatibilityProfileCatalogReloadsAndResolvesNameOrID() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appending(path: "onigiri-compatibility-profiles-\(UUID().uuidString)")
  let storeURL = directory.appending(path: "profiles.json")
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let profileID = UUID()
  let json = """
    {
      "formatVersion": 1,
      "defaultProfileID": "\(profileID.uuidString)",
      "profiles": [{
        "id": "\(profileID.uuidString)",
        "name": "qwen-local",
        "providerID": "ollama",
        "baseURL": "http://127.0.0.1:11434/v1",
        "modelID": "qwen3",
        "systemInstructions": "Answer briefly.",
        "ragMode": "agentic",
        "searchSettings": {
          "limit": 5, "minScore": 1, "keywordWeight": 1,
          "embeddingWeight": 1, "titleWeight": 6, "exactPhraseBonus": 12
        },
        "contextLimit": 8000
      }]
    }
    """
  try Data(json.utf8).write(to: storeURL)
  let catalog = CompatibilityProfileCatalog(storeURL: storeURL)

  let byID = try await catalog.resolve(id: profileID, name: nil)
  let byName = try await catalog.resolve(id: nil, name: "QWEN-LOCAL")
  #expect(byID?.modelID == "qwen3")
  #expect(byName?.id == profileID)
  #expect(byName?.runtime.ragMode == .agentic)
}
