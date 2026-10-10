# 🍙 Onigiri Harness

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![CI](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml/badge.svg)](https://github.com/StayHomeLabNet/onigiri-harness/actions/workflows/ci.yml)

macOS ネイティブのローカル AI ハーネス。Legacy Phase 11 以降ではアプリ画面からローカルテキスト / Markdown / PDF 資料やフォルダを追加し、関連チャンクを会話に差し込む簡易 RAG を使えます。回答ごとに使われた根拠候補を保持し、回答下の `[1]` からチャンク詳細を開けます。検索ではチャンク overlap、タイトル重み付け、完全一致ボーナス、日本語 2/3-gram に加え、LM Studio / Ollama などの OpenAI-compatible `/v1/embeddings` が使える場合は embedding 類似度も併用します。資料一覧、個別削除、プレビュー、関連チャンク確認、サーバー再起動後の資料復元にも対応しています。

```text
OnigiriApp (SwiftUI)
    → HTTP / 127.0.0.1:18080
OnigiriServer (別プロセス / Network.framework)
    → OnigiriCore
    → Harness
    → RAGManager（保存済み資料チャンク / hybrid 関連チャンク検索）
    → CodexAgentManager → Codex / Antigravity / Claude Code CLI（AIタスク）
    → ModelProvider / ModelConversationSession
    → AppleFoundationModelsProvider
      または LocalOpenAICompatibleProvider（LM Studio / Ollama）
      または CLIChatModelProvider（Codex / Antigravity / Claude Code）
```

## 必要な環境

- Apple Silicon Mac、macOS 26 以上
- Xcode 26 以上（初回起動時のセットアップを完了）
- Apple Intelligence が有効で、オンデバイスモデルのダウンロードが完了していること
- AIタスクまたはCLI通常チャットを使う場合は、利用するCodex CLI、Antigravity CLI（`agy`）、Claude Codeのいずれかがインストール済みでログイン済みであること

モデルの準備状態、選択中 provider、資料件数はアプリに表示されます。既定 provider は Apple Foundation Models です。LM Studio と Ollama は OpenAI-compatible API を使います。Codex、Antigravity、Claude Codeはインストール済みCLIを読み取り専用の通常チャットProviderとして利用できます。CLIのModel IDを空欄にするとアカウント既定モデルを使います。provider は起動時の環境変数でも、アプリ画面の provider 設定でも切り替えられます。アプリで選んだ provider、base URL、model ID は次回起動用に保存されます。資料は `Application Support/OnigiriHarness/knowledge.json` に保存されます。embedding は検索時にメモリ上で計算し、利用できない provider では従来のキーワード検索へ戻ります。外部パッケージ依存はありません。

右カラム上部の「データ管理」では、会話、Profile、資料、評価、AIタスク履歴をチェックサム付きJSONバックアップへ書き出し、復元できます。復元前には現在データのロールバック用コピーを自動作成します。保存形式の初回移行時にも`Application Support/OnigiriHarness/migration-backups`へ安全コピーを作成します。Decision Labの外部API keyは平文ファイルへ保存せず、必要な場合だけmacOS Keychainへ保存します。

## 起動する

初回はリポジトリをcloneし、サーバーを起動します。

```sh
git clone https://github.com/StayHomeLabNet/onigiri-harness.git
cd onigiri-harness
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

LM Studio を使う場合は、LM Studio の Local Server を起動し、モデルを読み込んでから、アプリ画面で provider を `LM Studio` にして「適用」を押します。`ONIGIRI_MODEL_ID` または画面上の Model ID を省略した場合は `/v1/models` の先頭のモデルを使います。

```sh
export ONIGIRI_MODEL_PROVIDER=lmstudio
export ONIGIRI_MODEL_BASE_URL=http://127.0.0.1:1234/v1
export ONIGIRI_MODEL_ID=your-loaded-model
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

Ollama を使う場合は、先に `ollama serve` と `ollama pull` でモデルを用意し、アプリ画面で provider を `Ollama` にして「適用」を押します。

```sh
export ONIGIRI_MODEL_PROVIDER=ollama
export ONIGIRI_MODEL_BASE_URL=http://127.0.0.1:11434/v1
export ONIGIRI_MODEL_ID=llama3.2
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

別のターミナルでアプリをビルドして起動します。

```sh
cd onigiri-harness
zsh scripts/build-app.sh
open /tmp/onigiri-harness-build/Onigiri.app
```

アプリで利用可能と表示されたら「こんにちは」を送信します。返答は生成に合わせて画面へ表示され、続けて送った質問ではそれまでの会話が参照されます。「資料/フォルダを追加」から UTF-8 のテキスト / Markdown / PDF ファイル、またはそれらを含むフォルダを追加すると、質問に関連するチャンクが provider へ渡され、回答内に `[1]` のような引用番号が出ます。フォルダ指定時は `.txt` / `.text` / `.md` / `.markdown` / `.pdf` を再帰的に取り込みます。資料がヒットした回答では、回答本文の下に「この回答の根拠」が表示され、`[1]` の行を押すとチャンク本文を開けます。「資料一覧」ではプレビュー確認と個別削除ができます。「関連チャンク」では、入力中の質問または直近のユーザー発話に一致した資料チャンク、引用番号、スコアを確認できます。検索はタイトル一致を強く評価し、長い資料では前チャンク末尾を overlap として引き継ぎます。ライブ情報を調べるには「Webリサーチ」でページを開き、「このページを会話に使う」を選んでから質問を送ります。URL、取得時刻、本文の抜粋はその質問だけの参考資料となり、回答の下に情報源として表示されます。「新しい会話」を押すと画面とモデルの履歴を破棄します。サーバーは最初のターミナルで Control-C を押すと停止します。アプリを閉じてもサーバーは独立して動作します。

入力欄では通常の Enter で送信し、Shift+Enter で改行します。日本語IMEの変換候補を Enter で確定している間は送信されません。メニューバーの「Onigiri Harness」→「設定…」から表示言語を日本語または英語へ切り替えられ、開いているOnigiriウインドウへすぐに反映されます。

すべての資料をクリアすると、各会話のRAGコンテキスト境界も更新されます。クリア前の資料由来の引用と検索結果は後続リクエストへ渡されず、資料が0件の状態で資料の有無を尋ねた場合は、モデルに推測させず「現在はRAG資料がない」と回答します。

「今日は何年何月？」などの現在日付はMacのローカル日時から回答します。為替・株価・天気・ニュースなどのライブ情報は、内蔵した「Webリサーチ」で利用者が開いて選択したページから回答できます。既定では外部検索APIを使わず、任意設定でローカルSearXNGまたはTavily検索を選べます。アプリが検索済みであるかのように装ったり、選択していないページの情報や数値を推測したりしません。ページ本文は参考データとして扱い、ページ内の指示は実行しません。

ローカルでSearXNGを起動している場合は、「Webリサーチ」内の「SearXNGローカル連携」を有効にし、`http://127.0.0.1:8080` のようなloopback URLを設定できます。検索語を入力するとSearXNGのJSON検索結果を最大8件表示し、選んだ結果のページを内蔵ブラウザで開けます。ページを「このページを会話に使う」で明示的に選ぶまで、検索結果や本文は会話へ渡りません。URLは同一Mac上の`localhost`、`127.0.0.1`、`::1`だけを受け付けます。

SearXNGの`settings.yml`ではJSON形式を有効にしてください。

```yaml
search:
  formats:
    - html
    - json
```

Tavilyを使う場合は、「Webリサーチ」内の「Tavily連携」を有効にしてAPI keyをmacOS Keychainへ保存します。「Webで検索して」「最新の為替」「今日のニュース」のようなWeb検索・ライブ情報の依頼では、チャット送信前にTavilyを自動検索し、上位3件の本文スニペットをその回答だけの情報源として渡します。回答下にURLと取得時刻を表示し、後続ターンには残しません。通常の質問、翻訳・箇条書きなどの追従変換、明示的に検索しないよう求めた入力では自動検索しません。Tavilyの無料プランでも利用できますが、毎月のAPIクレジット上限があります。

SearXNGとTavilyの設定欄には「接続確認」があります。SearXNGはJSON検索の結果数と応答時間を確認し、JSONが無効なHTTP 403では`search.formats`へ`json`を追加する手順を表示します。Tavilyの接続確認は1 APIクレジットを使用し、API key不正、リクエスト頻度、月間利用上限をHTTPステータス別に案内します。

OneDrive の拡張属性によるコード署名エラーを避けるため、生成物は `/tmp/onigiri-harness-build` に置きます。再起動や一時ファイル削除後は再ビルドしてください。

配布候補のRelease構成アプリ、ZIP、SHA-256 checksumを作る場合は次を実行します。Developer ID署名前の成果物なので、ファイル名には`unsigned`が付きます。

```sh
bash scripts/check-repository.sh
ONIGIRI_BUILD_CONFIGURATION=release zsh scripts/package-app.sh
shasum -a 256 -c release/*.sha256
```

versionはリポジトリ直下の`VERSION`で管理します。詳しい環境変数とCIの内容は[再現可能なビルドとCI](docs/BUILD_AND_CI.md)を参照してください。

Developer ID証明書を使った署名、Apple公証、staple、Gatekeeper検証は`scripts/release-app.sh`へまとめています。Apple側の準備、ローカル実行、GitHub Actions Secretsの登録方法は[署名・公証済みmacOS配布](docs/SIGNED_DISTRIBUTION.md)を参照してください。

## 公開と配布の方針

このリポジトリはApache-2.0でソースコードを公開します。Apple Developer Programへ加入していない間は、GitHub Releasesへ未署名のmacOSアプリを掲載しません。利用する場合はソースをcloneし、上記の手順でローカルビルドしてください。CIが保存する`unsigned` artifactはビルド再現性を確認するための検証成果物であり、一般配布用アプリではありません。

Developer ID署名・Apple公証の自動化は将来利用できるよう保持していますが、ソース公開の必須条件にはしません。

Xcode では `Package.swift` を開き、`OnigiriApp` または `OnigiriServer` の Scheme を選べます。最初は上記のターミナル手順で起動するのが確実です。

Serverは既定で`127.0.0.1`だけをlistenします。LANなどへ明示的に公開する場合は、外部待受とBearer認証を同時に設定する必要があります。

```sh
export ONIGIRI_SERVER_HOST=0.0.0.0
export ONIGIRI_ALLOW_EXTERNAL=1
export ONIGIRI_API_TOKEN='十分に長いランダムなtoken'
swift run --scratch-path /tmp/onigiri-harness-build OnigiriServer
```

外部公開時はすべてのリクエストへ`Authorization: Bearer <token>`を付けます。`ONIGIRI_ALLOW_EXTERNAL=1`またはtokenの片方だけではServerは起動しません。

## API と検証

Parent Phase 5.2着手前の実機確認には、[リリース前受け入れテスト手順書](docs/ACCEPTANCE_TEST_PLAN.md)と[同梱テスト素材](docs/test-materials/README.md)を使用します。結果記録用CSVと、読み取り専用のAPIスモークスクリプトも同梱しています。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path /tmp/onigiri-harness-build
curl http://127.0.0.1:18080/health
curl --no-buffer --max-time 120 http://127.0.0.1:18080/chat/stream \
  -H 'Content-Type: application/json' \
  -d '{"conversationID":"11111111-1111-1111-1111-111111111111","message":"こんにちは"}'
```

- `GET /health`: `{"available":true,"detail":"…","providerID":"apple-foundation-models","providerName":"Apple Foundation Models"}`。サーバーが正常でもモデル未準備なら `available` は `false`。LM Studio では `providerID` が `lmstudio`、Ollama では `ollama` になります。
- `GET /providers`: アプリで選べる provider と現在の provider 設定を返します。
- `POST /provider`: `{"providerID":"lmstudio","baseURL":"http://127.0.0.1:1234/v1","modelID":"..."}` で provider を切り替えます。切り替え時はサーバー上の会話セッションを破棄します。
- `GET /models`: 現在の provider が返すモデル ID 一覧を返します。Apple Foundation Models では空配列です。
- `GET /v1/models`: OpenAI互換形式で`onigiri/current`、現在Providerのモデル、`profile/<UUID>`を返します。
- `POST /v1/chat/completions`: OpenAI互換の非Streaming／SSE Streaming Chat Completionsです。任意の`onigiri`拡張でProfile、RAGモード、検索設定、コンテキスト上限、選択チャンクを指定できます。
- `GET /agents/status`: Codex、Antigravity、Claude Code CLIの検出結果と実行ファイルの場所を返します。
- `GET /agents/tasks`: 会話とは別に保存されたAIタスク実行履歴を返します。
- `POST /agents/tasks`: `provider`（`codex`／`antigravity`／`claudeCode`）、`prompt`、`workingDirectory`、任意の`model`、`sandboxMode`、`timeoutSeconds`で単発タスクを開始します。`sandboxMode`は`read-only`または`workspace-write`です。
- `POST /agents/tasks/cancel`: `id`で実行中のAIタスクをキャンセルします。
- 従来の`/codex/status`、`/codex/tasks`、`/codex/tasks/cancel`は後方互換用に維持します。providerを省略した旧リクエストと旧履歴はCodexとして読み込みます。
- `GET /decision/providers`: Decision Model Labが対応するProvider一覧を返します。
- `POST /decision/models`: OllayaまたはTypeSafe互換Providerのモデル一覧を返します。
- `POST /decision/run`: テキスト／JSON状態と`choice`・`score`・`noul`質問を意思決定モデルへ送り、独立した実験履歴として保存します。
- `GET /decision/runs`: 通常チャットとは分離された意思決定実験履歴を返します。
- `POST /decision/runs/clear`: 意思決定実験履歴をクリアします。
- `GET /decision/evaluations`: 保存済みの意思決定評価レポートを返します。
- `POST /decision/evaluations/run`: 複数モデル×正解付きケースを実行し、accuracy、calibration error、遅延、fallback率を集計します。
- `POST /decision/evaluations/clear`: 意思決定評価レポートをクリアします。
- `GET /tools/knowledge`: Agentic RAGから利用できるモデル非依存のKnowledge Tool定義を返します。
- `GET /tools/audit`: MCP／HTTPからのKnowledge Tool呼び出し監査ログを返します。
- `POST /tools/audit/clear`: Knowledge Tool監査ログをクリアします。
- `POST /tools/searchKnowledge`: `query`と検索設定を受け取り、順位と引用情報を持つチャンクを返します。
- `POST /tools/getKnowledgeChunk`: `chunkID`を受け取り、該当チャンクの完全な本文とメタデータを返します。
- `GET /knowledge`: メモリ上の資料数とチャンク数を返します。
- `GET /knowledge/documents`: 追加済み資料の ID、タイトル、チャンク数、プレビューを返します。
- `POST /knowledge/document`: `{"title":"memo.txt","content":"..."}` を受け取り、本文をチャンク化して資料として追加します。
- `POST /knowledge/delete`: `{"id":"..."}` で資料を1件削除します。
- `POST /knowledge/search`: `{"query":"..."}` で関連チャンク、引用番号、スコア、本文、検索モードを返します。スコアは本文語句、タイトル語句、完全一致、長めの語句一致、利用可能な場合は embedding 類似度を組み合わせます。
- `POST /evaluation/run`: 質問、期待するチャンクID、検索要否、RAGモード、検索設定を受け取り、独立したモデルセッションで回答を生成します。検索判断、Agentic検索語、診断、検索順位、検索再現率、引用精度・引用再現率、処理時間と回答を返します。
- `POST /knowledge/clear`: メモリ上の資料をすべて破棄します。
- `POST /chat/stream`: `conversationID` と `message` を受け取り、改行区切り JSON を chunked response で返します。
- `POST /chat/cancel`: `conversationID` に対応する進行中の生成を中断し、そのモデルセッションを破棄します。
- ストリームイベント: `snapshot` はその時点までの返答全文、`ragTrace` はAgentic RAGの判断・検索語・取得チャンク、`done` は完了、`error` は生成エラーです。
- `POST /conversation/reset`: `conversationID` に対応するサーバー上のモデルセッションを破棄します。
- ストリーム開始前の JSON エラーは `{"error":"…"}`。入力不正は 400、モデル利用不可は 503 です。生成開始後の競合やモデルエラーは `error` イベントとして通知します。

会話履歴はサーバーのメモリ上だけに保持し、サーバーを終了した場合は失われます。資料は JSON として保存し、サーバー起動時に復元します。入力は前後の空白を除いて 1〜4,000 文字です。資料本文は1ファイル 200,000 文字までです。モデル側のコンテキスト上限や安全性チェックによって生成が失敗することもあります。

HTTP は loopback のみ、1 接続 1 リクエスト、Content-Length 形式、本文最大 32 KiB に限定します。ブラウザーの Origin 付きリクエストは拒否します。同一 Mac 内のプロセス向けの未認証開発 API です。公開サーバーとしての運用は対象外です。

## ファイル構成

- `Sources/OnigiriApp`: 会話表示、逐次更新、HTTP クライアント
- `Sources/OnigiriServer`: HTTP、chunked NDJSON、Core への橋渡し
- `Sources/OnigiriCore`: 入出力型、入力検証、provider 抽象、Apple / OpenAI-compatible provider、会話別セッション、ストリーミング推論
- `Tests/OnigiriCoreTests`: 入力境界、ストリームイベント、provider 差し替え、会話削除のテスト
- `scripts/build-app.sh`: 開発用 `.app` バンドル作成（ローカル署名）

## 次の段階

Parent Phase 5 / Sub-phase 5.2では、GitHubでのソース公開、再現可能なビルド、CI、公開後の検証を整備します。公開方針と確認項目は[GitHub公開計画](docs/GITHUB_RELEASE_PLAN.md)にまとめています。

## ライセンス

Onigiri Harnessは[Apache License 2.0](LICENSE)で提供します。商標、外部モデル、外部CLI、各Providerのサービスには、それぞれの提供元の規約とライセンスが適用されます。

Legacy Phase 31 では、現在のprovider、model ID、Base URL、検索設定を名前付きの「評価環境」として複数保存できるようにしました。選択した環境でモデルを自動的に切り替えながら全ケースを順番に実行し、完了後は元のモデルへ戻します。基準結果があるケースでは、合格から不合格への変化、検索・引用・回答要点・資料裏付けの低下、20%以上または250msを超える速度悪化を「回帰アラート」として表示します。評価環境と選択状態は次回起動時にも復元されます。

Legacy Phase 32 では、モデルマトリクス評価1回分を独立したレポートとして最大100件保存するようにしました。評価画面で過去の実行を選択し、合格率と平均処理時間の推移グラフ、実行環境ごとの結果、不合格ケースだけの絞り込みを確認できます。選択中のレポートは、全件または不合格ケースだけをMarkdownへ書き出せます。

同じ合否判定とMarkdown形式を使う `onigiri-eval` CLIも追加しました。アプリから書き出した評価JSONと、起動中のOnigiriServerを指定して実行できます。不合格があれば終了コード1、入力や通信の失敗は終了コード2を返します。

```sh
swift run onigiri-eval --suite onigiri-rag-evaluation.json --output rag-report.md
swift run onigiri-eval --suite onigiri-rag-evaluation.json --rag-mode agentic --failed-only
```

Legacy Phase 33 では、選択済みの評価環境とケースを毎日指定時刻に自動実行できるようにしました。アプリ起動中に時刻を過ぎると1日1回実行し、自動・手動・CLIをレポート上で区別します。レポート保持期間は1〜365日で設定でき、直前レポートから合否、検索・引用・回答要点・資料裏付け、処理時間が悪化したケースを検出します。自動評価で回帰が見つかった場合はmacOS通知を送信できます。

`onigiri-eval` CLIは `--provider`、`--base-url`、`--model` で評価環境を切り替え、検索件数・閾値・Keyword/Embeddingウェイトを指定できるようになりました。`--format json` を使うと、CIや監視処理で読み取れる機械可読レポートを生成します。

```sh
swift run onigiri-eval --suite onigiri-rag-evaluation.json \
  --provider ollama --base-url http://127.0.0.1:11434/v1 --model llama3 \
  --limit 8 --keyword-weight 1.2 --embedding-weight 1.5 \
  --format json --output rag-report.json
```

Legacy Phase 34 では、評価ケースを名前付きスイートとタグで整理し、選択中のスイートだけを手動・マトリクス・自動評価の対象にできるようにしました。スイートではケースを自由に追加・除外でき、ケース複製と、最新回答を文単位で整理した期待要点候補の作成にも対応しています。

評価レポートには、資料ID、タイトル、チャンク数、Embedding数、分割設定から生成した資料版IDを保存します。過去レポートとの比較では、資料の追加・削除、名称変更、チャンク数・Embedding数、分割設定の差を表示し、RAG精度の変化と資料変更を同じ画面で追跡できます。Legacy Phase 32・33の既存ケースとレポートは、そのまま読み込めます。

Legacy Phase 35 では、資料ごとに未評価チャンクを選び、検索されやすい語句を使った質問、根拠チャンク、期待要点を評価ケース候補として自動生成できるようにしました。候補は追加前に確認・選択でき、追加後は「自動生成」と資料名のタグが付き、選択中の評価スイートにも自動で登録されます。

評価画面では、資料カバー率、期待チャンクカバー率、実際の検索到達率を分けて表示します。未評価の資料、検索結果に一度も現れていないチャンク、タグ・スイートごとのケース数と対象資料数、質問文または根拠チャンクが似ている重複ケースも確認できます。

Parent Phase 0 / Sub-phase 0.4では、モデル、Base URL、Model ID、システム指示、RAGモード、検索設定、コンテキスト上限をまとめるProduct Profileを追加しました。Profileは作成、複製、名称変更、削除、既定指定ができ、会話ごとの割り当てと再起動後の復元に対応します。従来の`@AppStorage`設定は初回起動時に`general`へ移行され、`apple-local`も同時に作成されます。

Parent Phase 0 / Sub-phase 0.5では、会話履歴、資料、選択チャンク、言語変換指示をProfileのコンテキスト上限内で組み立てるContext Builderを追加しました。生成中は送信ボタンが停止ボタンへ切り替わり、Apple FMとローカルモデルの生成を中断して同じ会話から再送信できます。

Parent Phase 1 / Sub-phase 1.3では、資料の保存、分割、検索、Embedding、プロンプト組み立てをRAG Managerへ集約しました。Profileの`disabled`では資料を検索・注入せず、`always`では質問ごとに検索して根拠を渡します。使用モードは会話、Markdown書き出し、評価結果、評価CSV／Markdownへ記録されます。次のAgentic RAG用に`searchKnowledge`と`getKnowledgeChunk`の共通Tool契約も追加しました。

Parent Phase 1 / Sub-phase 1.4では、ProfileのRAGモードに「AIが判断」を追加しました。AIは回答前にローカル資料の検索要否と検索語をJSONで決めます。最初の検索結果が弱い場合は、AIが用意した別の検索語で1回だけ再検索します。検索は最大2回、再検索開始は判断開始から5秒以内、取得数はProfileの検索上限までです。構造化判断に失敗した場合は質問文を使う`always`検索へ戻ります。回答には判断理由、検索語、Tool回数、所要時間が表示され、会話Markdownにも保存されます。

Parent Phase 1 / Sub-phase 1.5では、評価ケースに「資料検索が必要」の期待値を追加し、検索不要ケースも画面から作成できるようにしました。Agentic評価は実際の検索判断と再検索を実行し、適合率・再現率、誤検索、検索漏れ、再検索回復を集計します。検索に届かない場合は、検索語、閾値、Keyword／Embedding配分、チャンク境界を原因候補として表示します。全資料の未評価チャンクから評価候補を一括生成でき、モデルマトリクスではRAGモードも独立した比較条件になります。CLIは`--rag-mode disabled|always|agentic`に対応しました。

Parent Phase 2 / Sub-phase 2.1では、右カラム上部の「Codexタスク」からCodex CLIへ単発タスクを渡せるようにしました。既定は読み取り専用で、必要な場合だけ作業フォルダへの書き込みを選択できます。進行状況、完了結果、失敗、キャンセル、タイムアウトを表示し、実行履歴は会話履歴とは別に`Application Support/OnigiriHarness/codex-tasks.json`へ保存します。Codex CLIのJSONL出力を利用する設計は[OpenAIのCodex自動化ガイド](https://developers.openai.com/blog/eval-skills)に基づきます。

Parent Phase 2 / Sub-phase 2.2では、Onigiri RAGをstdio MCP Serverとして公開しました。右カラム上部の「MCP」画面から登録コマンドをコピーできます。現在の開発用アプリは次のコマンドで登録できます。

```sh
codex mcp add onigiri-rag -- /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/onigiri-mcp
codex mcp get onigiri-rag --json
```

Onigiriを起動した状態で新しいCodexセッションを開始すると、`searchKnowledge`と`getKnowledgeChunk`を利用できます。どちらも読み取り専用で、資料追加・削除はMCPへ公開しません。呼び出し監査ログは`Application Support/OnigiriHarness/knowledge-tool-audit.json`へ最大500件保存し、MCP画面で確認・クリアできます。実装は[公式OpenAI documentationのMCP Serverガイド](https://developers.openai.com/plugins/build/mcp-server)に沿って、入力スキーマ、構造化結果、読み取り専用・非破壊・閉じたデータ範囲の注釈を付けています。

Parent Phase 2 / Sub-phase 2.3では、「Codexタスク」を「AIタスク」へ統合しました。同じ画面でCodex、Google Antigravity、Claude Codeを選択し、モデル、作業フォルダ、読み取り専用／書き込み、タイムアウトを指定できます。タスクごとに独立したプロセスを使うため、異なるCLIを含む複数タスクを同時実行できます。履歴には実行AIと設定を保存し、旧Codex履歴は自動的にCodexとして移行します。Antigravityは[公式Headless Mode](https://www.antigravity.google/docs/cli/headless/)、Claude Codeは[公式CLI reference](https://code.claude.com/docs/en/cli-usage)のStreaming JSON出力を利用します。

Parent Phase 3 / Sub-phase 3.1では、Jev専用計画をDecision Model Labへ拡張しました。右カラム上部の「Decision Lab」から、OllayaまたはTypeSafe互換/Jev Providerを選択し、テキスト／JSON状態と`choice`・`score`・`noul`質問を実行できます。Ollayaでは`/api/tags`からLaya、Winnow、Decider、NLI、GLiClassなど現在インストールされているモデルを動的に取得します。結果、応答モデル、routing、確率、confidence、処理時間、失敗は`Application Support/OnigiriHarness/decision-lab-runs.json`へ最大200件保存し、APIキーは保存しません。Ollaya 0.8.0で`laya:multilingual`、`laya:en`、`laya:latest`の検出を確認済みです。Ollayaの共通質問形式とAPIについては[公式Ollaya API reference](https://ollaya.dev/docs/api)を参照してください。

Parent Phase 3 / Sub-phase 3.2では、Decision Labの「評価」から複数モデルと正解付きケースを指定し、accuracy、calibration error、平均遅延、完了数、fallback率を比較できるようにしました。confidence閾値とfallback先は既定値に加え、モデル別・質問別にoverrideできます。低confidence時のLLM／人へのfallbackはレポート表示だけのシミュレーションです。評価レポートは`Application Support/OnigiriHarness/decision-evaluation-reports.json`へ最大100件保存し、通常の実験履歴とAPIキーは含めません。

Parent Phase 3 / Sub-phase 3.3では、Decision Labに入力プリセットと比較実行を追加しました。状態と質問を名前付きで保存して再利用でき、複数のモデルを選択すると同一入力を順番に評価して実験履歴に並べます。比較実行も観察専用で、回答に応じた外部操作は行いません。

`laya:multilingual`を使った日本語2分類ケースの実モデル確認では、2/2件が正解し、平均遅延1,168ms、calibration error 0.00535、confidence 0.7未満のfallback 0件を記録しました。初回推論は2,319ms、2件目は17msで、モデルのウォームアップを含む値です。

Parent Phase 4 / Sub-phase 4.1では、OnigiriをOpenAI互換のローカルGatewayとして利用できるようにしました。Base URLは`http://127.0.0.1:18080/v1`です。`/v1/models`は現在モデルとProduct Profileを列挙し、`/v1/chat/completions`は非StreamingとSSE Streamingに対応します。Profile指定はモデルIDとして`profile/<UUID>`を使うか、`onigiri.profileID`／`onigiri.profileName`を指定します。RAGモード、引用、Agentic RAG traceはレスポンスの`onigiri`フィールドへ格納されます。

Parent Phase 4 / Sub-phase 4.2では、Codex、Google Antigravity、Claude Codeを通常チャットのModel Providerへ追加しました。上部のモデル選択から切り替えられ、Profile、会話文脈、RAG、Compatibility APIを既存モデルと同じ経路で利用できます。CLI Chatは専用の空作業フォルダと読み取り専用モードで実行します。モデルIDは自由入力で、空欄なら各CLIの既定モデルです。実機ではCodexとAntigravityの通常チャット応答を確認し、未導入のClaude Codeは利用不可理由を表示することを確認しました。

Parent Phase 5 / Sub-phase 5.1では、保存形式version、移行前安全コピー、チェックサム付きバックアップ／復元、復元失敗時のロールバック、破損JSON診断、Keychain、外部待受の明示許可とBearer認証を追加しました。AIタスクの書き込み先はsymlink解決後に検査し、ルートフォルダへの書き込みを拒否します。

Parent Phase 5 / Sub-phase 5.1aでは、リリース前受入で見つかった4系統の阻害問題を修正しました。Apple Foundation Modelsは変換用途向けguardrailで生成し、失敗時はApple Intelligenceの確認手順を返します。Agentic RAGはprimary最上位を保持してretry結果を統合します。本文の引用番号はmetadataへ正規化し、翻訳や箇条書きなどの追従変換では不要な再検索と引用付与を行いません。Antigravityの読み取り専用headlessタスクはplan modeとsandboxを保ったまま結果を完了できます。

```sh
curl http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "onigiri/current",
    "messages": [{"role": "user", "content": "こんにちは"}],
    "stream": false,
    "onigiri": {"ragMode": "disabled"}
  }'
```

`onigiri`を省略すると既定のChat Runtimeを使います。`ragMode`は`disabled`、`always`、`agentic`です。Product Profileを使う場合は、そのProfileのProvider、モデル、システム指示、RAG設定、コンテキスト上限がリクエスト単位で適用されます。OpenAI互換APIは現時点でもloopback限定です。

同梱OnigiriServerが終了している場合は、画面左上の「再確認」でサーバーを再起動して接続を回復します。アプリを再ビルドした場合は、以前のOnigiriを完全に終了してから新しい`.app`を開いてください。

Parent Phase 5 / Sub-phase 5.2sでは、Webリサーチを独立したmacOSウインドウで開けるようにしました。上部の「Webリサーチ」メニューから「別ウインドウで開く」を選ぶと、チャットを表示したままページ閲覧・検索・ブックマークを続けられます。「このページを会話に使う」で選んだページは、メインウインドウの次の質問に同じように添付されます。

Parent Phase 6 / Sub-phase 6.1では、回答の「根拠・再現」を追加しました。新しい回答には、質問、会話履歴、実行日時、Profile、Provider、モデル、RAG設定、引用、Agentic RAG traceを保存します。上部の「根拠・再現」から条件を確認し、別のProfileまたはRAGモードで同じ入力を独立再実行できます。比較結果は元の回答へ保存され、通常の会話や現在のProfileは変更しません。

今後は、大きな到達点を`Parent Phase`、実装単位を`Sub-phase`と表記します。現在は`Parent Phase 5 / Sub-phase 5.2 — GitHub Source Publication`です。

全体計画、各Parent Phase／Sub-phaseの完了条件、依存関係は [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) を参照してください。

Foundation Models の仕様: https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models

## Legacy Phase 11 の確認結果（2026-09-27）

macOS 27.0 / Xcode 27.0 で、次を確認済みです。

- 3 ターゲットのビルド成功、Swift Testing の18テスト成功
- `/health` が `available: true` と `providerID: apple-foundation-models` を返す
- `/providers`、`/provider`、`/models` の API 応答を確認
- `/chat/stream` が複数の `snapshot` と `done` を返す
- 同じ会話 ID の2ターン目で、1ターン目に伝えた合言葉を正しく回答する
- `/conversation/reset` が `cleared: true` を返す
- Legacy Phase 11 の `.app` をビルドし、provider 設定を `@AppStorage` で保存する実装を確認
- LM Studio `google/gemma-4-12b` で `/models`、`/health`、`/chat/stream` を確認
- Ollama `granite4.1:8b` で `/models`、`/health`、`/chat/stream` を確認
- `/knowledge`、`/knowledge/document`、`/knowledge/clear` の API 実装を確認
- `/knowledge/documents`、`/knowledge/delete`、`/knowledge/search` の API 実装を確認
- 資料一覧、個別削除、関連チャンク検索、永続保存と復元のテストを確認
- アプリから UTF-8 テキスト / Markdown / PDF 資料、またはそれらを含むフォルダを追加できる import 実装を確認
- 回答ごとの根拠候補表示と、引用チャンク詳細シートの実装を確認
- チャンク overlap、タイトル重み付け、完全一致ボーナス、日本語 2/3-gram 検索のテストを確認
- embedding 類似度でキーワード不一致の資料を拾える hybrid 検索のテストを確認
- Ollama `granite4.1:8b` で資料由来の「金色のおにぎり」と引用 `[1]` を含む RAG 応答を確認

Developer IDによる配布用署名・公証は任意の将来対応として保留しています。
