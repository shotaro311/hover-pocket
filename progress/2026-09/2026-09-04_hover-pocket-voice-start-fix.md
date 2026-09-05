# HoverPocket Codex Voice開始失敗の修正

## 対象

- worktree: `/Users/shotaro/code/share/hover-menu-preview-ai-native-final-integration`
- branch: `codex/ai-native-core-ga-final-integration`
- base HEAD: `38ec6f308bff55d44b57a26938857d061b5e0680`
- 配信状態: 未公開。GitHub Releaseと公開appcastは変更していない。

## 原因

- Codex app-serverの非物理Realtime検証は、ChatGPT account、19 voices、ephemeral thread、SDP、WebRTC、teardownまで成功した。
- 実環境ではmacOS WebViewの`getUserMedia`がCoreAudio入力を開始できない場合があった。既定入力はUSB接続のDJI MIC MINIで、CoreAudio HALの失敗ログを確認した。
- transportは具体的なマイクエラーをruntime hostへ報告していたが、開始continuationが先にgeneric `transportClosed`で終了し、`VoiceFoundation`が`voice_start_failed`へ上書きしていた。このためUIから原因を判断できなかった。
- stop / detach後にpendingのマイク取得が遅れて完了または失敗すると、古いoperationが後続candidateへ進むraceもあった。

## 変更

- `VoiceSessionStartFailure`を導入し、Codex WebRTC / runtime host / OpenAI Realtimeの固定safe error codeを開始元まで保持した。
- UIへpermission、deviceなし、device unreadable、constraints、WebRTC timeoutなどの日本語メッセージを追加した。
- Codex WebViewのマイク取得を最大4回へ限定した。
  - constraints付きdefaultを最初に使用する。
  - `OverconstrainedError`の場合だけplain defaultを使用する。
  - `NotReadableError`またはconstraints失敗だけを代替device探索の対象にする。
  - `NotAllowedError`、`NotFoundError`、不明エラーは即時停止する。
  - default / communicationsと同一groupの実deviceを除外し、group単位で重複を除く。
- operation epochを各await前後で確認し、停止済みoperationのlate streamは即時停止する。late rejectでも列挙や第2captureへ進まない。
- 最初のpermission callbackだけを明示操作から5秒以内に限定し、同一開始operationの後続候補は合計4回まで許可する。stop、detach、timeout、success、failureでleaseを破棄する。
- ProviderやOpenAI APIへの自動fallback、無限retry、polling、通常Hover経路の追加I/Oは追加していない。

## 実装と独立レビュー

- 実装担当: Luna Max subagent。
- 独立レビュー担当: 別subagent。
- 初回レビューで検出した、停止後race、default / group重複、5秒leaseの過剰適用、terminal error再試行、source文字列だけのテストを修正した。
- 最終レビューではP1 / P2を含む新規findingは0件。正常取得時の追加列挙、polling、通常Hover経路の性能低下も認めなかった。

## 自動検証

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift build -c release -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-voice-foundation`: PASS
- `python3 script/verify_voice_foundation.py`: PASS
- `.build/debug/HoverPocket --verify-codex-app-server-realtime`: PASS
- `git diff --check`: PASS
- Node VMはcleanup後のlate successとlate `NotReadableError`を検証し、late rejectではcapture 1回、failure通知0回、`enumerateDevices` 0回を固定した。

## 署名済みテスト版

- version / build: `0.1.0 (628)`
- bundle ID: `local.codex.hover-pocket`
- notary submission: `c4a78c35-ae53-43bc-b990-e1a0cad84e9a`
- notary status: `Accepted`
- Gatekeeper: `Notarized Developer ID`
- ZIP: `dist/releases/HoverPocket-0.1.0-628.zip`
- ZIP SHA-256: `7d86d140e9b8781361a0a60bc40aee11b97841d16f7f2f580e462957ac0cc500`
- 起動process: PID `42572`、`dist/HoverPocket.app/Contents/MacOS/HoverPocket`

## 実機確認

- ユーザーがbuild 628で実マイク入力、assistant応答、remote audio、Sticky Notes追加、明るさ変更、音量変更を確認し、すべて正常に動作した。
- パネル非表示時の音声継続とVoice操作確認の設定は、後続のbuild 629へ追加した。
- GitHub Release、macOS appcast、PR mergeは行っていない。
