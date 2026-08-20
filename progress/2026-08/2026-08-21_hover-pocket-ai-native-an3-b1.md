# 2026-08-21 HoverPocket AI-native AN3-B1 Windows Voice Runtime

## 状態

- branch: `codex/ai-native-an3b-voice-runtime`
- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-an3b`
- base: AN3-A PR #19 head `b34c1fc72fc4b8012e5cd467aa5047096ec7c846`
- status: 実装・ローカル検証・修正後exact Security scan済み。Windows Release / rendered WebView CI、実Windows Codex / microphone / WebRTC 1往復は未完了。

## 実装

- Windows Voiceをdefault-offのままproduction compositionへ接続した。Codex実体を絶対pathとSHA-256で固定し、experimental JSON schema、platform、`account/read`、`thread/realtime/listVoices`を通過した場合だけReadyにする。
- Panelの明示microphone clickから5秒・1回限りのgesture leaseを発行する。exact origin `https://app.hoverpocket.local`、可視Panel、WebView2 user activation、Microphoneの全条件を満たす場合だけ許可し、permissionをprofileへ保存しない。
- WebView2でgetUserMedia、WebRTC offer / answer、remote audio、input / output mute、明示終了時のpeer / data channel / media cleanupを実装した。SDPはcurrent root threadとconnection generationへ束縛し、262,144 bytes上限をHost / WebView双方で検証する。
- Codex root threadはephemeral、read-only、approval never、tool / shell / file / MCP / connector禁止で作成する。AN3-B1ではCapability BrokerやMCPをVoiceへ接続しない。
- transcriptは既存memory-only bounded bufferへ取り込み、partial / finalをroot scopeで更新する。raw SDP / audioはSettings、監査、diskへ保存しない。
- Codex app-serverとschema probeをWindows kill-on-close Job Objectへ所属させ、disable、crash、終了時に子processを残さない。
- 初回Security scanで再現した2件を修正した。getUserMedia成功後はPeerConnection等の構築前から取得streamをcleanup対象にし、途中失敗でも全trackを停止する。明示終了時はCodex / app-serverの応答を待たず、先にlocal track、peer、data channel、audioを停止する。

## 検証

- `python3 script/verify_voice_foundation.py`: PASS。42 geometry / stateケース、exact-origin microphone、schema / account / voice gate、fenced Realtime契約を確認。
- Windows UI JavaScript 3ファイルのsyntax check: PASS。
- fake app-server verifierへaccount / voices / thread / Realtime / SDP / transcript / remote-audio activity / stopとforeign・oversize SDP回帰を追加した。
- rendered WebView verifierへfake permission / WebRTC offer-answer / cleanup harnessを追加した。Windows CIで実行予定。
- macOS `swift build -Xswiftc -warnings-as-errors`: PASS。
- macOS Voice foundation、Panel layout 128件、Broker、Pocket Surface、Pocket App、Timer: PASS。
- macOS Capability 14 handler、共通Pocket contract 13 schema / 60 fixture: PASS。
- exact-code JavaScript lifecycle harness: PASS。`initializationFailureStopsTrack=true`、`initializationFailureNotifiesHost=true`、`endStopsBeforeNativeResponse=true`を確認した。
- 初回Security scan `2ab97a76-4999-41f5-9413-04f00df8fdf7`: 14 / 14 review、low finding 2件。両方を上記local-first cleanupへ修正した。
- 修正後Security scan `878927ec-12f6-49ea-a571-ed47182f1692`: 14 / 14 review、reportable finding 0件、sealed complete。content digestは`codex-security-snapshot/v1:sha256:38de43dbe33b5497bbc44b34e3ebcb9b307aebdaf9e725a834c49286fe259538`。
- `git diff --check`: PASS。
- このMacには`dotnet`がないため、Windows C# Release buildとnative verifierはPR CIを最終gateにする。

## 未完了

- Windows CIのRelease build、Voice verifier、Settings、rendered WebView、既存全回帰。
- Windows実機でインストール済みCodex path / version / generated schema、account、voice一覧、microphone allow / deny、WebRTC remote audio、1往復、mute / stop、process cleanupをreadbackする。
- 外部Codex CLIの初回trust anchorをpublisher signature、明示path enrollment、approved digestのどれで束縛するか確定する。Process.StartからJob assignmentまでに即時生成されたdescendantが残らないこともWindows adversarial harnessで確認する。
- AN3-B2のCalendar / Timer Capability Broker接続と書き込み承認・readback。
