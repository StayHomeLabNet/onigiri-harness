# Onigiri Harnessへの貢献

IssueやPull Requestを歓迎します。変更を始める前に、既存IssueとPull Requestを確認してください。大きな機能追加や設計変更は、実装前にIssueで目的と範囲を共有してください。

## 開発環境

- Apple Silicon Mac
- macOS 26以降
- Xcode 26以降
- Swift 6.2 toolchain

Apple Foundation Models、LM Studio、Ollama、Codex、Antigravity、Claude Codeを使う実機試験は任意です。通常の単体テストは、外部モデルや外部CLIへのログインなしで完了する必要があります。

## 変更の確認

Pull Requestを作る前に次を実行してください。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/check-repository.sh
swift test --scratch-path /tmp/onigiri-tests
ONIGIRI_BUILD_CONFIGURATION=release zsh scripts/package-app.sh
shasum -a 256 -c release/*.sha256
```

変更内容に応じて、`docs/ACCEPTANCE_TEST_PLAN.md`の関連項目も確認してください。

## Pull Request

- 一つのPull Requestでは、一つの目的を扱ってください。
- 変更理由、利用者に見える挙動、確認方法を記載してください。
- UI変更には、可能なら変更後のスクリーンショットを添付してください。
- 保存形式やAPIを変更する場合は、互換性と移行方法を記載してください。
- 新しい外部依存を追加する場合は、必要性、ライセンス、通信先を記載してください。

## セキュリティと個人データ

APIキー、token、署名証明書、notarization資格情報、会話、利用者の資料、バックアップJSONをcommitしないでください。脆弱性は公開Issueへ書かず、`SECURITY.md`の手順で報告してください。

貢献されたコードは、このリポジトリに設定されたライセンス条件で提供されます。
