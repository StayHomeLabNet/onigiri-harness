import Foundation

/// Conservative client-side trigger for an opt-in Web research provider.
/// It only detects an explicit request to search the Web or common requests
/// for information that changes over time; the selected provider remains off
/// unless the user enables it in the app.
public enum WebResearchIntent {
  public static func requiresLiveWebInformation(_ message: String) -> Bool {
    let normalized = message
      .lowercased()
      .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return false }

    let optOut = ["検索しない", "調べない", "webを使わない", "ウェブを使わない", "don't search", "do not search"]
    guard !optOut.contains(where: { normalized.contains($0) }) else { return false }

    let explicit = [
      "web検索", "ウェブ検索", "ネット検索", "インターネットで検索", "webで検索", "ウェブで検索",
      "webで調べ", "ウェブで調べ", "ネットで調べ", "ウェブから", "webから", "オンラインで調べ",
      "search the web", "web search", "look up online", "search online", "find online",
    ]
    if explicit.contains(where: { normalized.contains($0) }) { return true }

    let currentInformation = [
      "最新", "現在の", "今の", "今日の", "ニュース", "速報", "為替", "ドル円", "株価", "天気",
      "latest", "current", "today's", "news", "exchange rate", "stock price", "weather",
    ]
    return currentInformation.contains(where: { normalized.contains($0) })
  }
}
