# HoverPocket Voice設定・非表示継続の実装ログ

## 実施内容

- `AppSettings`へVoiceのパネル非表示継続と操作確認の永続設定を追加した。既定値はそれぞれOFF / ON。
- SettingsのVoice Lane節へ日本語 / 英語Toggleと、確認OFFの対象範囲・Broker境界・将来拡張禁止を説明する文言を追加した。
- `VoiceLaneRuntime`のdetachをconnectedかつunmutedのopt-inだけ継続する契約へ更新した。設定OFFへの変更はhidden中に即時muteし、session生成・再生成は行わない。
- connecting中のdetachはadapterへpanel非表示を伝播してpermission leaseを失効し、遅れて開始成功しても`disconnected / idle / muted`へ戻す。
- BYOK / Codex共通の`OpenAIRealtimeMacOSCapabilityRuntime`へMainActor settings closureを渡し、approval開始時に一度snapshotする。native presenter省略は現在の5種類だけで、Brokerの承認・実行・readback・auditと既存Coordinatorのsingle-flight / Timer rate limitを維持した。
- 確認OFFの自動承認はUUID reservationをBroker実行とreadback完了まで保持する。同時writeは`approval_busy`、実行途中cancelは`session_cancelled`となり、解放後の次writeが成功することを決定論的に検証した。
- Codex embedded WebRTC JSのmute stateをmic trackとremote audioへ適用し、遅延remote trackと新規sessionの状態初期化をNode VMで検証した。
- requirementsへ既定mute / opt-in継続、既定ON / allowlistだけの確認OFF、Settings項目を追記した。

## 検証

- `swift build -Xswiftc -warnings-as-errors`: PASS
- `swift build -c release -Xswiftc -warnings-as-errors`: PASS
- `.build/debug/HoverPocket --verify-voice-foundation`: PASS
- `python3 script/verify_voice_foundation.py`: PASS
- `.build/debug/HoverPocket --verify-capabilities`: PASS（21 handlers）
- `.build/debug/HoverPocket --verify-broker`: PASS（22 descriptors / 21 handlers）
- `.build/debug/HoverPocket --verify-voice-e2e-isolation`: PASS
- `.build/debug/HoverPocket --verify-codex-app-server-realtime`: PASS（ChatGPT account、19 voices、ephemeral thread、SDP / WebRTC、teardown）
- `git diff --check`: PASS

## 独立レビュー

- 初回P1はconnecting中detachのstate / permission境界と、確認OFF時のreservation範囲だった。P2の要件文と実行途中cancel検証を含めて修正した。
- 最終判定はP0 / P1 / P2すべて0件。
- 自動承認時だけの`scheduling yield` 1回を除き、追加I/O、polling、再接続はなく、通常の逐次tool chainとVoice hot pathに有意な性能低下はない。

## 署名済みテスト版

- version / build: `0.1.0 (629)`
- bundle ID: `local.codex.hover-pocket`
- notary submission: `3b9a9f55-4e61-4ff7-92bc-c6e9c471fa49`
- notary status: `Accepted`
- Gatekeeper: `Notarized Developer ID`
- ZIP: `dist/releases/HoverPocket-0.1.0-629.zip`
- ZIP SHA-256: `627ad8d7d833221757f860946f3aca5f54506b716e15f3a13e1c0ba7044a1f42`
- 起動process: PID `52719`、`dist/HoverPocket.app/Contents/MacOS/HoverPocket`

## 未完了ゲート

- build 629で、パネルを閉じても音声継続ON時に実マイクとremote audioが継続し、再hover後に同一sessionが残ることをユーザーが確認する。
- Voice操作確認OFF時に、Sticky追加、明るさ・音量変更、Timer開始、Calendar access有効時のCalendar作成がnative dialogなしで実行・readbackされることをユーザーが確認する。
- GitHub Release、公開appcast、PR mergeは行わない。
