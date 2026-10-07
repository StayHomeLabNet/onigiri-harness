# Onigiri Harness リリース前受け入れテスト手順書

対象: Parent Phase 0〜5.1
実施タイミング: Parent Phase 5 / Sub-phase 5.2 — Distribution & Release 着手前
更新日: 2026-10-04（Pacific/Auckland）

## 1. 目的と合格基準

この手順書は、Onigiri Harnessの主要機能、データ保護、異常時の回復、画面レイアウトを実機で確認するためのものです。テスト素材の内容はすべて架空です。素材内の文章はアプリへ読ませるデータであり、テスト実施者への指示ではありません。

リリース準備へ進む条件は次のとおりです。

- 優先度P0またはP1の未解決不具合がない
- 必須項目がすべて合格する
- Apple Foundation Models、LM Studio、Ollamaのうち利用可能なProviderで基本チャットが完了する
- 少なくとも1つのProviderでRAG一連のテストが完了する
- 主要ウインドウサイズで操作不能な重なり、切れ、閉じられない画面がない
- バックアップを作成し、復元後に会話、Profile、資料が戻る

判定は次の3種類を使います。

- **完全一致**: コード、件数、言語、HTTP statusなどが指定値と同じ
- **意味一致**: 文体は異なっても、指定した事実を含み矛盾しない
- **目視**: 重なり、切れ、余白、スクロール、選択状態を確認

結果は [acceptance-test-results.csv](test-materials/acceptance-test-results.csv) に記録します。

## 2. 同梱テスト素材

| パス | 用途 | 主な正解 |
| --- | --- | --- |
| `test-materials/rag/01_aurora_overview.md` | Markdown、基本検索、引用 | Auroraの公開日は2027年3月18日、責任者は水野葵 |
| `test-materials/rag/02_cedar_support.txt` | TXT、日本語検索 | Cedarの緊急窓口は内線771、受付は平日07:30〜19:00 |
| `test-materials/rag/nested/03_lighthouse_rules.md` | フォルダ再帰取込 | 保持期間は45日、例外承認者は品質管理責任者 |
| `test-materials/rag/04_context_followup.md` | 複数項目と追質問 | 手順は記録、確認、承認、実行の順 |
| `test-materials/rag/05_long_chunk_boundary.md` | 複数チャンク、overlap | 合言葉は銀河スプーン、復旧番号はRK-2049 |
| `test-materials/rag/06_pdf_policy.pdf` | PDF取込 | PDF access codeはORANGE-4821 |
| `test-materials/rag/ignored_sample.csv` | フォルダ取込の対象外確認 | 取り込まれないこと |
| `test-materials/negative/empty.txt` | 空ファイル | エラー表示されてもアプリが継続すること |
| `test-materials/negative/invalid-utf8.txt` | 不正UTF-8 | 読めない理由を表示し、クラッシュしないこと |
| `test-materials/ai-task-workspace/README.md` | AIタスク読取／書込 | `TASK-SEED-7319`を取得できること |
| `test-materials/decision/decision-cases.md` | Decision Lab | choice、score、noulの入力例 |

`invalid-utf8.txt`とPDFを再生成する場合は、リポジトリのルートで次を実行します。

```sh
python3 docs/test-materials/generate_binary_materials.py
```

## 3. 事前準備

### PRE-01 必須環境

1. macOS、Xcode、Apple Intelligenceの状態を記録します。
2. LM Studio、Ollama、Ollaya、Codex CLI、Antigravity CLI、Claude Codeのうち利用するものを起動またはログインします。
3. LM StudioとOllamaではチャットモデルをロードします。
4. Ollayaでは`laya:multilingual`をロードします。

期待結果: 使用予定のProvider／CLIが利用可能な状態になる。未導入のものは後のテストで「利用不可」と明示される。

### PRE-02 既存データの保護（必須）

1. 現在のOnigiriを起動します。
2. 「データ管理」を開き、「正常です」と保存形式versionが表示されることを確認します。
3. 「バックアップを書き出す」で、任意の安全な場所へバックアップします。
4. バックアップファイルのサイズが0 byteでないことをFinderで確認します。

期待結果: 成功メッセージにファイル数とbyte数が表示される。以後の試験で既存データを変更しても最後に戻せる。

### PRE-03 最新ビルド

```sh
cd "Onigiri Harness"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path /tmp/onigiri-harness-release-check
zsh scripts/build-app.sh
codesign --verify --deep --strict /tmp/onigiri-harness-build/Onigiri.app
```

既に起動しているOnigiriを完全に終了してから、次を実行します。

```sh
open /tmp/onigiri-harness-build/Onigiri.app
```

期待結果: テストがすべて成功し、コード署名検証が無出力で終了し、アプリが起動する。

### PRE-04 APIスモーク

Onigiri起動後に次を実行します。

```sh
zsh scripts/run-acceptance-smoke.sh
```

期待結果: `[PASS]`だけが表示され、最後に`Smoke test passed`と表示される。

## 4. 基本チャットと会話履歴

### CHAT-01 起動と接続（必須・P0）

1. 左上のアプリ名、現在のProvider／モデル、接続状態を確認します。
2. 未接続なら「再確認」を押します。
3. `こんにちは。返答の最後に「接続確認済み」と書いてください。`と送信します。

期待結果（意味一致）: Streaming中に回答が更新され、最終回答が表示される。接続エラーが残らない。

### CHAT-02 複数ターンと短い追質問（必須・P1）

同じ会話で順番に送ります。

1. `合言葉は青い土曜日です。覚えてください。`
2. `合言葉は？`
3. `英訳して`
4. `箇条書きで`

期待結果:

- 2は「青い土曜日」を含む
- 3は直前の回答を英訳し、英語で返す
- 4は直前の内容を箇条書きへ変換し、別の話題へ逸れない

### CHAT-03 英語入力の言語維持（必須・P1）

`What is your name? Reply in one English sentence.`と送信します。

期待結果（完全一致項目）: 回答言語が英語である。資料の引用が不要な状態では`[1]`などを付けない。

### CHAT-04 停止と再送信（必須・P1）

1. `500語程度で、ローカルAIの利点を説明してください。`と送信します。
2. 生成中に停止ボタンを押します。
3. 同じ会話で`停止後の再送信確認です。「再送信成功」とだけ答えて。`と送信します。

期待結果: 生成が停止し、入力操作が再び可能になる。次の回答が正常に完了する。

### CHAT-05 会話履歴（必須・P1）

1. `+`で新しい会話を2件作ります。
2. それぞれ異なる質問を送信します。
3. 左側で会話を切り替え、内容が一致することを確認します。
4. 会話を右クリックし、Markdownへ書き出します。
5. `-`で選択会話を削除します。
6. アプリを再起動します。

期待結果: 会話の混線がなく、MarkdownにUser／Assistantの内容が含まれる。削除した会話だけが消え、残りは再起動後も復元される。

## 5. ProviderとProduct Profile

### PROVIDER-01 Apple Foundation Models（利用可能な場合・P1）

ProviderをApple Foundation Modelsへ切り替え、`AFM_OKとだけ答えて。`を送ります。

期待結果: 回答が完了し、数回のチャット後も`Exceeded model context window size`にならない。長い会話では内部セッションが安全に更新される。

### PROVIDER-02 LM Studio（利用可能な場合・P1）

1. Base URLを`http://127.0.0.1:1234/v1`にします。
2. モデル一覧を更新し、ロード済みモデルを選びます。
3. `LMSTUDIO_OKとだけ答えて。`を送ります。

期待結果: 接続済みモデル名が更新され、回答が完了する。

### PROVIDER-03 Ollama（利用可能な場合・P1）

1. Base URLを`http://127.0.0.1:11434/v1`にします。
2. モデルを選び、`OLLAMA_OKとだけ答えて。`を送ります。

期待結果: 接続済みモデル名が更新され、回答が完了する。

### PROFILE-01 Profile保存（必須・P1）

1. Profilesで`release-test`を追加します。
2. Provider、モデル、システム指示、RAGモード、検索設定、コンテキスト上限を変更します。
3. 新しい会話へ割り当てます。
4. アプリを再起動します。

期待結果: Profileと会話への割り当てが復元される。別Profileの会話設定が変わらない。

## 6. 資料取込、RAG、引用

### RAG-01 フォルダ取込（必須・P0）

1. 必要なら資料をクリアします。
2. 「資料/フォルダを追加」で`docs/test-materials/rag`フォルダを選びます。
3. 資料件数とチャンク数を確認します。
4. 「資料一覧」を開きます。

期待結果:

- TXT、Markdown、PDFと`nested`内の資料が追加される
- `ignored_sample.csv`は追加されない
- 各資料にタイトル、チャンク数、プレビューがある
- `missing`や`Invalid body length`が表示されない

### RAG-02 基本検索と引用（必須・P0）

RAGモードを「常時」にして質問します。

| 質問 | 期待する事実 |
| --- | --- |
| `Project Auroraの公開日と責任者は？` | 2027年3月18日、水野葵 |
| `Cedarの緊急窓口と受付時間は？` | 内線771、平日07:30〜19:00 |
| `Lighthouseの保持期間と例外承認者は？` | 45日、品質管理責任者 |
| `PDF access codeは？` | ORANGE-4821 |

期待結果（完全一致項目）: 各回答に対応する事実と引用番号があり、「この回答の根拠」から正しい資料本文を開ける。

### RAG-03 チャンク境界（必須・P1）

`銀河スプーンに対応する復旧番号は？`と質問します。

期待結果: `RK-2049`を回答し、`05_long_chunk_boundary.md`の関連チャンクが根拠になる。チャンク一覧では複数チャンクとoverlapを確認できる。

### RAG-04 文脈追従（必須・P1）

順番に質問します。

1. `変更作業の手順を順番に教えて。`
2. `箇条書きでお願いします。`
3. `英訳して。`

期待結果: 1は「記録→確認→承認→実行」の順。2は同じ回答の箇条書き。3はその箇条書きの英訳。

### RAG-05 RAGモード（必須・P1）

同じ質問`Auroraの公開日は？`を各モードで試します。

- RAGなし: 保存資料を検索せず、根拠を表示しない
- RAG常時: 検索し、正しい根拠を表示する
- Agentic RAG: 検索必要と判断し、検索語とtraceを表示する

続いてAgentic RAGで`2+2は？`を質問します。

期待結果: 一般知識の質問では原則として資料検索不要と判断する。モデルが構造化判断に失敗した場合はフォールバックしたことがtraceで分かる。

### RAG-06 手動チャンクと検索設定（P1）

1. 「関連チャンク」で質問に一致する結果を開きます。
2. チャンク本文、番号、Embedding状態、検索されやすい語句を確認します。
3. 1件を次の回答用に選択します。
4. Keyword／Embeddingの重みと検索上限を変更して再検索します。

期待結果: 選択したチャンクだけを根拠として利用できる。設定変更が検索結果と診断表示へ反映される。

### RAG-07 不正素材（必須・P1）

`negative/empty.txt`と`negative/invalid-utf8.txt`を1件ずつ追加します。

期待結果: 読み込めない場合は対象ファイル名と理由が表示される。アプリ、Server、既存資料は利用可能なままである。

### RAG-08 クリア後の分離（必須・P0）

1. 資料をすべてクリアします。
2. 新しい会話を作ります。
3. `Project Auroraの責任者は誰？資料だけを根拠に答えて。`と質問します。

期待結果: 水野葵を保存資料由来の事実として回答せず、過去資料の引用も表示しない。

### RAG-09 クリア後の資料所持確認（必須・P0）

1. 資料を追加し、資料内容について1回以上会話します。
2. 資料をすべてクリアします。
3. 同じ会話で`資料を持ってる？`と質問します。
4. `Do you have any RAG documents?`とも質問します。

期待結果: 日本語では`いいえ。現在、読み込まれているRAG資料はありません。`、英語では`No. There are currently no RAG documents loaded.`と回答する。過去資料の内容や引用を回答へ含めない。

## 7. RAG評価

### EVAL-01 評価ケースとスイート（P1）

1. RAG-01の資料を再追加します。
2. RAG評価でRAG-02の4問をケースとして登録します。
3. 期待チャンクと期待要点を設定します。
4. `release-acceptance`スイートを作り、4件を追加します。
5. 手動評価を実行します。

期待結果: 検索順位、引用精度／再現率、期待要点、診断、処理時間が記録される。

### EVAL-02 マトリクスと書き出し（利用可能なProviderのみ・P2）

1. 2つ以上の評価環境を選択します。
2. マトリクス評価を実行します。
3. レポートをMarkdownへ書き出します。

期待結果: 環境ごとの結果が分離され、元のProviderへ戻る。Markdownに環境、合否、失敗理由が含まれる。

## 8. AIタスクとMCP

### AGENT-01 CLI検出（必須・P1）

「AIタスク」を開きます。

期待結果: Codex、Antigravity、Claude Codeが個別に表示される。導入済みは緑、未導入は利用不可理由が表示される。未導入CLIがあっても他の開始ボタンは使える。

### AGENT-02 読み取り専用（利用可能なCLIごと・P1）

作業フォルダに`test-materials/ai-task-workspace`を指定し、読み取り専用で次を実行します。

`README.mdを読み、seedを1行で答えてください。ファイルは変更しないでください。`

期待結果: `TASK-SEED-7319`を含む。ファイルの内容と更新日時が変わらない。

### AGENT-03 書き込みと同時実行（P1）

1. テスト素材フォルダを一時フォルダへコピーします。
2. 書き込みモードで`result.txtにAI_TASK_WRITE_OKと書いてください。`を実行します。
3. 完了前に別CLIでAGENT-02を開始します。

期待結果: 2タスクが別々に実行中として表示され、両方完了する。`result.txt`だけが期待内容で作成される。

### AGENT-04 キャンセルと権限（必須・P1）

1. 長いタスクを開始してキャンセルします。
2. 作業フォルダ書き込みで`/`を指定して開始を試みます。

期待結果: 1はキャンセル状態になる。2はルートフォルダを拒否し、プロセスを開始しない。

### MCP-01 Knowledge Tool（Codex MCP登録済みの場合・P2）

Codexから`searchKnowledge`で`銀河スプーン`を検索し、返ったIDを`getKnowledgeChunk`へ渡します。

期待結果: 読み取り専用で該当チャンクを返す。「MCP」画面の監査ログに入力概要、成否、時間、件数が残る。

## 9. Decision Model Lab

### DECISION-01 Ollaya（利用可能な場合・P1）

[decision-cases.md](test-materials/decision/decision-cases.md)の3ケースを`laya:multilingual`で実行します。

期待結果: choice、score、noulそれぞれが構造化結果を返し、confidence、処理時間、routingが履歴へ保存される。通常チャット履歴へ混ざらない。

### DECISION-02 評価とfallback（利用可能な場合・P2）

3ケースを評価へ登録し、confidence閾値を0.99にして実行します。

期待結果: accuracy、calibration error、平均遅延、fallback率が表示される。fallbackはシミュレーションであり、外部操作を実行しない。

### DECISION-03 Keychain（TypeSafe互換Providerを使える場合・P1）

1. API keyへテスト用キーを入力してKeychainへ保存します。
2. フィールドを消し、「Keychainから読み込む」を押します。
3. Keychainから削除します。
4. `Application Support/OnigiriHarness`内を検索します。

期待結果: 保存後に読み戻せ、削除後は戻らない。JSONファイルにキー文字列が存在しない。

## 10. OpenAI Compatibility APIとセキュリティ

### API-01 ModelsとChat Completions（必須・P1）

```sh
curl -sS http://127.0.0.1:18080/v1/models
curl -sS http://127.0.0.1:18080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"onigiri/current","messages":[{"role":"user","content":"API_OKとだけ答えて"}],"stream":false}'
```

期待結果: OpenAI互換の`object`、`data`または`choices`があり、回答が完了する。

### API-02 Streaming（必須・P1）

同じendpointへ`"stream":true`で送信します。

期待結果: `data:`イベントが複数届き、最後が`data: [DONE]`になる。

### SECURITY-01 既定の接続境界（必須・P0）

```sh
ONIGIRI_SERVER_HOST=0.0.0.0 \
  /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/OnigiriServer
```

期待結果（完全一致）: `ONIGIRI_ALLOW_EXTERNAL=1`とtokenが必要という理由で起動を拒否する。

### SECURITY-02 認証（任意・P1）

通常利用とは別ポート、一時データ領域でServerを起動し、tokenなしが401、正しいtokenが200になることを確認します。コマンド例は [SECURITY_TEST_COMMANDS.md](SECURITY_TEST_COMMANDS.md) を使います。

## 11. バックアップ、復元、再起動

### DATA-01 バックアップ／復元（必須・P0）

1. テスト会話、`release-test` Profile、RAG資料が存在する状態でバックアップを書き出します。
2. それぞれを1件以上削除します。
3. バックアップから復元します。
4. Onigiriを完全終了して再起動します。

期待結果: チェックサム検証を通過し、会話、Profile、資料、評価、AIタスク履歴がバックアップ時点へ戻る。`restore-rollbacks`に復元前コピーがある。

### DATA-02 無効なバックアップ（必須・P1）

普通のJSONファイルをバックアップとして選択します。

期待結果: 形式エラーになり、現在データは変化しない。

### DATA-03 Server再起動（必須・P0）

1. アプリ使用中にOnigiriServerを終了させます。
2. 接続エラーを確認します。
3. 左上の「再確認」を押します。

期待結果: 同梱Serverが再起動し、資料と履歴が復元され、チャットを再開できる。

## 12. UI目視テスト

UI項目はライト／ダーク外観の両方で確認します。スクリーンショット名を結果CSVの`evidence`へ記録します。

### UI-01 メイン画面サイズ（必須・P0）

次の各サイズで確認します。

- 最小付近: 980 × 620
- 標準: 1280 × 800
- 横長: 1600 × 900
- フルスクリーン

期待結果（目視）:

- 2カラム構成を維持する
- 左上のロゴ、アプリ名、モデル名、再確認が固定される
- 右上のモデル操作とRAG関連操作へ到達できる
- 入力欄と送信ボタンが画面外へ消えない
- Dividerをドラッグしても左右どちらかが操作不能にならない

### UI-02 RAGボタン横スクロール（必須・P1）

1. ウインドウ幅を狭め、右側のボタンを隠します。
2. `>`の表示と動作を確認します。
3. 右端まで移動し、`<`の表示と`>`の非表示を確認します。
4. 全ボタンが見える幅へ戻します。

期待結果: 隠れている方向にだけ矢印が表示され、全表示時は両方消える。常時表示や逆方向表示がない。

### UI-03 サブウインドウ（必須・P1）

次をすべて開きます。

- 資料一覧
- チャンク一覧
- 関連チャンク
- 検索設定
- 分割設定
- Profiles
- RAG評価
- AIタスク
- MCP
- Decision Lab
- データ管理

期待結果:

- 右上の`×`が見え、クリックで閉じる
- Escでも閉じられる
- 上部に不自然な大きな空白がない
- タイトル、操作ボタン、本文が重ならない
- リストと詳細ペインをスクロールできる

### UI-04 長い文字列（必須・P1）

長い会話名、長い資料名、長いモデルID、長い作業フォルダを表示します。

期待結果: 必要な場所では省略または折返しされ、ボタンを押し出さない。全文を選択または詳細画面で確認できる。

### UI-05 日本語IMEとEnter（必須・P0）

1. 入力ソースを日本語へ切り替え、未確定文字列を入力します。
2. Enterで変換候補を確定します。
3. Shift+Enterで改行します。
4. もう一度Enterを押します。

期待結果: 変換確定のEnterでは送信されず、Shift+Enterでは改行され、未確定文字列がない通常のEnterだけで送信される。

### UI-06 表示言語（必須・P1）

1. メニューバーの「Onigiri Harness」→「設定…」を開きます。
2. 表示言語をEnglishへ変更します。
3. メイン画面と主要サブウインドウを開きます。
4. 表示言語を日本語へ戻します。

期待結果: アプリを再起動せず主要ラベルが選択した言語へ切り替わり、選択は次回起動後も保持される。会話本文、資料本文、モデル名など利用者データは翻訳されない。

### UI-05 状態と操作フィードバック（P1）

生成中、取込中、評価中、AIタスク実行中、接続失敗時を確認します。

期待結果: 二重実行を防ぐdisabled状態、進行表示、成功／失敗理由が分かる。処理完了後に操作可能状態へ戻る。

### UI-06 キーボードとコピー（P2）

Tab移動、Return送信、Esc閉じる、入力コピー、回答コピー、テキスト選択を確認します。

期待結果: フォーカスが見え、コピー内容に欠落や余分なUI文字列がない。

## 13. 長時間・回帰テスト

### STRESS-01 連続チャット（P1）

同じ会話で短い質問を20回送り、その後に最初と最後の話題を確認します。

期待結果: アプリが応答し続け、コンテキスト上限超過時にもユーザー向けエラーまたは安全な履歴整理が働く。UIが著しく遅くならない。

### STRESS-02 資料操作（P2）

RAGフォルダの追加、検索、個別削除、再追加、全クリアを3周行います。

期待結果: 件数が整合し、削除済み資料が回答へ混入しない。

### STRESS-03 再起動（P1）

アプリを5回終了・起動し、毎回Provider、Profile、会話、資料件数を確認します。

期待結果: データが重複せず、Server接続が回復する。

## 14. 不具合記録方法

不合格時は次を残します。

1. テストID
2. 使用Provider／モデル／Profile
3. ウインドウサイズと外観
4. 再現手順
5. 期待結果と実際の結果
6. エラー全文
7. スクリーンショットまたは書き出したMarkdown
8. 再現率（例: 3/3）

優先度:

- **P0**: データ消失、起動不能、基本チャット不能、セキュリティ境界の破綻
- **P1**: 主要機能不能、誤った資料混入、操作不能なUI
- **P2**: 代替手段がある不具合、表示上の問題
- **P3**: 軽微な文言、整列、改善提案

## 15. テスト終了時

1. `acceptance-test-results.csv`に未実施理由を含めて記録します。
2. 最初に作成したバックアップを復元します。
3. Onigiriを完全終了して再起動します。
4. 会話、Profile、資料件数が試験前へ戻ったことを確認します。
5. P0／P1が0件ならParent Phase 5 / Sub-phase 5.2へ進みます。
