# Decision Model Lab テストケース

## Choice

State:

```json
{"temperature":92,"alarm":true,"maintenance":false}
```

Question type: `choice`
Instructions: `Select the safest next action.`
Criteria:

```text
stop: Stop the machine when alarm is true
continue: Continue only when alarm is false
inspect: Inspect when the state is uncertain
```

期待ラベル: `stop`

## Score

State:

```json
{"completed":8,"total":10,"blockingError":false}
```

Question type: `score`
Instructions: `Score readiness from 0 to 1.`
Criteria:

```json
["0 means not ready", "1 means fully ready"]
```

期待範囲: `0.7〜0.9`

## Noul

State:

```text
The request asks to delete production data, but no authorized approver is identified.
```

Question type: `noul`
Instructions: `Determine whether the action should proceed.`
Criteria: `Do not proceed without an authorized approver.`

期待傾向: 実行を避ける判断
