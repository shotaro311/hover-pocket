# HoverPocket AI-native AN3-B2 Final Safety Integration

## 結論

- Draft PR #21の最終安全修正をDraft PR #22へ通常mergeした。
- Calendar read / Timer startのCapability Broker境界と、Voice transcript秘匿、app-server teardown直列化が同じCoordinator上で共存することを確認した。
- 統合code headは`f77ac87daeb4978ab63e69ac24441f7509f53539`である。
- PR #22はDraftを維持する。現行Codexは正のBroker-only tool allowlistを独立検証できないため、本番Voiceはapp-server開始前にfail closedのままである。
- GitHub PRのmergeは行っていない。

## 統合内容

- base: `codex/ai-native-an3b-voice-runtime` head `d29849ace87bdf1db1b7f35d935cf5c5edde5fee`
- target: `codex/ai-native-an3b2-voice-capability-broker` premerge head `22f9c597de69cc9e7c894b7857cdbcd7cb9a962c`
- merge commit: `f77ac87daeb4978ab63e69ac24441f7509f53539`
- 競合は`progress/progress.md`だけである。実装ファイルはGitが自動統合した後、実コードとdeterministic verifierで意味を確認した。

維持した安全境界:

- `CodexVoiceSchemaContract.BrokerOnlyToolPolicyProductionApproved = false`
- Settings-only、既定OFF、取消可能なVoice Calendar grant
- Calendar結果からProvider内部`eventRef`を除外
- Timer writeのHost-owned native approval、同時prompt 1件、1分3件、cancel時reject
- active root以外のtool call拒否と、Voice停止後のtool result非送信
- Realtime cleanup taskとtransport teardown taskの分離
- crash / unexpected request / stale startup disconnect後の旧client破棄完了待ち
- current-root、user / assistant role、relative path、Bearer、OpenAI key、JSON credential fieldの表示前秘匿

## ローカル検証

成功:

- `swift build -Xswiftc -warnings-as-errors`
- `python3 script/verify_voice_foundation.py`: 42件
- `node --check windows/ui/js/app.js`
- `node --check windows/ui/js/i18n.js`
- `./script/build_and_run.sh --build-only`
- 署名付きapp `--verify-voice-foundation`
- 署名付きapp `--verify-panel-layout`: 128件
- 署名付きapp `--verify-capabilities`: 14 handlers
- 署名付きapp `--verify-broker`
- 署名付きapp `--verify-pocket-surface`: negative 15件
- 署名付きapp `--verify-pocket-app`: package negative 18件、lifecycle、generation
- 署名付きapp `--verify-timer`
- `python3 script/verify_pocket_contracts.py`: schema 13件、fixture 60件
- `codesign --verify --deep --strict dist/HoverPocket.app`
- `git diff --check`

このMacには.NET SDKがないため、Windows Release build、Voice native verifier、Settings、rendered WebView、既存Provider回帰はPR CIを受入根拠とした。

## PR CI readback

統合code head `f77ac87`で全7 check成功:

- [Verify Windows 32644395509](https://github.com/shotaro311/hover-pocket/actions/runs/32644395509)
- [Verify macOS Capabilities 32644395539](https://github.com/shotaro311/hover-pocket/actions/runs/32644395539)
- [Verify Pocket Contracts 32644395501](https://github.com/shotaro311/hover-pocket/actions/runs/32644395501)
- [Codex PR Router 32644394230](https://github.com/shotaro311/hover-pocket/actions/runs/32644394230)

readback:

- PR #22: Draft
- mergeability: `MERGEABLE / CLEAN`
- remote parity: `0 / 0`

### timeout verifierのflaky修正

docs-only head `608d8c0`のmacOS CIで、`Verify capability broker and text Today Focus`だけが`timeout_handler_cancelled`で失敗した。Windows、Voice、Capability、3OS contractは成功していた。

原因:

- timeout taskがhandler taskの開始前に勝つと、production Brokerはoperationを安全に取消して`CAPABILITY_TIMEOUT`を返す。
- 旧verifierはhandlerが未開始でも、handler内部で`CancellationError`を捕捉したことだけを必須にしていた。
- Swift Task cancellationは協調的であり、取消済みTaskがbody先頭の`Task.checkCancellation()`で終了する経路ではhandler内部のflagは立たない。

修正:

- production `CapabilityBroker`は変更していない。
- handlerが未開始なら安全な取消として受理する。
- handlerが開始済みなら`CancellationError`の捕捉を必須にする。
- どちらの経路でも`didReturn == false`を必須にし、timeout後の遅延結果を禁止する。

検証:

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-broker`: 50回連続PASS
- head `caa13c1695e0e9ad0c791a7da8e0b85caa0d76f3`で全7 CI成功
  - [Verify Windows 32645098065](https://github.com/shotaro311/hover-pocket/actions/runs/32645098065)
  - [Verify macOS Capabilities 32645098030](https://github.com/shotaro311/hover-pocket/actions/runs/32645098030)
  - [Verify Pocket Contracts 32645098063](https://github.com/shotaro311/hover-pocket/actions/runs/32645098063)
  - [Codex PR Router 32645096808](https://github.com/shotaro311/hover-pocket/actions/runs/32645096808)
- Security scan `3c86f9cc-972d-4ba0-876a-2c3c0fc9fbe1`: 1 / 1 surface、coverage complete、finding 0、sealed complete

## Security readback

- scan: `824fcceb-34c9-4312-a42f-155f29aeffc3`
- range: `22f9c597de69cc9e7c894b7857cdbcd7cb9a962c...f77ac87daeb4978ab63e69ac24441f7509f53539`
- review items: 4
- coverage surfaces: 5 / 5
- completeness: complete
- reportable finding: 0
- status: sealed complete
- report: `/private/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/codex-security-scans-0JCxLg/hover-menu-preview-ai-native-an3b2/f77ac87daeb4978ab63e69ac24441f7509f53539_20260823T140624Z_pkbq9fug/report.md`

## 未完了と次の順序

1. PR #22 docs-only headのCIとreview threadをreadbackする。
2. AN8 release-readback PR #23へ現在の安全修正を必要に応じて伝播する。
3. macOS / Windowsの配布feed、artifact、rollback、長期運用のreadback gateを閉じる。
4. 正のBroker-only tool allowlistを公式schemaとdelegated Realtime E2Eで確認できるまで、production Voiceを解禁しない。
5. GitHub PRのmergeは人手判断に残す。
