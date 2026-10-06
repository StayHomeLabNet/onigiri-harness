import Foundation
import OnigiriCore

private enum MCPFailure: LocalizedError {
  case invalidArguments(String)
  case server(String)

  var errorDescription: String? {
    switch self {
    case .invalidArguments(let detail), .server(let detail): return detail
    }
  }
}

private struct OnigiriMCPServer {
  let baseURL: URL

  init() {
    let configured = ProcessInfo.processInfo.environment["ONIGIRI_SERVER_BASE_URL"]
    baseURL = URL(string: configured ?? "http://127.0.0.1:18080")!
  }

  func handle(_ message: [String: Any]) async -> [String: Any]? {
    guard let method = message["method"] as? String else {
      return errorResponse(id: message["id"], code: -32600, message: "Invalid Request")
    }
    let id = message["id"]
    if id == nil { return nil }

    switch method {
    case "initialize":
      let params = message["params"] as? [String: Any]
      let requestedVersion = params?["protocolVersion"] as? String
      return response(
        id: id,
        result: [
          "protocolVersion": requestedVersion ?? "2025-06-18",
          "capabilities": ["tools": ["listChanged": false]],
          "serverInfo": ["name": "onigiri-rag", "version": "1.0.0"],
          "instructions":
            "Search the user's local Onigiri knowledge with searchKnowledge, then fetch a complete chunk with getKnowledgeChunk when more context is needed. Both tools are read-only.",
        ])
    case "ping":
      return response(id: id, result: [:])
    case "tools/list":
      return response(id: id, result: ["tools": Self.tools])
    case "tools/call":
      return await callTool(id: id, params: message["params"] as? [String: Any])
    default:
      return errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
    }
  }

  private func callTool(id: Any?, params: [String: Any]?) async -> [String: Any] {
    guard let name = params?["name"] as? String else {
      return errorResponse(id: id, code: -32602, message: "Tool name is required")
    }
    let arguments = params?["arguments"] as? [String: Any] ?? [:]
    do {
      let resultData: Data
      switch name {
      case KnowledgeToolName.searchKnowledge.rawValue:
        guard let query = arguments["query"] as? String,
          !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw MCPFailure.invalidArguments("query is required") }
        let settings = KnowledgeSearchSettings(
          limit: arguments["limit"] as? Int ?? 5,
          minScore: arguments["minScore"] as? Int ?? 1,
          keywordWeight: arguments["keywordWeight"] as? Double ?? 1,
          embeddingWeight: arguments["embeddingWeight"] as? Double ?? 1)
        resultData = try await post(
          path: "tools/searchKnowledge",
          body: SearchKnowledgeToolRequest(query: query, settings: settings))
      case KnowledgeToolName.getKnowledgeChunk.rawValue:
        guard let chunkID = arguments["chunkID"] as? String, !chunkID.isEmpty else {
          throw MCPFailure.invalidArguments("chunkID is required")
        }
        resultData = try await post(
          path: "tools/getKnowledgeChunk", body: GetKnowledgeChunkToolRequest(chunkID: chunkID))
      default:
        throw MCPFailure.invalidArguments("Unknown tool: \(name)")
      }
      let object = try JSONSerialization.jsonObject(with: resultData)
      let text = String(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}"
      return response(
        id: id,
        result: [
          "content": [["type": "text", "text": text]],
          "structuredContent": object,
          "isError": false,
        ])
    } catch {
      return response(
        id: id,
        result: [
          "content": [["type": "text", "text": error.localizedDescription]],
          "isError": true,
        ])
    }
  }

  private func post<T: Encodable>(path: String, body: T) async throws -> Data {
    var request = URLRequest(url: baseURL.appending(path: path))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("mcp", forHTTPHeaderField: "X-Onigiri-Tool-Source")
    request.httpBody = try JSONEncoder().encode(body)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      let detail = (try? JSONDecoder().decode(APIError.self, from: data))?.error
      throw MCPFailure.server(detail ?? "OnigiriServer returned an error")
    }
    return data
  }

  private func response(id: Any?, result: Any) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
  }

  private func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
    [
      "jsonrpc": "2.0", "id": id ?? NSNull(),
      "error": ["code": code, "message": message],
    ]
  }

  private static let tools: [[String: Any]] = [
    [
      "name": KnowledgeToolName.searchKnowledge.rawValue,
      "title": "Search Onigiri knowledge",
      "description":
        "Search the user's indexed local Onigiri documents and return ranked chunks with stable IDs, titles, citation indexes, scores, and text.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "query": ["type": "string", "description": "Words or question to search for"],
          "limit": ["type": "integer", "minimum": 1, "maximum": 20],
          "minScore": ["type": "integer", "minimum": 1, "maximum": 100],
          "keywordWeight": ["type": "number", "minimum": 0, "maximum": 3],
          "embeddingWeight": ["type": "number", "minimum": 0, "maximum": 3],
        ],
        "required": ["query"],
        "additionalProperties": false,
      ],
      "annotations": [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
        "openWorldHint": false,
      ],
    ],
    [
      "name": KnowledgeToolName.getKnowledgeChunk.rawValue,
      "title": "Get an Onigiri knowledge chunk",
      "description":
        "Fetch one complete local knowledge chunk by the stable chunk ID returned from searchKnowledge.",
      "inputSchema": [
        "type": "object",
        "properties": [
          "chunkID": ["type": "string", "description": "Stable Onigiri chunk ID"]
        ],
        "required": ["chunkID"],
        "additionalProperties": false,
      ],
      "annotations": [
        "readOnlyHint": true, "destructiveHint": false, "idempotentHint": true,
        "openWorldHint": false,
      ],
    ],
  ]
}

@main
private struct OnigiriMCPMain {
  static func main() async {
    let server = OnigiriMCPServer()
    while let line = readLine(strippingNewline: true) {
      guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let data = line.data(using: .utf8),
        let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { continue }
      if let reply = await server.handle(message),
        let output = try? JSONSerialization.data(withJSONObject: reply)
      {
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data([0x0A]))
      }
    }
  }
}
