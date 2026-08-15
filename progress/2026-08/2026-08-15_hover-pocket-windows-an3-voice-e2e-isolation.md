# HoverPocket Windows AN3 Voice E2E Isolation

## 目的と境界

- `feature/codex-voice-lane`のexact `2185b106126aaa526308afa48d70c1f34b75825a`を、専用clone `C:\Users\shotaro\code\shared\hover-pocket-an3-win-e2e`のbranch `codex/an3-windows-voice-e2e-isolation`で実装した。
- 既存3 worktree、dirty main、インストール済みWindows 0.2.7、実行中製品process、`%APPDATA%\HoverPocket`は変更・停止しない境界を維持した。
- 今回は安全基盤と決定的Verifierまでとし、E2E `Run`、手動GUI、Windows microphone privacy prompt、実マイク、remote audio、音声1往復は起動していない。

## 実装

- `--voice-e2e`と、system temp配下に事前作成された空・非reparseの`HoverPocketVoiceE2E-*` rootが両方あるDebugだけを隔離E2Eとして受理する。欠落、不正、非fresh rootは起動前に拒否し、Releaseは両overrideを無視して製品設定へ戻す。
- E2E専用のmutex、open-request event、safe-stop eventを追加した。build/run/readback/stop scriptはDebug exe path、明示flag、exact rootが一致するprocessだけを対象にし、製品processを停止・通知しない。
- `HoverPocketApplicationData`を保存先の正本にし、settings、AI audit、Sticky、Timer、Clipboard、Capability Broker、Voice workspace、Panel / Settings WebView2、diagnostics、receiptを隔離root配下へ集約した。Updater、Velopack / ARP installer連携、Google OAuth、startup registration、Calendar readをE2Eで無効にした。
- E2E初期値はAI-native ON、Voice ON、Compact、auto-listen OFF、Calendar read OFF、update/startup OFF、Clipboard private mode ONとした。
- `voice-e2e-receipt.json`は20 fieldの固定allowlistだけをUTF-8 JSONで`.tmp`へflush後atomic replaceする。transcript本文、音声、SDP、token、path、Provider data、PID、error本文は保存しない。
- WebView2 runtimeからmic acquired/stopped、remote track received/stopped、`audio.play()` success/failure/stopped、safe closeを型付きbridge eventとしてHostへ通知する。既存transport attach/detachもreceiptへ反映し、operation epochでclose後に完了した古い`getUserMedia` / SDP処理を破棄する。exact origin、表示中、ユーザー操作、8秒single-use permissionの既存境界は変更していない。
- `voice_e2e_windows.ps1`へ`Build / Run / Readback / Stop`を追加した。receipt本文のallowlistをReadbackとStopの両方で検査し、Stopは専用eventによるsafe shutdown後にtransport、app-server、mic、track、playbackのcurrent状態がfalseであることを要求する。隔離rootは証跡として残す。

## 検証済み

- Debug / Release `TreatWarningsAsErrors=true`: warning 0 / error 0。
- Windows deterministic Verifier 19 target: shell、display、ui、ui-model、sticky、clipboard、controls、calc、timer、calendar、settings、ailane、capabilities、broker、voice-lane-layout、codex-app-server-protocol、codex-voice-coordinator、voice-e2e-isolation、updaterが成功。
- Release `voice-e2e-isolation`、Verifier例外終了fixture、JS syntax 13件、PowerShell parse 5件、`voice_e2e_windows.ps1 -Action Build`、`git diff --check`が成功。
- 隔離VerifierはDebug flag/root、Release無効、製品と別IPC、全保存path、safe defaults、OAuth / updater遮断、receipt exact allowlist / redaction / atomic更新、playback成功・失敗、safe close current=false、feature-off無副作用、Web runtime event契約を検査する。
- rendered UI Verifierの動的stylesheet読込前に寸法を評価する揺れを再現し、Verifier専用visual settleを追加して全件を再実行した。

## 未完了gate

- `Run`で返るfresh rootとDebug exeをreadbackし、アプリ内Voiceボタンの明示クリックからWindows microphone privacy promptを開始する。
- mic acquired/current、WebRTC transport attached、remote audio track、playback success、user / assistant / complete transcript countによる音声1往復をsanitized receiptだけで確認する。
- Panel closeと`Stop`後にcurrent flagsとapp-server process presentがすべてfalse、対象Debug E2E process残存0であることを確認する。
- transcript本文、音声、SDP、token、path、Provider data、PIDは実機検証時も出力・保存しない。
