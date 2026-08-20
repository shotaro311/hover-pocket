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
- Windowsは`NotifySystemTransitionAsync`へShell所有tokenを渡し、restart取消、startup取消、client破棄、snapshot更新、restart予約の境界ごとに取消を再確認する。
- Windows transcript roleは`user` / `assistant` / `system`の有限集合だけを受理し、未知値はbufferへ追加しない。

## 決定論的回帰

- macOS: 取消を無視してstart待機するadapterを使い、その処理が終わる前にreplacement factoryが呼ばれないこと、解放後にreplacementが1回だけ接続することを確認する。
- Windows: client破棄中の古いtransitionを取消して新しいtransitionを開始し、古い処理の解放後もfactory callが増えないことを確認する。
- Windows: `tool` roleのtranscriptを投入し、件数が増えないことを確認する。
- 静的contractはShellからCoordinatorへのtoken伝播、両OSの新規回帰、Windows role allowlistを必須化する。

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

## 未完了gate

- Windows C# Release build / native Voice verifierはMacに.NET SDKがないためPR CIで確認する。
- 修正commit / push後に、Windows、macOS、3OS contract / byte compare、PR Routerを確認する。
- exact修正差分のsecurity scanを完了する。
- 3件のreview threadへ検証根拠を返信し、resolve後に未解決0件を別経路でreadbackする。
- PR #19の修正をPR #21、その後PR #22へ通常mergeで伝播する。
