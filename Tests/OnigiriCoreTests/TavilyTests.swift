import Foundation
import Testing

@testable import OnigiriCore

@Test func tavilyBuildsAuthenticatedBasicSearchRequest() throws {
  let request = try TavilySearchAPI.makeRequest(query: "最新ニュース", apiKey: "tvly-test-key")
  let body = try #require(request.httpBody)
  let payload = try JSONDecoder().decode(TavilySearchRequest.self, from: body)

  #expect(request.url == TavilySearchAPI.endpoint)
  #expect(request.httpMethod == "POST")
  #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tvly-test-key")
  #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
  #expect(payload.query == "最新ニュース")
  #expect(payload.searchDepth == "basic")
  #expect(payload.maxResults == 8)
  #expect(payload.includeRawContent == false)
}

@Test func tavilyRejectsMissingAPIKey() {
  #expect(throws: TavilyError.missingAPIKey) {
    try TavilySearchAPI.makeRequest(query: "test", apiKey: "  ")
  }
}

@Test func tavilyIncludesSearchRefinements() throws {
  let refinement = WebSearchRefinement(
    maxResults: 6, language: "ja", timeRange: "week", includedDomains: ["https://example.com/path"])
  let request = try TavilySearchAPI.makeRequest(
    query: "経済ニュース", apiKey: "tvly-test-key", refinement: refinement)
  let body = try #require(request.httpBody)
  let payload = try JSONDecoder().decode(TavilySearchRequest.self, from: body)

  #expect(payload.maxResults == 6)
  #expect(payload.language == "ja")
  #expect(payload.filterByLanguage)
  #expect(payload.timeRange == "week")
  #expect(payload.includeDomains == ["example.com"])
}

@Test func tavilyDecodesSearchResults() throws {
  let data = Data("""
    {"results":[{"title":"Example","url":"https://example.com","content":"Snippet","score":0.9}]}
    """.utf8)
  let response = try JSONDecoder().decode(TavilySearchResponse.self, from: data)

  #expect(response.results == [
    TavilySearchResult(title: "Example", url: "https://example.com", content: "Snippet")
  ])
}
