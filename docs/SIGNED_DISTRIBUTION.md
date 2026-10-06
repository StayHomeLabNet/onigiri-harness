# 署名・公証済みmacOS配布

## 出力

`scripts/release-app.sh`は次の順に配布物を作成します。

1. `OnigiriServer`と`onigiri-mcp`をDeveloper ID Applicationで署名する
2. Onigiri.appをHardened Runtime付きで署名する
3. Appleのnotary serviceへZIPを送信して完了を待つ
4. 承認済みticketをアプリへstapleし、ticketを検証する
5. `codesign`とGatekeeperの`spctl`で最終検証する
6. `Onigiri-Harness-<version>-macOS-<arch>-notarized.zip`とSHA-256を作る

Onigiri Harnessは現時点でHardened Runtimeの例外を必要としません。`config/Onigiri.entitlements`は空のentitlementsとして管理し、JIT、unsigned executable memory、library validation無効化などの例外を付与しません。

## 必要なApple側の準備

- 有効なApple Developer Program membership
- 秘密鍵を含むDeveloper ID Application証明書
- App Store Connect API key、またはローカルKeychainに保存したnotarytool資格情報

このリポジトリへ証明書、秘密鍵、`.p12`、`.p8`、passwordを置かないでください。

## ローカルで署名・公証する

現在の署名identityを確認します。

```sh
security find-identity -v -p codesigning
```

Apple IDとapp-specific passwordを使う場合は、資格情報をKeychainへ一度保存します。コマンドはpasswordを対話的に要求します。

```sh
xcrun notarytool store-credentials onigiri-harness-notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

次に配布物を作ります。

```sh
ONIGIRI_SIGN_IDENTITY="Developer ID Application: YOUR NAME (TEAMID)" \
ONIGIRI_NOTARY_PROFILE="onigiri-harness-notary" \
ONIGIRI_BUILD_NUMBER=1 \
zsh scripts/release-app.sh
```

App Store Connect API keyをローカルで使う場合は、Keychain profileの代わりに`ONIGIRI_NOTARY_KEY_PATH`、`ONIGIRI_NOTARY_KEY_ID`、`ONIGIRI_NOTARY_ISSUER_ID`を設定します。

## GitHub Actionsで作る

PrivateリポジトリのGitHub Actions Secretsへ次の5項目を登録します。

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | 秘密鍵を含むDeveloper ID Application `.p12`のBase64 |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12`のpassword |
| `APPLE_NOTARY_KEY_P8_BASE64` | App Store Connect API key `.p8`のBase64 |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER_ID` | Issuer ID |

ローカルファイルの内容を画面に表示せずGitHub CLIへ渡す例です。

```sh
base64 -i DeveloperIDApplication.p12 | gh secret set MACOS_CERTIFICATE_P12_BASE64
gh secret set MACOS_CERTIFICATE_PASSWORD
base64 -i AuthKey_KEYID.p8 | gh secret set APPLE_NOTARY_KEY_P8_BASE64
gh secret set APPLE_NOTARY_KEY_ID
gh secret set APPLE_NOTARY_ISSUER_ID
```

登録後、手動workflowを実行します。

```sh
gh workflow run signed-distribution.yml
gh run watch
```

一時KeychainとAPI keyファイルはGitHub-hosted runnerの一時領域だけに作り、job終了時にKeychainを削除します。完成した署名・公証済みZIP、checksum、公証結果JSONはActions artifactとして14日間保存します。

## 別Macで受け入れ確認する

Actions artifactを別のApple Silicon Macへダウンロードし、Finderまたはブラウザ経由で得たZIPを展開して確認します。

```sh
shasum -a 256 -c Onigiri-Harness-*.zip.sha256
codesign --verify --deep --strict --verbose=2 Onigiri.app
xcrun stapler validate Onigiri.app
spctl --assess --type execute --verbose=4 Onigiri.app
open Onigiri.app
```

起動後は、Onigiri Serverへの接続、Apple Foundation Modelsでの最初の会話、資料追加とRAG検索を確認します。結果はリリース前受け入れテスト記録へ残します。
