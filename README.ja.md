# 🍙 Onigiri Harness

## Apple Foundation Models、GGUFローカルモデル管理、ハイブリッドRAG、Decision Lab、AI CLI統合を備えたmacOSネイティブのローカルAIハーネス

**Onigiri Harness は、Apple Intelligence（オンデバイスモデル）、llama.cppによるローカルGGUFモデル管理、根拠引用付きハイブリッドRAG、意思決定モデル検証（Decision Lab）、および外部AIエージェントCLI連携を備えたmacOSネイティブのローカルAI実行環境・デスクトップアプリです。**

[English](README.md) | [日本語](README.ja.md)

[概要](#概要) ・ [主な機能](#主な機能) ・ [動作環境](#動作環境) ・ [アーキテクチャ](#アーキテクチャ) ・ [クイックスタート](#クイックスタート) ・ [ローカルモデル管理](#onigiri管理のローカルモデルgguf) ・ [AIタスク・CLI連携](#aiタスクとcli連携) ・ [APIと検証](#apiと検証) ・ [プロジェクト構成](#プロジェクト構成) ・ [ライセンス](#ライセンス)

![version](https://img.shields.io/badge/version-0.7.0-blue)
[![License](https://img.shields.io/badge/license-Apache--2.0-green)](LICENSE)
![platform](https://img.shields.io/badge/platform-macOS%20(Apple%20Silicon)-orange)
![app](https://img.shields.io/badge/app-SwiftUI%20%2F%20Swift-purple)
![models](https://img.shields.io/badge/models-Apple%20Intelligence%20%7C%20GGUF%20%7C%20OpenAI-brightgreen)
[![CI](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml/badge.svg)](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml)

[![Ko-fi](https://img.shields.io/badge/Ko--fi-Support%20StayHomeLabNet-ff5e5b?style=for-the-badge&logo=kofi&logoColor=white)](https://ko-fi.com/stayhomelabnet)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-Support%20StayHomeLabNet-ffdd00?style=for-the-badge&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/stayhomelabnet)

**Onigiri Harness が役に立った場合は、プロジェクトの支援をご検討ください。**

---

## 概要

Onigiri Harness は、macOS 上でローカル AI をフル活用するための統合ハーネス（実行基盤・クライアント）です。
プライバシーを最優先にしたオンデバイスの Apple Intelligence（Apple Foundation Models）をはじめ、`llama.cpp` による GGUF モデルの直接ダウンロードと実行、LM Studio や Ollama などの外部サーバー連携、そして Codex CLI・Google Antigravity CLI・Claude Code といった自律型コーディングエージェント CLI のチャット・タスク連携までをひとつのデスクトップアプリからシームレスに扱えます。

ローカル資料を取り込んだ高精度なハイブリッド RAG（全文検索 + Embedding）や、AIが自律的に検索要否を判断する Agentic RAG、意思決定モデルの検証環境（Decision Model Lab）、OpenAI 互換のローカル Gateway、さらに stdio MCP Server まで内蔵しています。外部パッケージ依存を持たない純粋な Swift 実装です。

現在のバージョン: `v0.7.0`

## アーキテクチャ

Onigiri Harness は、UIレイヤー（SwiftUI）、独立プロセスのサーバーレイヤー（Network.framework）、および中核ロジック（OnigiriCore）で構成されています。

```text
OnigiriApp (SwiftUI / macOS ネイティブ)
    │
    ▼ HTTP / 127.0.0.1:18080 (loopback)
OnigiriServer (別プロセス / Network.framework / OpenAI互換 Gateway)
    │
    ├── OnigiriCore
    │     ├── Harness (プロバイダー管理・セッション制御)
    │     ├── RAGManager (資料チャンク分割・hybrid検索・Agentic判断)
    │     ├── CodexAgentManager (Codex / Antigravity / Claude Code CLI実行)
    │     ├── ManagedLocalModels (Hugging Face GGUF取得 / llama-server制御)
    │     ├── DecisionEvaluation (Decision Model Lab / Ollaya連携)
    │     └── DataProtection (暗号化・Keychain・チェックサム付きバックアップ)
    │
    └── ModelProvider / ModelConversationSession
          ├── AppleFoundationModelsProvider (オンデバイス Apple Intelligence)
          ├── ManagedLocalGGUFProvider (llama-server / 127.0.0.1:18181)
          ├── LocalOpenAICompatibleProvider (LM Studio / Ollama)
          └── CLIChatModelProvider (Codex / Antigravity / Claude Code CLI)
```

## 主な機能

- **マルチプロバイダー対応**
  - **Apple Foundation Models**: macOS 標準のオンデバイス基盤モデルを直接利用（完全オフライン・プライベート）。
  - **Onigiri Local (GGUF)**: Hugging Face から直接 GGUF モデルをダウンロードし、`llama-server` 経由で実行・管理。
  - **OpenAI 互換サーバー**: LM Studio や Ollama などのローカル推論サーバーとワンクリック接続。
  - **CLI チャット**: インストール済みの Codex CLI、Google Antigravity CLI（`agy`）、Claude Code を安全な読み取り専用通常チャットプロバイダーとして利用可能。
- **高精度ハイブリッド RAG & Agentic RAG**
  - テキスト、Markdown、PDF資料やフォルダをドラッグ＆ドロップで追加。
  - チャンク overlap、タイトル重み付け、完全一致ボーナス、日本語 2/3-gram、および `/v1/embeddings` による Embedding 類似度を組み合わせたハイブリッド検索。
  - 回答本文中に引用番号（例: `[1]`）を埋め込み、ワンクリックで該当チャンク詳細を確認可能。
  - **Agentic RAG**: AIが回答前に検索要否と検索語をJSONで自律判断。検索結果が不十分な場合は別クエリで自動再検索を実行。
- **Webリサーチ連携**
  - 内蔵ブラウザまたは独立ウインドウでWebページを閲覧・選択し、そのターンの質問だけの参考資料として安全に注入。
  - ローカル SearXNG とのダイレクト連携、および Tavily 検索 API による自動 Web 検索に対応。
- **自律型 AI タスク & CLI 連携**
  - Codex、Google Antigravity、Claude Code にバックグラウンドで非同期タスクを発行。
  - `read-only`（読み取り専用）または `workspace-write`（作業フォルダ書き込み）のサンドボックス保護。
  - 複数タスクの並行実行、ストリーミングログ確認、タイムアウト・キャンセル対応。
- **Decision Model Lab**
  - 意思決定・分類に特化したモデル（Ollaya / TypeSafe / Jev互換）の実行とベンチマーク。
  - 正解付きケースを用いた多モデル比較評価（Accuracy、Calibration Error、遅延、フォールバック率の集計）。
- **OpenAI 互換 Gateway & MCP サーバー**
  - ローカル `http://127.0.0.1:18080/v1` で OpenAI 互換の Chat Completions API（Streaming / SSE）を提供。
  - stdio MCP Server（`onigiri-mcp`）を同梱し、Claude Code や Codex などの MCP クライアントから Onigiri の RAG 知識を呼び出し可能。
- **評価システム & 回帰テスト (`onigiri-eval`)**
  - モデルマトリクス評価、名前付きスイート管理、日次定期自動実行、回帰アラート。
  - CI やヘッドレス環境で回帰を検知する `onigiri-eval` CLI ツール。
- **安全なデータ管理**
  - 会話、Profile、資料、評価、AIタスク履歴のチェックサム付き JSON バックアップ・復元。
  - 復元前の安全自動ロールバックコピー作成。外部 API キーは平文保存せず macOS Keychain で保護。

## 動作環境

- **Mac**: Apple Silicon Mac（M1以降）
- **OS**: macOS 26 以上
- **Xcode**: Xcode 26 以上（初回起動時のコンポーネントセットアップを完了していること）
- **Apple Intelligence**: 有効化され、オンデバイスモデルのダウンロードが完了していること（Apple Foundation Models 利用時）
- **任意の追加環境**:
  - `llama.cpp`（`llama-server`）: ローカル GGUF モデル実行用（Homebrew で導入可能）
  - 各 CLI（Codex CLI、Google Antigravity CLI `agy`、Claude Code）: AIタスクやCLIチャット利用時に必要

## クイックスタート

### 1. リポジトリのクローンとサーバー起動

ターミナルを開き、OnigiriServer を起動します。

```sh
git clone https://github.com/StayHomeLabNet/onigiri-harness.git
cd onigiri-harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

### 2. アプリのビルドと起動

別のターミナルウインドウでクライアントアプリをビルドして起動します。

```sh
cd onigiri-harness
zsh scripts/build-app.sh
open /tmp/onigiri-harness-build/Onigiri.app
```

> [!NOTE]
> **初回起動時のGatekeeper解除**
> 未署名のローカルビルドアプリは macOS のセキュリティ機能によってブロックされる場合があります。その場合はターミナルで以下を実行してください。
> ```sh
> xattr -cr /tmp/onigiri-harness-build/Onigiri.app
> ```

### 3. 基本的な使い方

- **チャット**: メイン画面で「こんにちは」と入力して送信します。返答はストリーミングで表示されます。
- **改行と送信**: 通常の `Enter` で送信、`Shift + Enter` で改行します。日本語 IME の変換確定中の `Enter` では誤送信されません。
- **資料の追加 (RAG)**: 「資料/フォルダを追加」ボタンからテキストファイル、Markdown、PDF、またはフォルダを選択します。次回以降の質問で関連チャンクが自動検索され、回答に `[1]` などの引用リンクが付きます。
- **言語の切り替え**: メニューバーの「Onigiri Harness」→「設定…」から表示言語を日本語または英語へ瞬時に切り替えられます。

## Onigiri管理のローカルモデル（GGUF）

メニューの「設定…」→「ローカルモデル」から、Hugging Face 上の公開 GGUF モデルを Onigiri の管理ストレージ（`Application Support/OnigiriHarness/local-models/models`）へ直接ダウンロードできます。

1. **実行エンジンの準備**:
   推論には `llama.cpp` の `llama-server` を使用します。設定画面の「Homebrewで自動インストール」を押すか、ターミナルでインストールします。
   ```sh
   brew install llama.cpp
   # Apple Siliconの標準パス: /opt/homebrew/bin/llama-server
   ```
2. **モデルのロード**:
   カタログからモデルを選んでダウンロード完了後、「ロードして利用」をクリックすると、専用の loopback ポート（`127.0.0.1:18181`）で `llama-server` が立ち上がり、チャットプロバイダーが自動的に切り替わります。
3. **受入テスト（ベンチマーク）と推奨**:
   ロードしたモデルに対して日英の受入テストを一括実行し、成功率、応答時間、消費メモリ（RSS）を計測・記録できます。複数モデルの結果から、お使いの Mac のメモリ容量に応じた最適モデルが自動推薦されます。

## 外部プロバイダー＆CLIチャット

### LM Studio / Ollama の利用
- **LM Studio**: LM Studio の Local Server を起動後、アプリのプロバイダー設定で `LM Studio`（Base URL: `http://127.0.0.1:1234/v1`）を選択します。
- **Ollama**: `ollama serve` を起動後、アプリで `Ollama`（Base URL: `http://127.0.0.1:11434/v1`）を選択します。

### CLI 通常チャット
インストール済みの **Codex CLI**、**Google Antigravity CLI**（`agy`）、**Claude Code** を通常チャットのプロバイダーとして選択できます。モデル ID を空欄にした場合はアカウントの既定モデルが使われ、専用の空作業ディレクトリかつ読み取り専用で安全に呼び出されます。

## AIタスクとCLI連携

右カラム上部の「AIタスク」から、Codex、Antigravity、Claude Code CLI に対して単発の非同期タスクを発行できます。

- **サンドボックスモード**:
  - `read-only`: 作業ディレクトリの変更を行わない安全な読み取り専用モード。
  - `workspace-write`: 指定した作業フォルダ内のみ書き込みを許可するモード（シンボリックリンク検査を行い、ルートフォルダなどへの不正書き込みを防止）。
- 複数のタスクを並行して実行でき、進行ログや終了ステータス、所要時間が記録されます。

## Webリサーチ連携

為替、株価、最新ニュースなどのリアルタイム情報を会話に取り込むことができます。

- **内蔵ブラウザ / 別ウインドウ**:
  上部の「Webリサーチ」からブラウザを開き、調べたいページで「このページを会話に使う」をクリックすると、そのターンの参考情報として会話に注入されます。
- **SearXNG 連携**:
  ローカルで起動した SearXNG（`http://127.0.0.1:8080`、JSON出力有効）と連携し、検索結果を直接取得できます。
- **Tavily 連携**:
  API キーを Keychain に登録することで、「最新のニュースを調べて」といった発話時に自動的に Web 検索を実行し、回答に反映します。

## OpenAI互換Gateway & MCP サーバー

### OpenAI 互換 API
OnigiriServer は `http://127.0.0.1:18080/v1` で標準的な Chat Completions エンドポイントを提供します。

```sh
curl http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "onigiri/current",
    "messages": [{"role": "user", "content": "こんにちは"}],
    "stream": false,
    "onigiri": {"ragMode": "agentic"}
  }'
```

### stdio MCP サーバー (`onigiri-mcp`)
Onigiri の RAG 知識ベースを外部の MCP 対応エージェント（Codex や Claude Code 等）から呼び出すことができます。

```sh
codex mcp add onigiri-rag -- /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/onigiri-mcp
```
ツールとして `searchKnowledge`（関連チャンク検索）と `getKnowledgeChunk`（チャンク取得）が提供され、呼び出し履歴は監査ログとして保存されます。

## 評価システムと回帰テスト (`onigiri-eval`)

`onigiri-eval` は、プロンプト・資料・モデルの変更による RAG 性能の変化を定量測定するための CLI ツールです。

```sh
# 評価スイートを実行してMarkdownレポートを出力
swift run onigiri-eval --suite onigiri-rag-evaluation.json --output rag-report.md

# 回帰が発生した場合に非ゼロの終了コードを返してCIを失敗させる
swift run onigiri-eval --suite onigiri-rag-evaluation.json \
  --format json --output current-report.json \
  --baseline baseline-report.json --fail-on-regression
```

アプリ内でも評価スイートの管理、モデルマトリクス比較、日次自動評価、および回帰アラート通知が可能です。

## Decision Model Lab

「Decision Lab」では、分類やスコアリングなどの意思決定に特化したモデル（Ollaya / TypeSafe 互換）の検証が行えます。
- 入力プリセット、多モデル並行比較実行
- 正解付き評価データセットを用いた Accuracy、Calibration Error、平均遅延、フォールバック率の比較測定

## APIと検証

主要な HTTP エンドポイント（すべて loopback `127.0.0.1:18080`）:

| メソッド | パス | 説明 |
|---|---|---|
| `GET` | `/health` | サーバーの稼働状態と現在プロバイダーの確認 |
| `GET` / `POST` | `/providers`, `/provider` | 利用可能なプロバイダー一覧の取得、および切り替え |
| `GET` | `/local-models` | Onigiri 管理 GGUF モデルの一覧と状態 |
| `POST` | `/local-models/download` | GGUF モデルのダウンロード開始 |
| `POST` | `/local-models/load` | 指定 GGUF モデルを `llama-server` へロード |
| `POST` | `/local-models/benchmark` | ロード済みモデルの受入テスト（ベンチマーク）実行 |
| `POST` | `/chat/stream` | 会話のストリーミング生成（chunked NDJSON） |
| `POST` | `/chat/cancel` | 生成の途中中断 |
| `GET` / `POST` | `/knowledge/documents`, `/knowledge/document` | RAG 資料一覧の取得、新規資料の追加 |
| `POST` | `/knowledge/search` | ハイブリッド RAG チャンク検索 |
| `GET` / `POST` | `/agents/tasks` | AIタスク一覧の取得、新規タスクの実行 |
| `GET` / `POST` | `/v1/models`, `/v1/chat/completions` | OpenAI 互換 Chat Completions API |

> [!IMPORTANT]
> **外部公開時のセキュリティ要件**
> サーバーを LAN 等に公開する場合は、`ONIGIRI_SERVER_HOST=0.0.0.0`、`ONIGIRI_ALLOW_EXTERNAL=1`、および `ONIGIRI_API_TOKEN`（十分に長いトークン）を同時に設定し、全リクエストに `Authorization: Bearer <token>` ヘッダーを付与する必要があります。

## プロジェクト構成

- `Sources/OnigiriApp`: SwiftUI による macOS デスクトップアプリケーション
- `Sources/OnigiriServer`: Network.framework を用いた HTTP / NDJSON サーバー、OpenAI 互換 Gateway
- `Sources/OnigiriCore`: モデルプロバイダー抽象、RAG エンジン、GGUF 管理、AIタスク実行、セキュリティ管理
- `Sources/OnigiriMCP`: stdio Model Context Protocol (MCP) サーバー
- `Sources/OnigiriEvalCLI`: ヘッドレス回帰評価 CLI（`onigiri-eval`）
- `Tests/OnigiriCoreTests`: 単体テスト・統合テスト群（境界テスト、RAG検索、プロバイダーモック）
- `scripts/`: ビルド・パッケージ化・整合性検証用スクリプト群

## 配布とセキュリティ方針

- **Apache License 2.0**: ソースコードはオープンソース（Apache-2.0）として公開されています。
- **ローカルビルドによる利用**: Apple Developer Program へ加入していない期間は、未署名 macOS アプリケーションのバイナリ配布は行いません。ソースコードをクローンし、付属のスクリプトを用いてご自身の環境でビルドしてご利用ください。
- **データプライバシー**: 会話データや RAG 資料はすべてお使いの Mac 内に保存され、ユーザーが明示的に外部プロバイダーや検索 API を指定しない限り、外部ネットワークへ送信されることはありません。外部 API キーは平文ファイルではなく macOS Keychain で厳重に保護されます。

## ライセンス

本ソフトウェアは [Apache License 2.0](LICENSE) の下で提供されています。

商標、外部モデル（Hugging Face、Apple Foundation Models）、外部 CLI（Codex、Google Antigravity、Claude Code）、および外部サービス（LM Studio、Ollama、Tavily、SearXNG）の著作権および利用規約は、それぞれの提供元に帰属します。
