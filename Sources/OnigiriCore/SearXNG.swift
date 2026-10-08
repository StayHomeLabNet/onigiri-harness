import Foundation

/// Configuration for an opt-in, self-hosted SearXNG instance.
/// The app intentionally accepts loopback URLs only: this setting is for a
/// search service the user runs on the same Mac, not a public proxy.
public struct SearXNGConfiguration: Codable, Sendable, Equatable {
  public let baseURL: String

  public init(baseURL: String) {
    self.baseURL = baseURL
  }

  public func searchURL(for query: String) throws -> URL {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard var components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
      let host = components.host, Self.isLoopbackHost(host)
    else {
      throw SearXNGError.invalidLocalURL
    }
    components.query = nil
    components.fragment = nil
    guard let base = components.url else { throw SearXNGError.invalidLocalURL }
    let endpoint = base.appending(path: "search", directoryHint: .notDirectory)
    guard var request = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      throw SearXNGError.invalidLocalURL
    }
    request.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "format", value: "json"),
      URLQueryItem(name: "language", value: "auto"),
      URLQueryItem(name: "safesearch", value: "1"),
    ]
    guard let url = request.url else { throw SearXNGError.invalidLocalURL }
    return url
  }

  public static func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized == "localhost" || normalized == "127.0.0.1" || normalized == "::1"
  }
}

public enum SearXNGError: LocalizedError, Sendable, Equatable {
  case invalidLocalURL
  case invalidResponse
  case server(statusCode: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidLocalURL:
      return "SearXNGのURLは、このMac上の http://127.0.0.1:8080 のようなloopback URLを指定してください。"
    case .invalidResponse:
      return "SearXNGから検索結果を読み取れませんでした。JSON形式が有効か確認してください。"
    case .server(let statusCode):
      return "SearXNGの検索に失敗しました（HTTP \(statusCode)）。"
    }
  }
}

public struct SearXNGSearchResponse: Codable, Sendable, Equatable {
  public let results: [SearXNGSearchResult]

  public init(results: [SearXNGSearchResult]) {
    self.results = results
  }
}

public struct SearXNGSearchResult: Codable, Sendable, Equatable, Identifiable {
  public let title: String
  public let url: String
  public let content: String?
  public let engine: String?

  public var id: String { url }

  public init(title: String, url: String, content: String? = nil, engine: String? = nil) {
    self.title = title
    self.url = url
    self.content = content
    self.engine = engine
  }
}
