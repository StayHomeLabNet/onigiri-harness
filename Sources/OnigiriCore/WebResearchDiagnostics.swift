import Foundation

public enum WebResearchProvider: String, Codable, Sendable, Equatable {
  case searXNG
  case tavily

  public var displayName: String {
    switch self {
    case .searXNG: return "SearXNG"
    case .tavily: return "Tavily"
    }
  }
}

public struct WebResearchDiagnostic: Sendable, Equatable {
  public let provider: WebResearchProvider
  public let isSuccess: Bool
  public let summary: String
  public let detail: String

  public init(provider: WebResearchProvider, isSuccess: Bool, summary: String, detail: String) {
    self.provider = provider
    self.isSuccess = isSuccess
    self.summary = summary
    self.detail = detail
  }
}

public enum WebResearchDiagnosticAdvisor {
  public static func success(
    provider: WebResearchProvider, resultCount: Int, elapsedMilliseconds: Int
  ) -> WebResearchDiagnostic {
    WebResearchDiagnostic(
      provider: provider, isSuccess: true,
      summary: "接続できました。\(resultCount)件を \(elapsedMilliseconds)ms で取得しました。",
      detail: provider == .tavily
        ? "Tavily接続確認はAPIクレジットを1回使用します。"
        : "SearXNGのJSON検索が利用できます。")
  }

  public static func failure(
    provider: WebResearchProvider, statusCode: Int? = nil, isNetworkError: Bool = false
  ) -> WebResearchDiagnostic {
    if isNetworkError {
      let detail = provider == .searXNG
        ? "SearXNGが起動しているか、URLとポートが正しいか確認してください。"
        : "ネットワーク接続を確認して、もう一度実行してください。"
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "\(provider.displayName)へ接続できませんでした。",
        detail: detail)
    }

    switch (provider, statusCode) {
    case (.searXNG, 403):
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "SearXNGがJSON応答を拒否しました（HTTP 403）。",
        detail: "settings.yml の search.formats に json を追加して、SearXNGを再起動してください。")
    case (.searXNG, 404):
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "SearXNGの検索エンドポイントが見つかりません（HTTP 404）。",
        detail: "SearXNG URLのパスとポートを確認してください。")
    case (.tavily, 401):
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "Tavily API keyを確認できませんでした（HTTP 401）。",
        detail: "API keyをKeychainへ保存し直してから、もう一度確認してください。")
    case (.tavily, 429):
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "Tavilyのリクエスト上限に達しました（HTTP 429）。",
        detail: "少し待ってから再試行してください。")
    case (.tavily, 432), (.tavily, 433):
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false, summary: "Tavilyの利用上限に達しました（HTTP \(statusCode!)）。",
        detail: "Tavilyのダッシュボードで今月のAPIクレジットまたは利用上限を確認してください。")
    default:
      let suffix = statusCode.map { "（HTTP \($0)）" } ?? ""
      return WebResearchDiagnostic(
        provider: provider, isSuccess: false,
        summary: "\(provider.displayName)の接続確認に失敗しました\(suffix)。",
        detail: "設定を確認して、もう一度実行してください。")
    }
  }
}
