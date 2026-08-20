# 2026-08-21 HoverPocket AI-native AN3-A Review Follow-up

## 対象

- Worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3a`
- Branch: `codex/ai-native-an3-voice-foundation`
- 修正前head: `b34c1fc72fc4b8012e5cd467aa5047096ec7c846`
- PR: #19

## 新規review 3件

1. macOSのsystem recoveryが取消済みstartup Taskの参照を失い、非協調的なprobe / startとreplacementを重複させる。
2. Windows Shellのstaged recovery cancellationがVoice Coordinatorへ渡らず、古い復旧処理がclient破棄後にrestartを追加予約できる。
3. Windows transcriptの未知roleがrendererでSystem表示へフォールバックし、外部由来テキストがHostの発言に見える。

## 修正

- macOSは取消対象の`restartTask`をlocalへ保持し、`recoveryTask`が完了を待ってから旧adapter停止とreplacement schedulingへ進む。adapter unavailable / unexpected server requestでも同じdrain境界を使う。
- Windowsは`NotifySystemTransitionAsync`へShell所有tokenを渡し、restart取消、startup取消、client破棄、snapshot更新、restart予約の境界ごとに取消を再確認する。system transitionとfeature transitionを同じgateで直列化し、restart CTSもcaller tokenへ連結する。
- Windows transcript roleは`user` / `assistant` / `system`の有限集合だけを受理し、未知値はbufferへ追加しない。
- Windows Voice LaneのHost所有region labelは、初期HTMLを日本語とし、描画時は現在言語の`音声レーン` / `Voice Lane`へ更新する。

## 決定論的回帰

- macOS: 取消を無視してstart待機するadapterを使い、その処理が終わる前にreplacement factoryが呼ばれないこと、解放後にreplacementが1回だけ接続することを確認する。
- Windows: client破棄中の古いtransitionを取消して新しいtransitionを開始し、解放前は新transitionが待機し、解放後にreplacementが1回だけ接続することを確認する。
- Windows: `tool` roleのtranscriptを投入し、件数が増えないことを確認する。
- rendered WebViewは日本語 / 英語のregion label、Compact / Expanded本文、操作ラベルを同じ描画経路で確認する。
- 静的contractはShellからCoordinatorへのtoken伝播、restart token連結、両OSの新規回帰、Windows role allowlistとregion label localizationを必須化する。

## ローカル検証

- `swift build -Xswiftc -warnings-as-errors`: 成功
- `--verify-voice-foundation`: 成功
- `--verify-panel-layout`: 128件成功
- `--verify-capabilities`: 14 handler成功
- `--verify-pocket-surface`: 成功
- `--verify-pocket-app`: package / lifecycle / generation成功
- `--verify-broker`: 成功
- `--verify-timer`: 成功
- `python3 script/verify_voice_foundation.py`: 42件成功
- `python3 script/verify_pocket_contracts.py`: 13 schema / 60 fixture成功
- Windows JavaScript構文: 成功
- `git diff --check`: 成功

## PR CI / Security readback

- Source head: `edcadf9a0ad54d245f16995371fad5b98e3f2ee8`
- Windows: [32413198640](https://github.com/shotaro311/hover-pocket/actions/runs/32413198640) 成功。Release buildは警告0 / error 0、`VOICE_CASE_PASS dispose-transition-drain`、全Voice case、rendered WebViewを確認した。
- macOS: [32413198661](https://github.com/shotaro311/hover-pocket/actions/runs/32413198661) 成功。warnings-as-errors build、Voice verifier、Panel layout 128件を確認した。
- 3OS contract / byte compare: [32413198617](https://github.com/shotaro311/hover-pocket/actions/runs/32413198617) 成功。Ubuntu / macOS / Windowsで13 schema / 60 fixtureが成功し、reportはbyte-identicalだった。
- PR Router: [32413196048](https://github.com/shotaro311/hover-pocket/actions/runs/32413196048) 成功。
- Security scan `0830db5d-97ac-46ee-9c44-a2176551c462`: range `b3b83cb...70c6a56`、4 / 4、finding 0、sealed complete。
- Security scan `742c9674-ee8c-4755-aa78-26bd9fb1072a`: range `70c6a56...4b23892`、3 / 3、finding 0、sealed complete。
- Security scan `ea6dcbc6-8282-40aa-9bd6-5aeeb61ae830`: range `4b23892...edcadf9`、5 / 5、finding 0、sealed complete。
- PR #19は`CLEAN / MERGEABLE`、remote parity `0 / 0`、未解決review thread 0件を別経路でreadbackした。

## 最終表示・root分離hardening

- Source head `91a4f41e57032f0f6931fdaf60229716d757226d`で、括弧などの区切り直後にあるmacOS / Windows絶対pathも全体redactし、`https://example.com/path`と`and/or`は誤検出しない回帰を追加した。
- Unicode `Format` categoryを可視テキスト境界で除去し、U+202E / U+2066 / U+2069によるrole表示の並べ替えを防いだ。Windowsのavailabilityは`SignedOut` / `SchemaMismatch` / `CapabilityBlocked`をrendererと同じcamelCaseへ明示mappingした。
- `VoiceTranscriptEvent`へsanitized root session IDを必須追加し、現在rootと一致しない遅延eventを両OSruntimeで拒否する。root Aから遅延したeventとroot Bの正常eventをroot切替後に投入し、Bだけが残ることを検証した。
- Windows [32415595849](https://github.com/shotaro311/hover-pocket/actions/runs/32415595849)、macOS [32415595831](https://github.com/shotaro311/hover-pocket/actions/runs/32415595831)、3OS contract [32415595783](https://github.com/shotaro311/hover-pocket/actions/runs/32415595783)、Router [32415591319](https://github.com/shotaro311/hover-pocket/actions/runs/32415591319)は成功した。
- Security scan `b520fb75-bb1d-4bb8-bd4b-6c14d04b434b`は7 / 7、`c90ca20e-099c-4c0d-ae80-8d1a6d59fea4`は6 / 6を確認し、いずれもfinding 0、sealed complete。PR #19は未解決review 0、`CLEAN / MERGEABLE`、remote parity `0 / 0`である。

## 未完了gate

- PR #19の修正をPR #21、その後PR #22へ通常mergeで伝播する。
- PR #21 / #22のWindows、macOS、3OS contract CIとreviewを各headで再確認する。
- AN8 release-readbackの並行OS dispatchでWindows latestを独立解決し得る問題を修正し、release artifactとfeedを別経路で確認する。
