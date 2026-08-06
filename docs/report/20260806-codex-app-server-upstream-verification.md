# Codex app-server 公式仕様の照合結果

- 確認日: 2026-08-06
- 対象: `openai/codex` `main` の `codex-rs/app-server/README.md`
- 目的: Codex Voice Laneの実装計画を、現在の公式app-server仕様と突き合わせる
- 結論: 基本方針は維持できる。ただし、Realtime version、schema追従、overload処理、初期化handshakeを実装条件へ追加する。

## 1. 確認できた公式仕様

### Transportとframing

- stdioは既定transportで、newline-delimited JSON（JSONL）を使う。
- JSON-RPC 2.0相当だが、wire上では`"jsonrpc":"2.0"` headerを省略する。
- tracing/logは`stderr`へ分離でき、`LOG_FORMAT=json`で1行1eventのJSON logにできる。
- request ingressが飽和した場合、error code `-32001`、message `Server overloaded; retry later.`を返す。clientはexponential backoffとjitterで再試行することが推奨されている。

### Schema

- `codex app-server generate-ts --out DIR`
- `codex app-server generate-json-schema --out DIR`

生成物は、実行したCodex version固有であり、そのversionと一致することが保証される。

HoverPocketはrepositoryへ固定schemaを正本として置かず、インストール済みCodexから生成したschemaをPhase 0と互換性診断の正本にする。

### Initialization

1 connectionにつき、最初に`initialize` requestを1回送る。そのresponse受信後に`initialized` notificationを送る。

`clientInfo`には安定した識別子を使う。

```json
{
  "method": "initialize",
  "id": 1,
  "params": {
    "clientInfo": {
      "name": "hover_pocket",
      "title": "HoverPocket",
      "version": "0.0.0"
    },
    "capabilities": {
      "experimentalApi": true
    }
  }
}
```

`clientInfo.name`はOpenAI Compliance Logs Platformでclient識別に使われるため、無作為な値やversionごとに変わる値を使用しない。

### Realtime

`thread/realtime/start`はexperimentalで、次を受け付ける。

- `outputModality`: `text`または`audio`
- optional `model` / `version`
- optional `realtimeStartInstructions` / `realtimeEndInstructions`
- optional WebRTC transport `{ "type": "webrtc", "sdp": "..." }`

answer SDPは`thread/realtime/sdp` notificationで返る。

versionの意味は現行公式READMEでは次のとおり。

- `v1`: legacy Bidi `conversation.handoff.*`
- `v2`: Realtime Voice API
- `v3`: V1 Codex Voice behaviorを維持しつつFrameless Bidi `delegation.*`を使用

重要な制約として、**現行仕様では`v2`はWebRTC非対応**と明記されている。

したがってHoverPocketは`v2 + WebRTC`を前提にしてはいけない。Phase 0では、ローカルCodexの生成schemaと実接続結果から、WebRTCで利用可能なversionを選ぶ。versionを省略した場合の既定値にも依存せず、検証済みversionをsession単位で明示する。

### Threadsとsubagents

- `thread/list`はexperimental client向けに`parentThreadId`または`ancestorThreadId` filterを持つ。
- 両filterは同時に使えない。
- deprecated `multiAgentMode`は無視され、proactive multi-agent behaviorはUltra reasoning effort側が担う。

## 2. 既存レビューへの反映

### 専用clientは引き続き必須

app-serverもUI bridgeもJSON系messageを使うが、既存`BridgeDispatcher`はapp内method dispatch用であり、app-server transportのclient責務を持たない。

`CodexAppServerClient`には最低限次を持たせる。

- JSONL stdout reader
- stderr reader
- request ID採番とpending request相関
- response / error / notificationの分離
- initialize → initialized handshake
- timeout / cancellation
- `-32001`に対するbounded exponential backoff + jitter
- malformed lineと未知notificationの安全な処理
- process exit時のpending request失敗化
- graceful shutdownとprocess tree cleanup
- installed Codex versionと生成schemaの記録

### Version compatibilityはschema-first

feature flagを有効にする前に、次を確認する。

1. `codex --version`
2. `generate-json-schema`
3. 必要method / field / notificationの存在
4. initialize成功
5. account状態
6. Realtime versionとWebRTCの実接続

methodやfieldが不足する場合は、Voice Laneだけをfail closedで無効化し、既存providerとHoverPocket本体は通常起動させる。

## 3. Phase 0で追加する検証項目

- [ ] `codex --version`を記録
- [ ] `generate-json-schema`を実行し、生成成功を確認
- [ ] `thread/realtime/start`と`thread/realtime/sdp`の存在を確認
- [ ] WebRTCで利用するversionを実測して固定
- [ ] `v2 + WebRTC`を選択しない
- [ ] initialize response後に`initialized` notificationを送る
- [ ] `-32001`をretryableとして分類する
- [ ] stdoutへprotocol以外の行が混入してもprocess全体を落とさない
- [ ] stderrをprotocolとしてparseしない
- [ ] `clientInfo.name = hover_pocket`を安定利用する

## 4. 公式資料

- `https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md`

実装時はこのURLだけでなく、対象PCにインストールされているCodex自身が生成したschemaを最終的な互換性の正本とする。
