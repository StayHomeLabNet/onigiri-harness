# Security Policy

## Supported versions

正式Release後は、最新のminor releaseだけへセキュリティ修正を提供します。正式Release前は`main`ブランチの最新版を対象にします。

## Reporting a vulnerability

脆弱性、秘密情報の露出、認証回避、任意コード実行、意図しない外部通信を見つけた場合は、公開Issueへ詳細を書かないでください。[GitHubのPrivate vulnerability reporting](https://github.com/StayHomeLabNet/onigiri-harness/security/advisories/new)から非公開で報告してください。

報告には次を含めてください。

- 影響を受けるversionまたはcommit
- 再現手順と期待される挙動
- 想定される影響
- 分かる範囲の回避策

受領後7日以内の初回応答を目標とします。修正版を公開するまでは、再現用の資料、ログ、資格情報を公開しないでください。

## Scope

Onigiri Harness本体と同梱するServer、MCP、保存・移行処理が対象です。LM Studio、Ollama、Codex、Antigravity、Claude Code、AppleのモデルやOS自体の問題は、それぞれの提供元へ報告してください。
