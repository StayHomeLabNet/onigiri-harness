import Foundation
import Testing

@testable import OnigiriCore

@Test func searXNGBuildsLoopbackJSONSearchURL() throws {
  let configuration = SearXNGConfiguration(baseURL: "http://127.0.0.1:8080/searx")
  let url = try configuration.searchURL(for: "今日のドル円")
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

  #expect(url.path == "/searx/search")
  #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "今日のドル円")
  #expect(components.queryItems?.first(where: { $0.name == "format" })?.value == "json")
  #expect(components.queryItems?.first(where: { $0.name == "safesearch" })?.value == "1")
}

@Test func searXNGRejectsNonLocalURL() {
  let configuration = SearXNGConfiguration(baseURL: "https://search.example.com")
  #expect(throws: SearXNGError.invalidLocalURL) {
    try configuration.searchURL(for: "test")
  }
}

@Test func searXNGIncludesLanguageAndTimeRefinements() throws {
  let configuration = SearXNGConfiguration(baseURL: "http://127.0.0.1:8080")
  let refinement = WebSearchRefinement(maxResults: 6, language: "ja", timeRange: "week")
  let url = try configuration.searchURL(for: "経済ニュース", refinement: refinement)
  let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

  #expect(components.queryItems?.first(where: { $0.name == "language" })?.value == "ja")
  #expect(components.queryItems?.first(where: { $0.name == "time_range" })?.value == "week")
}

@Test func searXNGDecodesStandardResults() throws {
  let data = Data("""
    {"results":[{"title":"Example","url":"https://example.com","content":"Snippet","engine":"brave"}]}
    """.utf8)
  let response = try JSONDecoder().decode(SearXNGSearchResponse.self, from: data)

  #expect(response.results == [
    SearXNGSearchResult(
      title: "Example", url: "https://example.com", content: "Snippet", engine: "brave")
  ])
}
