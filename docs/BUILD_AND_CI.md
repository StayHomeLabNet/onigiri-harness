# 再現可能なビルドとCI

## Version

アプリのversionはリポジトリ直下の`VERSION`を唯一の入力源とします。`scripts/build-app.sh`が`CFBundleShortVersionString`へ反映します。build番号は`ONIGIRI_BUILD_NUMBER`で指定し、未指定時は`1`です。

## ローカル検証

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash scripts/check-repository.sh
swift test --scratch-path /tmp/onigiri-tests
ONIGIRI_BUILD_CONFIGURATION=release zsh scripts/package-app.sh
```

成果物は既定で`release/Onigiri-Harness-<version>-macOS-<architecture>-unsigned.zip`へ作成され、同じ場所にSHA-256ファイルを出力します。`unsigned`はDeveloper ID未署名という意味です。アプリバンドル自体にはローカル実行確認用のad-hoc署名を行います。

主な環境変数:

| 変数 | 既定値 | 用途 |
| --- | --- | --- |
| `ONIGIRI_BUILD_CONFIGURATION` | `debug`（package時は`release`） | Swift build構成 |
| `ONIGIRI_BUILD_DIR` | `/tmp/onigiri-harness-build` | Swift scratch pathとアプリ出力先 |
| `ONIGIRI_BUILD_NUMBER` | `1` | `CFBundleVersion` |
| `ONIGIRI_SIGN_IDENTITY` | `-` | コード署名identity |
| `ONIGIRI_ARTIFACT_OUTPUT_DIR` | `release` | ZIPとchecksumの出力先 |
| `ONIGIRI_ARTIFACT_QUALIFIER` | `unsigned` | 成果物名の署名状態 |

## GitHub Actions

`.github/workflows/ci.yml`はpush、Pull Request、手動実行で次を行います。

1. 追跡禁止ファイル、ローカル絶対パス、credential形式を検査する
2. GitleaksでGit履歴を検査する
3. macOS 26 ARM64とXcode 26.6で全テストを実行する
4. Release構成のアプリ、ZIP、SHA-256を生成して検証する
5. 未署名CI成果物を14日間保存する

CI成果物は配布用ではありません。Developer ID署名、公証、stapleを行う成果物はSub-phase 5.2cで作成します。

## 署名・公証済み配布物

Developer ID証明書とApple公証資格情報を準備した環境では、`scripts/release-app.sh`がReleaseビルド、Hardened Runtime付き署名、公証、ticketのstaple、Gatekeeper検証、ZIPとSHA-256作成を一続きで実行します。GitHub Actionsの手動workflowでも同じ処理を実行できます。

設定と実行方法は[署名・公証済みmacOS配布](SIGNED_DISTRIBUTION.md)を参照してください。
