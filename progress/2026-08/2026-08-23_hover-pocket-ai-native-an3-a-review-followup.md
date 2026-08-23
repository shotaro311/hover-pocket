# 2026-08-23 HoverPocket AI-native AN3-A Final Review Hardening

## 対象

- Worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3a`
- Branch: `codex/ai-native-an3-voice-foundation`
- PR: [#19](https://github.com/shotaro311/hover-pocket/pull/19)
- 修正base: `b506557e13b45bd13d1f4a774a60a8a2314bfa33`
- source head: `5170115b7d1f3afcfaef1e38e643bce0b8c3a641`

## ChatGPT Pro Orchestrator回収

- route: 通常Pro。ユーザーのChatGPT Pro活用指定を優先した。
- role: `builder`
- 開始: `2026-08-23T21:23:45+09:00`
- 回収完了: `2026-08-23T21:31:16+09:00`
- transport記録: GPT-5.6 Sol / Pro、Oracle `0.17.2`、Node `v24.19.0`
- Project target: 検証済み。個別会話URLは記録されていない。
- UI上のmodel selection証拠: `unverified`。transport metadataはGPT-5.6 Solを記録しているが、画面上のモデル表示を独立確認した証拠とは扱わない。
- run: `/Users/shotaro/Documents/Codex/chatgpt-pro-orchestrator-runs/20260823-211957-pr-192filesystem-pathosvoice-uiwindows-transport-crashclient-teardownrestartpatch`
- delivery: `return-a6894e4ea4f650aae5178cea2c076919`
- Pro-owned: review修正設計、macOS / Windows実装、deterministic回帰、patch artifact作成。
- Codex-owned: receipt、base、hash、path検証、機械適用、ローカルbuild / test、Security scan、commit / push、PR / CI / review readback。
- GitHub capabilityはread-only、Proからの外部書き込みなし。local filesystem capabilityはfalse、artifactはinline deliveryである。
- 本文文字数とURL / domain数はcoding patch runの受入指標ではないため未集計。必要成果物とsource context、artifact hash、local / CI結果を正本にした。

## Artifact検証

- artifact: `changes.patch`
- base SHA: `b506557e13b45bd13d1f4a774a60a8a2314bfa33`
- size: 13,796 bytes
- SHA-256: `f7ee323511dfd498f5d5e819054d6359576e79989a99b21d41f5c404979af88d`
- Oracle response SHA-256: `9b5e3b5de0c0ca233346b5cc121e0a30c644a2ca092ee5c76d99235db7f8f07f`
- `git apply --check`: exact baseのclean worktreeで成功。
- actual changed pathは次の4件だけで、task packetのallowed path内だった。
  - `Sources/HoverPocket/App/VoiceFoundationVerificationCommand.swift`
  - `Sources/HoverPocket/Voice/VoiceFoundation.swift`
  - `windows/src/HoverPocket.Shell/Verification/VoiceFoundationVerifier.cs`
  - `windows/src/HoverPocket.Shell/Voice/CodexVoiceCoordinator.cs`
- Pro成果をCodexが別実装へ置き換える例外は使っていない。patchを機械適用し、必要な受入検証だけをCodexが担当した。

## 実装

### 相対filesystem path秘匿

- macOS / Windowsの`VoiceTextSafety`へ同じrelative path判定を追加した。
- `Sources/HoverPocket/App.swift`を`[redacted]`へ置換する。
- `https://example.com/Sources/HoverPocket/App.swift`、`and/or`、`input/output`は通常テキストとして保持する。
- 既存のabsolute path、secret marker、Unicode format control除去、scalar / event上限、decoded model再sanitizationは維持する。

### Windows transport teardown-before-restart

- crash / disconnect / stale unexpected requestで切り離したclientの非同期破棄TaskをCoordinatorが追跡する。
- restartはschedule時点で対象teardown Taskを固定し、完了後にだけreplacement clientを起動する。
- Initialize、Voice OFF、system transition、application disposeも保留teardownをdrainする。
- gated dispose fixtureで、破棄が保留中はfactory callが1回のまま、解放後に2回目のclientだけがReadyになることを確認する。

## ローカル検証

成功:

- `./script/build_and_run.sh --build-only`
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-voice-foundation`
  - `PASS voice-foundation verify: default-off inert, root scope, bounded redacted transcript, app-lifetime UI detach, compact/expanded geometry`
- `swift build -Xswiftc -warnings-as-errors`
- `git diff --check`

制約:

- ローカルMacには`dotnet`がなく、Windows Release build / Voice verifierはローカル実行できない。Windows GitHub Actionsを受入根拠にした。

## PR CI / review readback

- Router: [32639816930](https://github.com/shotaro311/hover-pocket/actions/runs/32639816930) 成功。
- 3OS deterministic contract / compare: [32639818928](https://github.com/shotaro311/hover-pocket/actions/runs/32639818928) 成功。
- Windows Verify: [32639818937](https://github.com/shotaro311/hover-pocket/actions/runs/32639818937) 成功。
- macOS Verify: [32639818967](https://github.com/shotaro311/hover-pocket/actions/runs/32639818967) 成功。
- GitHub review 2件へ修正根拠を返信して解決した。
- 全review thread: 60件。未解決: 0件。
- PR #19: Open / Ready、`CLEAN / MERGEABLE`。
- local / remote parity: `0 / 0`、worktree clean。

## Security diff scan

- scan ID: `c143d307-1abb-4c9b-b7ca-b69ab0066272`
- exact range: `b506557e13b45bd13d1f4a774a60a8a2314bfa33...5170115b7d1f3afcfaef1e38e643bce0b8c3a641`
- changed file: 4 / 4 review完了。
- coverage surface: 4 / 4 closed。
- completeness: complete。
- reportable finding: 0。
- status: sealed complete。
- measured token usage: total 2,401,293 / input 2,387,043 / cached input 2,305,024。coverageはcomplete。
- TAC advisory statusはコネクター未接続で取得不能だった。これは認可gateではなく、scanは通常どおり完了した。
- report: `/private/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/codex-security-scans-0JCxLg/hover-menu-preview-ai-native-an3a/5170115b7d1f3afcfaef1e38e643bce0b8c3a641_20260823T124142Z_zr2cbcyw/report.md`

## 残るgate

1. この進捗記録をcommit / pushし、docs-only headのCI、review thread、mergeability、remote parityを再確認する。
2. PR #18を人手で先にmergeする。PR #19も自動mergeしない。
3. PR #19の修正をPR #21へ通常mergeし、その後PR #21をPR #22へ通常mergeする。
4. PR #21 / #22の各headでWindows、macOS、3OS contract、review thread、mergeability、remote parityを再確認する。
5. AN8-B release transitionの実行・rollback・長期運用gateへ進む。
