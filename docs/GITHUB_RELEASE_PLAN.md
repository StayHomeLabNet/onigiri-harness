# GitHubソース公開計画

Onigiri HarnessをGitHubでソース公開するための計画です。Apple Developer Programへ加入していない間は、未署名macOSバイナリを一般配布しません。利用者は公開ソースをcloneしてローカルビルドします。

## 1. 公開方針を決める

- GitHubの公開先ownerとrepository名を決める
- OSSライセンスを選ぶ
- 対応macOS、Apple Silicon、Apple Intelligence、外部CLIの要件を明記する
- Issue、Pull Request、セキュリティ問題の受付方法を決める
- Codex、Antigravity、Claude Code、LM Studio、Ollamaは別製品であり、本リポジトリへ同梱しないことを明記する

## 2. Repository Readiness

- Gitリポジトリを初期化し、最初の公開commitを作る
- `.build`、`.swiftpm`、DerivedData、署名用ファイル、配布物、バックアップJSON、`.env`を追跡しない
- 実在ユーザーの会話、資料、評価結果、ローカル絶対パスを含めない
- commit前と公開直前に、作業ツリーとGit履歴の秘密情報検査を行う
- `LICENSE`、`CONTRIBUTING.md`、`SECURITY.md`、Code of Conduct、Issue／Pull Requestテンプレートを追加する

## 3. 再現可能なビルドとCI

- クリーンcheckoutから`swift test`と`zsh scripts/build-app.sh`を実行できるようにする
- CIでテスト、ビルド、コード形式、不要ファイル、秘密情報を検査する
- CIではApple Foundation Modelsやログイン済みCLIを必須にせず、実機試験と分離する
- version、build番号、tag、成果物名を一つのリリース番号へ揃える
- 成果物ごとにSHA-256 checksumを生成する

## 4. macOSローカルビルド

- Apple SiliconとmacOS 26以上を必要環境として明記する
- 公開ソースからテストとローカル用アプリを再現できるようにする
- CIの未署名artifactは再現性検証専用とし、一般配布物として案内しない
- Developer ID署名とApple公証は、Apple Developer Programへ加入した場合の任意対応として保持する

## 5. Source Release

- SemVer形式のtagを作る
- 変更点、動作環境、インストール方法、既知の制約をRelease Notesへ記載する
- GitHubがtagから生成するソースアーカイブだけを公開対象にする
- READMEからclone、テスト、ローカルビルド方法を案内する
- 問題発生時のRelease取り下げ、旧版へのロールバック、修正版公開手順を確認する

## 現在の準備状況

- Swift Packageと開発用アプリビルド: 完了
- 自動テスト: 84件合格
- ローカル署名検証: 合格
- Gitリポジトリ初期化: 完了（`main`、`origin`設定済み）
- GitHub公開先: `StayHomeLabNet/onigiri-harness`
- OSSライセンス: Apache-2.0に決定、公式LICENSEとNOTICEを配置済み
- CONTRIBUTING・SECURITY・行動規範・Issue／Pull Requestテンプレート: 作成済み
- 作業ツリーの秘密情報・個人ローカルパス検査: 合格
- Developer ID署名・Apple公証: 自動化実装済みだが、Apple Developer Programへ加入しない方針のため任意・保留
- GitHub Actions: CI workflowを整備（macOS 26／Xcode 26.6、テスト、Releaseビルド、Gitleaks、ZIP、SHA-256）
- Optional Signed Distribution workflow: 将来加入した場合だけ手動実行する
- GitHub Releases: 未実施。作成する場合はソースアーカイブのみ
- Private vulnerability reporting: Public変更後に有効化する
