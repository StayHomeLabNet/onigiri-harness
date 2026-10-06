# Security test commands

通常利用中のServerと衝突しないよう、ポート`18083`と`/tmp/onigiri-security-test`を使います。

## 1. 未許可の外部待受

```sh
ONIGIRI_SERVER_HOST=0.0.0.0 \
  /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/OnigiriServer
```

`External binding requires...`で終了することを確認します。

## 2. 認証付き一時Server

別のターミナルで起動します。

```sh
env \
  ONIGIRI_SERVER_PORT=18083 \
  ONIGIRI_API_TOKEN=release-test-token \
  ONIGIRI_DATA_ROOT=/tmp/onigiri-security-test \
  ONIGIRI_KNOWLEDGE_STORE_URL=/tmp/onigiri-security-test/knowledge.json \
  ONIGIRI_CODEX_TASK_STORE_URL=/tmp/onigiri-security-test/codex-tasks.json \
  ONIGIRI_TOOL_AUDIT_STORE_URL=/tmp/onigiri-security-test/knowledge-tool-audit.json \
  ONIGIRI_DECISION_LAB_STORE_URL=/tmp/onigiri-security-test/decision-lab-runs.json \
  ONIGIRI_DECISION_EVALUATION_STORE_URL=/tmp/onigiri-security-test/decision-evaluation-reports.json \
  ONIGIRI_PROFILE_STORE_URL=/tmp/onigiri-security-test/product-profiles.json \
  /tmp/onigiri-harness-build/Onigiri.app/Contents/MacOS/OnigiriServer
```

認証なし:

```sh
curl -sS -o /tmp/onigiri-unauthorized.json -w '%{http_code}\n' \
  http://127.0.0.1:18083/health
cat /tmp/onigiri-unauthorized.json
```

期待値はHTTP `401`です。

認証あり:

```sh
curl -sS -o /tmp/onigiri-authorized.json -w '%{http_code}\n' \
  -H 'Authorization: Bearer release-test-token' \
  http://127.0.0.1:18083/health
cat /tmp/onigiri-authorized.json
```

期待値はHTTP `200`です。確認後、Server側のターミナルでControl-Cを押します。
