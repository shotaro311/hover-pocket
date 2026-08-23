# HoverPocket AI-native Core Capability Reintegration

## 結果

競合中のPR #13 / #15をそのままmergeせず、current `main` exact `a35b0ea8c224809ad4ff1bf1dc466882fc70169b`から隔離worktreeとbranch `codex/ai-native-core-capability-reintegration`を作り、Host-owned destructive approval presentationとControls Capabilityを再統合した。

この単位はAN8全体の完了ではない。Voice PR群、AN5-C、AN8-A / B、AN8-C backup / restore、署名済みWindows release gateは別PRのまま維持する。

## 再統合と追加hardening

- macOS / WindowsのRegistryへControls 6 Capabilityを追加し、既存UIと同じOS serviceをCapability handlerから利用する。
- writeは`controls.write`、idempotency key、Broker policy、`os_state` readbackを必須にする。
- volume setは実行前のmute状態を保持し、mute setはtoggleではなく明示boolを使う。
- brightness setは対象displayだけを再読込し、command acceptanceだけでは成功にしない。
- Windows DDC/CIは、read失敗時に残る楽観更新値と`Error`を検査し、`Error`があるfresh stateを`WriteVerified=true`にしない。
- macOS外部display音量は、通常の手操作UIだけ記憶値fallbackを維持し、Capability readbackでは実観測がない場合に失敗する。
- Windows media Capabilityは、direct UI用のdetached timeout fallbackを迂回し、`WindowsMediaSessionService.ExecuteAsync`のaccepted / confirmed / error結果を保持する。
- media title / sourceはUnicode scalar上限に加え、制御文字、format文字、改行を除去して可視テキストだけを返す。
- Sticky deleteの空titleは本文へfallbackし、意味のある表示ラベルが作れない場合は承認要求を作成せずfail closedにする。

## セキュリティreadback

Codex Security diff scan `8d09288e-c2a3-4c21-988d-1c96ca07ca71`を、frozen working-tree digest `codex-security-snapshot/v1:sha256:9c11f716dfaef7f40cc63b3fbebb7d12e1394ff9ce4d04b856ab12b94bda0849`へ実施した。

- preflight: 3 / 3 pass。
- changed source review: 30 / 30 complete。
- discovery candidates: 7。
- validation: 7 / 7。
- attack-path decision: 1 / 1。
- sealed finding: 0。

Windows DDC false readbackはコード上成立し、direct manual UIから到達する。ただし同じOSユーザーが自分のbrightnessを操作するself-only pathで、低権限・外部actorとの境界を越えないため、security policy上はignoreとなった。製品のreadback契約には違反するため、scan封印後に`fresh.Error`を成功条件から除外し、回帰を追加した。

次の機能公開前gateは次のとおり。

- `sticky.note.delete`をVoice / MCP / generated appへ許可する前に、承認表示時のnote version / content digestを実行直前に再照合する。
- Controls mediaをgeneric routeへ許可する前に、command acceptance、同一session identity、state changeの因果関係を両OSで固定する。
- Windows custom UIはhost-owned bundled WebViewのdirect Controls bridgeを継承せず、別origin / CSP / capability tokenへ分離する。
- automated retry前にWindows OS operation timeout後のlate effectを`unknown`として照合する。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功。
- `HoverPocket --verify-capabilities`: 成功、20 handler。
- `HoverPocket --verify-broker`: 成功、21 descriptor / 20 handler、negative 12。
- `HoverPocket --verify-pocket-surface`: 成功。
- `HoverPocket --verify-pocket-app`: package / lifecycle / generation成功。
- `python3 script/verify_pocket_contracts.py`: 13 schema / 64 fixture、2回成功。
- `git diff --check`: 成功。
- Windows .NET SDK: このMacには未導入。Windows build / Controls / Capability / Broker verifierはPR CIで確認する。

## 次の手順

1. 全差分をstageし、current main向けの1 commitとしてpushする。
2. Draft PRを作り、Windows / macOS / 3OS contract / PR Routerの全checkをreadbackする。
3. CI失敗があれば、このbranchだけで修正して再検証する。
4. generic Controls / sticky.delete公開前gateは、別の限定hardening単位で閉じる。
5. ChatGPT ProのAN8-C返却はdelivery claimとreceipt / artifact hash検証後だけ、別worktreeへ適用する。

Windows unsigned betaは明示承認なしに実行しない。
