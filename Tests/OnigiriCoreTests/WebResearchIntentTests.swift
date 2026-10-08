import Testing

@testable import OnigiriCore

@Test(arguments: [
  "ウェブで最新のドル円レートを調べて",
  "今日のニュースを教えて",
  "Search the web for the latest Apple news.",
  "What is the current exchange rate?",
])
func webResearchIntentDetectsExplicitAndLiveRequests(_ message: String) {
  #expect(WebResearchIntent.requiresLiveWebInformation(message))
}

@Test(arguments: [
  "この文章を英訳して",
  "昨日の回答を箇条書きにして",
  "最新という単語を検索しないで説明して",
  "Do not search the web; translate this paragraph.",
])
func webResearchIntentAvoidsTransformsAndExplicitOptOuts(_ message: String) {
  #expect(WebResearchIntent.requiresLiveWebInformation(message) == false)
}
