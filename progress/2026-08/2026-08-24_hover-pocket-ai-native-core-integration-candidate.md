# HoverPocket AI-native Core Integration Candidate

## 結論

- AI-nativeの分岐実装を、通常mergeだけで1本の統合候補branchへまとめた。
- 統合候補headは`4e297b7`で、AN5-C runtime activation、AN3 Voice / Calendar / Timer、Controls Capability、AN8 release readbackを同時に含む。
- macOSではwarnings-as-errors buildと全主要verifierが成功した。WindowsはこのMacに.NET SDKがないため、Draft PRのCIを受入根拠にする。
- これはAN8完了ではない。ChatGPT ProのAN8-C workspace backup / export / restore成果物、実Windows端末、署名済み配布、長時間soak、実Voice runtimeの正のtool allowlistが未完了である。

## 統合元

| 対象 | exact head | 統合結果 |
| --- | --- | --- |
| AN5-C + AN3-A/B1/B2 stack | `3b5b068cece1d70e40cb0d54aaaf735c0c388793` | merge commit `1e02d1f` |
| Controls / approval presentation再統合 | `f857b971c7ac6f15cf697716a794a5be4b1af208` | merge commit `f61baa5` |
| AN8 release transition / readback | `91d17aaef735f50129d1547359db20142cc9b477` | merge commit `4e297b7` |

`2d8b89cf709860ad3f12782683b13841d1543161`がVoice stack headの祖先であること、Controls headとAN8 headが統合候補headの祖先であることを`git merge-base --is-ancestor`で確認した。

## 競合解決

- `progress/progress.md`は各分岐の履歴を両方残した。
- Windows `PanelBridgeController`は、Voice側の共有Broker早期生成を維持しながら、Sticky Notes Storeに結び付く`HostCapabilityApprovalPresentationResolver`を同じBrokerへ注入した。
- Windows `CapabilityBrokerVerifier`は、共有`VerifyConsole`出力、21 descriptor / 20 handler、Controls、承認表示、12件negative caseを同時に維持した。
- 競合解決後にSwift compileとBroker verifierを実行し、組み合わせが実行可能であることを確認した。

## ローカル検証

実行日: 2026-08-24、macOS

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `python3 script/verify_pocket_contracts.py`: 13 schema / 66 fixture、66件一致
- `python3 script/verify_voice_foundation.py`: 42件成功
- `python3 -m unittest script.tests.test_verify_release_readback`: 19件成功
- `bash -n script/verify_macos_release_transition.sh script/verify_published_macos.sh`: 成功
- `node --check windows/ui/js/app.js`: 成功
- `node --check windows/ui/settings/settings.js`: 成功
- `HoverPocket --verify-capabilities`: 21 descriptor、20 handler系統、主要Capability成功
- `HoverPocket --verify-broker`: Calculator、Controls、Sticky、Today Focus、Pocket App、承認表示、並行重複、negative 12件成功
- `HoverPocket --verify-pocket-app`: package、lifecycle、generation、negative 18件成功
- `HoverPocket --verify-pocket-surface`: 6 node、negative 15件成功
- `HoverPocket --verify-voice-foundation`: default-off、root scope、bounded redaction、app lifetime、compact / expanded geometry成功
- `HoverPocket --verify-timer`: lifecycle、storage isolation、draft migration、stopwatch、concurrency、layout成功
- `HoverPocket --verify-panel-layout`: 128件、4 sizeの互換性と永続化成功
- `git diff --check`: 成功
- `git status --porcelain`: 出力なし

## ChatGPT Pro AN8-C

- 正しいrunは`20260824-000623-hoverpocket-an8-cpocket-app-workspacebackup-export-restoredata-version-readbackmacoswindowschanges-patch`で、exact baseは`2d8b89cf709860ad3f12782683b13841d1543161`である。
- 旧`20260823-235944-...` runは送信前にsource context上限で失敗しており、成果物として扱わない。
- 正しいrunの自動回収通知を受信した場合だけ、delivery IDとstate hashを`claim-synthesis`で検証し、receipt、base、allowed path、artifact hashを確認してから隔離worktreeへ適用する。同一通知を再適用しない。

## 未完了ゲート

1. 正しいAN8-C Pro成果物のclaim、receipt検証、隔離適用、両OS contract検証
2. 統合候補Draft PRのWindows Release / native / rendered UI / contract byte比較CI
3. 実Windows端末でCodex、microphone、remote audio、Calendar / Timer Broker往復
4. Codex production VoiceでBrokerだけを許可する正のtool allowlist、または専用最小runtimeの採用
5. workspace backup / export / restore、旧workspace migration、破損・offline回帰
6. macOS notarization / SparkleとWindows Authenticode / Velopackの署名済み成果物readback
7. clean install、upgrade、downgrade、uninstall / reinstall、sleep / wake、長時間soak
8. deprecation window、migration tool、監査・receipt retention、ユーザーによる変更・削除

## 運用判断

- 統合候補はDraft PRのまま維持し、人手gateなしにmainへmergeしない。
- AI / Voiceはdefault-offを維持する。
- 未署名Windows betaを自動実行しない。
- Pro成果物は外部artifactであり、ローカルcompile・verifier・CI・配布後readbackを代替しない。
