# HoverPocket AI-native AN3-B3B Windows Voice E2E isolation

## 目的

- OpenAI Realtime BYOKのWindows実機検証を、本番の設定・資格情報・WebView2 profile・IPC・Calendar OAuth・Clipboard監視・更新処理から分離する。
- microphone、remote audio、transcript件数、Timer Capability Broker readback、終了後のmedia teardownとCredential Manager削除を、本文・音声・SDP・API keyを残さないsanitized receiptで確認する。

## 2026-08-24 実装

- Debug専用`--voice-e2e --voice-e2e-root <fresh-root>`を追加した。Release buildはE2E flagを拒否し、Debugもsystem temp配下の`HoverPocketVoiceE2E-*`、事前作成済み、空、non-reparse rootだけを受理する。
- 設定、Sticky、Timer、Clipboard、Capability Broker、Pocket App data、Panel / Settings WebView2、diagnostics、receiptを専用rootへ閉じた。OpenAI / Google OAuthのCredential Manager targetはroot digest由来のE2E専用名で、本番targetと一致しない。
- E2Eの既定はUpdater / startup / AI-native / Voice / Calendar accessをoff、Clipboard privateをon、Voice providerはOpenAI Realtime BYOKを事前選択、表示ProviderはTimerだけにした。Settingsから本番連携、Calendar、Controls、Clipboard、Codex app-server、AI-nativeを有効化できない。
- E2E専用mutex、show event、safe stop eventを追加し、本番instanceを停止・表示しない。E2EではVelopackとTray updaterを起動しない。
- WebRTCから`microphoneAcquired / Stopped`、remote audio track、playback success / failure / stopped、transport detach、safe closeをHostへ通知する。playback失敗を握りつぶさず、receiptのcurrent / ever flagへ反映する。
- receiptはallowlist済みboolean / count / safe enumだけをatomic保存する。transcript本文、session title、error、SDP、API key、path、PIDは保存しない。Timer toolの`status=succeeded`かつ`readback=verified`だけをboolean化する。終了時はmedia / transport / realtimeをfalse、Credential Manager削除後の`credentialCurrent=false`を固定する。
- `windows/script/voice_e2e_windows.ps1`へ`Build / Run / Readback / Stop`を追加した。Runはfresh rootを作成し、Settingsでテスト用API key保存、Voice有効化、明示mic clickを案内する。Stopは専用eventだけを送信し、残存process・media・transport・credentialをreceiptで拒否する。
- `--verify voice-e2e-isolation`へRelease拒否、fresh root、path / credential / IPC分離、安全な既定値、receipt allowlist / redaction / atomic write / shutdown、WebRTC event契約を固定した。

## ローカル検証

- `node --check windows/ui/js/app.js`: PASS
- `git diff --check`: PASS
- worktree / base parity: clean開始、`16090d7a86c81ab19d85018462814c7279bb8801`、`origin/codex/ai-native-an3b3-realtime-provider`との差`0 / 0`
- このMacには.NET SDKとPowerShellがないため、C# warnings-as-errors build、Debug isolation verifier、PowerShell parse、rendered WebView2はDraft PRのWindows CIを受入gateに残す。

## 未完了gate

- GPT-5.6 Sol Pro担当のmacOS Host-owned Realtime transport artifactをclaim / apply / verifyする。
- macOSとWindowsで同じtranscript event / session model契約を確定する。Windows receiptは件数を受け取れるが、現headのOpenAI coordinatorはまだtranscript eventをsnapshotへ反映しない。
- Windows実機で実API keyをE2E専用Credential Manager targetへ保存し、mic入力、remote audio一往復、Timer承認、Broker readback、Stop後のcredential削除をreadbackする。
- 実API key、transcript本文、音声、SDPはGit、progress、CI artifactへ保存しない。

## Draft PR CI follow-up

- Draft PR #37の初回Windows run `32722365200`はRelease / Debug build、Voice foundation、Voice E2E isolation、PowerShell構文まで成功した。rendered UIだけ、通常のUI verifier用temporary rootまでexternal integration無効として扱い、`clipboard.getState`を登録しなかったため失敗した。
- external integrationを無効化する境界を`IsIsolatedVoiceE2E`だけへ戻し、既存UI verifierのbridge surfaceを維持した。E2E専用rootのfail-closedは変更していない。
- 修正後run `32722634593`はRelease / Debug build、Settings、Voice foundation、Voice E2E isolation、PowerShell構文、Updater、署名contract、rendered WebView UIを含む全stepが成功した。Draft PR #37はcode head `b8b1a912d9f657fd0792740c39b39c66d127fac3`で`MERGEABLE / CLEAN`、review / comment 0件、remote parity `0 / 0`をreadbackした。
