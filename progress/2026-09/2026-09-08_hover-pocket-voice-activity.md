# 音声表示・音声による終了とToday Focus削除

2026-09-08 / ローカル実装・検証済み、本番638へ未反映。

ユーザーの画像に合わせ、macOSのマイク横の波形、ノッチ左右の表示、ノッチなし画面の表示を実装した。追加依頼の「会話を終了して」もCodexの音声ツールへ接続した。ローカル変更と非破壊の検証は依頼に含まれるため再確認せず実施した。

## 変更内容

- `VoiceActivityView.swift`で共通の表示を持つ。聞き取り中は小さく、応答中は大きく波形が動く。ミュート中は静止と斜線、Reduce Motionでも静止する。音声OFF・未接続では上端の会話表示を出さない。
- ノッチの実幅を中央に残し、左右54ptへ会話アイコンと波形を置く。ノッチなしでは上端中央108×33ptのバーへ収め、会話終了時は既存の小さな起点へ戻す。既存access windowを再利用し、状態変化時に位置と寸法を更新する。
- Codex WebRTCは受信音声の統計を160ms間隔で確認し、応答中／聞き取り中をruntimeへ伝える。状態が同じなら通知せず、終了時のタイマー停止と古い取得結果の破棄を行う。音声データや文字起こしは追加保存しない。参照: [W3C WebRTC Statistics](https://www.w3.org/TR/webrtc-stats/#dom-rtcinboundrtpstreamstats-audiolevel)。
- `voice_session_end`は現在のCodex音声セッションにだけ適用する。既存の終了処理を呼び、マイクと再生を停止する。確認ダイアログは出さず、機能の有効設定や実行済み操作・保存データを変更しない。旧セッションの要求が新しい会話を終了しない。
- Today Focusを標準Provider、Calendar内の集中ボタン、設定詳細、起動時のpackage/adapter生成から削除した。生成Pocket App用Providerは専用ファイルへ分離して維持した。既存データと契約検証で使うToday Focus fixtureは保持する。

## 検証

- Swift warnings-as-errors build: PASS。最終ローカルアプリはbuild639、Apple Development署名のDebug版。strict codesign: PASS。
- `--verify-voice-activity`: 27項目PASS。状態遷移、波形の時間変化と高さ、ノッチ有無の配置、削除済みProviderの選択復旧、音声終了ツール、引数・thread不一致、再送、旧要求からの新セッション保護を確認。
- `node script/verify_voice_activity.mjs`: PASS。無音、発声、短い間隔の平滑化、mute/unmute、audioLevel未提供時のenergy、統計取得失敗、終了中の取得完了とtimer停止を確認。
- Voice Foundation、Codex app-server foundation、App OS49、Pocket Tools platform78、panel layout112、Pocket App package/runtime/lifecycle/governance/backup: PASS。
- 共通v1契約72、v2契約46、Voice契約42: PASS。
- panel soak: 100回開閉、100回切り替え、5回復旧、3回アニメーションがPASS。window3→3、thread15→15、child0→0、RSS99.5→114.2MiB。
- Computer Useで実SwiftUIコンポーネントを表示し、ノッチ用・ノッチなし用・マイク横の3領域が異なるフレームで変化することをpixel比較した。ミュートの斜線と「一時停止中」、終了後の「開始前」を別途readbackした。

検証画面は接続状態をfixtureで与えている。実マイクの発話、実サービス応答音声との同期、物理的な複数ディスプレイ上の操作は未検証。画像だけを音声E2Eの成功として扱わない。検証用アプリは終了した。

## 成果物と配信境界

- ローカルアプリ: `dist/HoverPocket.app`。検証用bundle identifierで、本番インストールと区別している。
- [会話中](../evidence/2026-09-08-voice-activity/speaking-1.png) / [ミュート](../evidence/2026-09-08-voice-activity/muted.png)
- [検証ログ・readback](../evidence/2026-09-08-voice-activity/)
- `/Applications/HoverPocket.app`は638のままで、既知の公開版binary hashと一致。公証、GitHub公開、Windows実装・配信、本番インストール置換は実施していない。
