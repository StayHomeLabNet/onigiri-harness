# GitHub公開・配布計画

Onigiri HarnessをGitHubでソース公開し、GitHub ReleasesからmacOSアプリを配布するための準備項目です。リポジトリの公開やReleaseの作成は、以下を満たした後に行います。

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

## 4. macOS配布物

- Release構成でUniversalまたはApple Silicon向けアプリを作る
- Developer ID Applicationで署名し、Hardened Runtimeを有効にする
- Appleへ公証し、ticketをstapleする
- DMGまたはZIPを作り、Gatekeeper検証を行う
- 別Macでダウンロード、初回起動、モデル接続、会話、RAGを確認する

## 5. GitHub Release

- SemVer形式のtagを作る
- 変更点、動作環境、インストール方法、既知の制約をRelease Notesへ記載する
- 署名・公証済みアプリ、checksum、必要に応じてSBOMを添付する
- 公開後にREADMEのダウンロード先と検証方法を更新する
- 問題発生時のRelease取り下げ、旧版へのロールバック、修正版公開手順を確認する

## 現在の準備状況

- Swift Packageと開発用アプリビルド: 完了
- 自動テスト: 84件合格
- ローカル署名検証: 合格
- Gitリポジトリ初期化: 完了（`main`、remote未設定、初回commit前）
- GitHub公開先: `StayHomeLabNet/onigiri-harness`のPrivateリポジトリに決定
- OSSライセンス: Apache-2.0に決定、公式LICENSEとNOTICEを配置済み
- CONTRIBUTING・SECURITY・行動規範・Issue／Pull Requestテンプレート: 作成済み
- 作業ツリーの秘密情報・個人ローカルパス検査: 合格
- Developer ID署名・Apple公証: 未実施
- GitHub Actions・GitHub Releases: 未実施
