# Onigiri Harness 受入テスト実施報告

実施日: 2026-10-04（Pacific/Auckland）
対象: Parent Phase 0〜5.1b / Parent Phase 5, Sub-phase 5.2着手前
手順書: [ACCEPTANCE_TEST_PLAN.md](ACCEPTANCE_TEST_PLAN.md)
詳細結果: [acceptance-test-results.csv](test-materials/acceptance-test-results.csv)

## 判定

**Sub-phase 5.1bの最終手動受入は合格です。実UIで残っていたP0/P1のチャット、Profile、資料拒否、主要サブウインドウ、狭幅表示、5回再起動を完了し、確認中に見つかった4問題も修正しました。Sub-phase 5.2の配布作業へ進めます。**

| 結果 | 件数 |
| --- | ---: |
| PASS | 39 |
| PARTIAL | 5 |
| SKIPPED（現在の環境で利用不可） | 1 |
| NOT_RUN | 2 |
| 合計 | 47 |

自動テスト82件、アプリビルド、ad-hoc署名、APIスモーク7 endpointはすべて合格しています。継続試験ではApple Foundation Models、Ollama、Ollaya、Knowledge Tool、AIタスク同時実行、20回連続チャット、App/Serverの5回再起動を実機確認しました。残るPARTIAL/NOT_RUNはP2または追加品質観測であり、P0/P1のリリース阻害不具合はありません。

## 実施環境

- アプリ: `/tmp/onigiri-harness-build/Onigiri.app`
- Provider:
  - Ollama `granite4.1:8b`: 利用可、実チャット・RAG・20回連続試験を実施
  - Apple Foundation Models: 利用可。アプリUIと隔離Serverの互換APIで生成成功
  - LM Studio: 停止中
- Decision Model: Ollaya `laya:multilingual`、`laya:en`、`laya:latest`
- AIタスク: Codex CLI、Antigravity CLI利用可。Claude Code未導入
- 外観: ダーク/ライト、標準/狭幅/フルスクリーン
- 手動受入の隔離先: `/tmp/onigiri-acceptance-home`
- 隔離先の終了状態: 7会話 / 2資料 / 2チャンク / 0 Embedding
- ユーザー保存状態: 10資料 / 318チャンク / 0 Embedding（隔離試験では変更なし）
- 事前バックアップ: ユーザーが指定したローカル保存先の`Onigiri-PreAcceptance-2026-10-04.json`

## 今回までに合格した主な確認

- Swift Testing: **82 tests passed**
- アプリビルド、ad-hoc署名、APIスモーク: 合格
- Ollama Provider: `OLLAMA_OK`をStreamingで返却
- RAGフォルダ取込: TXT、Markdown、PDF、nestedを取込み、CSVを無視
- 基本RAG: Aurora、Cedar、Lighthouse、PDFの期待事実と引用を確認
- 会話追従: 「記録→確認→承認→実行」から箇条書き、英訳まで同じ内容を維持
- RAG disabled: 検索と引用を行わない
- Agentic RAG: 資料質問は`search`、`2+2`は`skipped`
- 手動チャンク: 指定したチャンクだけで`RK-2049`を回答
- 不正資料: 空本文と不正UTF-8相当を400で拒否し、Serverと既存資料を維持
- Knowledge Tool: `searchKnowledge`、`getKnowledgeChunk`、監査ログを実呼出し
- Decision Lab:
  - choice、score、noulを構造化結果として保存
  - 3ケース評価はaccuracy 1、completed 3/3
  - confidence閾値0.99で3件をfallbackへRouting
- AIタスク:
  - CodexとAntigravityを同時実行
  - Codex書込は一時フォルダへ`result.txt`だけを作成し、内容は`AI_TASK_WRITE_OK`
  - 両タスク終了コード0
- RAG評価: expected rank 1、retrieval recall 1、citation precision/recall 1、answer point coverage 1
- OpenAI Compatibility API: 非Streaming、SSE Streaming、`[DONE]`を確認
- 耐久: Ollamaで20回連続`chat.completion`を実行し、20/20成功
- 復旧: 115資料を全クリアし、旧資料非参照を確認後、事前バックアップから会話1件・Profile 2件・資料10件/318チャンク・Decision履歴1件を復元
- Decision履歴: 構造化結果と処理時間を再表示し、通常チャット履歴との分離を確認
- UI: 標準ダークとフルスクリーンで2カラム、固定ヘッダ、入力欄、サブウインドウの閉じるボタンを確認
- UI: ライトと狭幅を追加確認し、隠れたRAGボタンがある側だけ矢印を表示
- 入力操作: Return送信、Shift+Return改行、入力/出力コピー、Markdown書出しを確認
- Profile: `release-test`の保存、会話割当、指示適用、再起動復元を確認
- 実UI資料拒否: 空ファイルと不正UTF-8をファイル名付きで拒否し、既存資料を維持
- 再起動耐久: 隔離環境でApp/Serverを5回再起動し、health、Profile、会話、資料を毎回復元
- Apple Foundation Models: `2+2`へ`4`と正常応答し、SensitiveContentAnalysisML error 15は再発せず
- 追従変換: RAG常時の会話で「英訳して」を実行し、無関係な引用metadataを引き継がないことを確認
- Antigravity: 隔離した読み取り専用タスクで`TASK-SEED-7319`を返し、終了コード0で完了

## 検出済みで修正した不具合

1. zshの`path`変数上書きでスモークスクリプトが`curl`を見失う問題を修正。
2. 長い資料名が操作ボタンを押しつぶす問題を修正。
3. Codex CLIの`--approve-for-me`と明示的sandboxの競合を修正。
4. Antigravityの`agent_response.text_delta`を結果へ蓄積するよう修正。
5. Apple Foundation Modelsの変換用途に適したguardrail設定を使い、SensitiveContentAnalysisML失敗時は確認手順を含む診断メッセージへ変換。
6. Agentic RAGの再検索結果をprimary/retryの決定的なinterleaveへ変更し、primaryの最上位一致を保持。
7. 生成本文の引用番号を実際のmetadata indexへ正規化し、箇条書き・翻訳などの追従変換では新規検索と引用metadata付与を抑止。
8. Antigravity読み取り専用タスクをheadlessで完了できる引数へ修正し、plan modeとterminal sandboxを維持したままツール許可待ちを回避。
9. メッセージ入力をReturnで送信、Shift+Returnで改行するよう修正。
10. 「英訳して」などの追従変換は直前のassistant回答だけを変換元にし、名前・色・曜日・日付・数値などの事実を維持するよう修正。
11. Provider切替後のモデル再取得でProvider pickerがAppleへ戻る問題を修正。
12. BOMのない任意バイト列をUTF-16として誤読していた問題を修正し、UTF-16はBOM付きだけを許可。

## Sub-phase 5.1aで解消したRelease blocker

### 1. Apple Foundation Modelsの生成失敗

`SystemLanguageModel`のguardrail設定を変換用途へ合わせました。アプリUIと隔離Serverの両方で`2+2`へ`4`を返し、生の`com.apple.SensitiveContentAnalysisML error 15`は再発しませんでした。OS側で同系統の失敗が起きた場合も、Apple Intelligenceの言語・モデル取得・macOS再起動を案内するエラーを返します。

### 2. 多資料時のAgentic RAG再検索順位

primaryとretryをスコアだけで再ソートせず、primary最上位を保持する決定的なinterleaveへ変更しました。大量の一般語retry一致があっても、primaryの完全一致が最終Top Kから脱落しない回帰テストを追加しました。

### 3. 引用番号の整合性

本文内の無効な引用番号を利用可能なmetadata indexへ正規化します。複数資料で対応不能な番号は除去します。翻訳・箇条書きなど直前回答の変換依頼は検索を行わず、無関係な引用metadataを返しません。単体テストとApple Foundation Modelsの実会話で確認しました。

### 4. Antigravityの結果表示

headlessのplan modeでpermission promptを待ち続けていたことが原因でした。読み取り専用ではplan modeとterminal sandboxを維持しつつ、headless実行内の許可を自動承認します。隔離した`/tmp`資料で`TASK-SEED-7319`を取得し、終了コード0と具体的なresultを確認しました。

## 残る非阻害項目

1. **EVAL-02（P2）**: RAG評価マトリクスの実UI実行とMarkdown書出し。
2. **STRESS-02（P2）**: 大量資料時の検索・生成時間とメモリ使用量の継続計測。
3. **RAG-03**: 長いチャンク境界の通常生成品質を継続改善。明示チャンク選択では合格済み。
4. **AGENT-04 / DATA-02 / UI-05**: 自動テストで合格済みのキャンセル、破損復元拒否、進行表示について追加の実UI観測を行う。
5. **PRE-01**: LM StudioとClaude Codeを導入した環境で任意確認を行う。

隔離試験で作った合言葉会話と、修正前に誤取込した`invalid-utf8.txt`は、ユーザーの確認後に実UIで削除しました。ユーザーの本番保存領域には触れていません。

## 実行証跡

```text
swift test: 82 tests passed
build-app.sh: Built /tmp/onigiri-harness-build/Onigiri.app
codesign --verify --deep --strict: passed
acceptance smoke: 7/7 passed
Ollama provider: OLLAMA_OK
RAG folder import: 6 documents / 7 chunks, CSV ignored
Decision Lab: choice + score + noul completed
Decision evaluation: accuracy 1, completed 3/3, fallback 3/3 at threshold 0.99
RAG evaluation: expected rank 1, recall 1, citation precision/recall 1, answer coverage 1
Knowledge Tool: searchKnowledge + getKnowledgeChunk + audit completed
AI task concurrency: Codex completed, Antigravity completed, exit 0/0
AI task write: result.txt = AI_TASK_WRITE_OK
continuous chat: 20/20 passed
clear isolation: 0 documents / 0 chunks, no stale answer, 0 citations
backup restore: 1 conversation, 2 profiles, 10 documents / 318 chunks, 1 decision run
restore rollback: created
invalid documents: HTTP 400/400, Server and knowledge remained available
Apple FM UI + isolated API: response = 4, no SensitiveContentAnalysisML error 15
follow-up transform: response retained, citations = 0
Agentic RAG regression: primary top hit retained after retry merge
citation normalization regression: invalid marker aligned or removed
Antigravity isolated read-only task: TASK-SEED-7319, completed, exit 0
Return sends / Shift+Return inserts newline: passed in UI
follow-up translation: Blue Saturday.; list transform: - Blue Saturday.
provider refresh: Ollama selection retained after model reload
invalid UTF-8 UI rejection: filename and encoding guidance shown
appearance: dark/light + standard/narrow/fullscreen passed
RAG overflow arrows: only the direction with hidden controls is shown
profile restart: release-test and RELEASE_PROFILE restored
app/server restart: 5/5 passed with stable conversation/profile/knowledge hashes
manual cleanup: target conversation removed; invalid-utf8.txt removed; 2 documents / 2 chunks remain in isolated home
```
