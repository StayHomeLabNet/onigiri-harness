import Foundation

public enum TavilyError: LocalizedError, Sendable, Equatable {
  case missingAPIKey
  case invalidResponse
  case server(statusCode: Int)

  public var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Tavily API keyをKeychainへ保存してから検索してください。"
    case .invalidResponse:
      return "Tavilyから検索結果を読み取れませんでした。"
    case .server(let statusCode):
      return "Tavilyの検索に失敗しました（HTTP \(statusCode)）。"
    }
  }
}

public struct TavilySearchRequest: Codable, Sendable, Equatable {
  public let query: String
  public let searchDepth: String
  public let maxResults: Int
  public let includeAnswer: Bool
  public let includeRawContent: Bool
  public let includeImages: Bool
  public let topic: String
  public let safeSearch: Bool

  public init(
    query: String, searchDepth: String = "basic", maxResults: Int = 8,
    includeAnswer: Bool = false, includeRawContent: Bool = false, includeImages: Bool = false,
    topic: String = "general", safeSearch: Bool = true
  ) {
    self.query = query
    self.searchDepth = searchDepth
    self.maxResults = max(1, min(maxResults, 20))
    self.includeAnswer = includeAnswer
    self.includeRawContent = includeRawContent
    self.includeImages = includeImages
    self.topic = topic
    self.safeSearch = safeSearch
  }

  enum CodingKeys: String, CodingKey {
    case query
    case searchDepth = "search_depth"
    case maxResults = "max_results"
    case includeAnswer = "include_answer"
    case includeRawContent = "include_raw_content"
    case includeImages = "include_images"
    case topic
    case safeSearch = "safe_search"
  }
}

public struct TavilySearchResponse: Codable, Sendable, Equatable {
  public let results: [TavilySearchResult]

  public init(results: [TavilySearchResult]) {
    self.results = results
  }
}

public struct TavilySearchResult: Codable, Sendable, Equatable, Identifiable {
  public let title: String
  public let url: String
  public let content: String?

  public var id: String { url }

  public init(title: String, url: String, content: String? = nil) {
    self.title = title
    self.url = url
    self.content = content
  }
}

public enum TavilySearchAPI {
  public static let endpoint = URL(string: "https://api.tavily.com/search")!

  public static func makeRequest(query: String, apiKey: String) throws -> URLRequest {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { throw TavilyError.missingAPIKey }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(TavilySearchRequest(query: query))
    return request
  }
}
