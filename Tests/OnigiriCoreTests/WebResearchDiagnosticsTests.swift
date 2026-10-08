import Testing

@testable import OnigiriCore

@Test func searXNGJSONFormatFailureExplainsRequiredSetting() {
  let diagnostic = WebResearchDiagnosticAdvisor.failure(provider: .searXNG, statusCode: 403)

  #expect(diagnostic.isSuccess == false)
  #expect(diagnostic.summary.contains("HTTP 403"))
  #expect(diagnostic.detail.contains("search.formats"))
  #expect(diagnostic.detail.contains("json"))
}

@Test func tavilyFailuresDistinguishAuthenticationAndQuota() {
  let authentication = WebResearchDiagnosticAdvisor.failure(provider: .tavily, statusCode: 401)
  let quota = WebResearchDiagnosticAdvisor.failure(provider: .tavily, statusCode: 432)

  #expect(authentication.detail.contains("Keychain"))
  #expect(quota.summary.contains("利用上限"))
  #expect(quota.detail.contains("APIクレジット"))
}

@Test func successfulDiagnosticReportsResultCountAndLatency() {
  let diagnostic = WebResearchDiagnosticAdvisor.success(
    provider: .tavily, resultCount: 4, elapsedMilliseconds: 123)

  #expect(diagnostic.isSuccess)
  #expect(diagnostic.summary.contains("4件"))
  #expect(diagnostic.summary.contains("123ms"))
  #expect(diagnostic.detail.contains("APIクレジット"))
}
