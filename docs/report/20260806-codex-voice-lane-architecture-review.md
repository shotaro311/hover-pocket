# Codex Voice Lane アーキテクチャレビュー

- レビュー日: 2026-08-06
- 対象: `docs/plan/20260806-codex-voice-lane-plan.md`
- 対象基準: `main` `bb8f06ab103dba594d62dbef94f3b6a19a60a8fa`
- 結論: **方向性は妥当。ただし、実装開始前に3件の設計ブロッカーを解消すること。**

---

## 1. 総評

HoverPocketの価値を「上端から0クリックで到達できる常駐サーフェス」と捉え、Codexの音声会話・進捗・承認をproviderとは別のlaneとして載せる方針は妥当である。

一方、現在の計画には、既存コードの実際の責務と一致していない箇所がある。特に、WebView2の寿命、app-serverとのプロトコル、パネル高さの扱いは、そのまま実装すると後半で作り直しになる可能性が高い。

以下の3件を実装前の必須修正とする。

---

## 2. 実装前ブロッカー

### B-1: 音声セッションの寿命を `PanelWindow` / WebView2 の寿命から分離する

**重大度: Critical**

現状、WebView2は `PanelWindow` が所有し、`PanelWindow.OnClosed` で破棄される。また、shell health checkはHWND異常時に `PanelWindow` を再生成する。WebView2 process failureも既存コードで検知される。

そのため、パネル内WebView2だけにRealtime接続、thread ID、transcript、子セッション状態を持たせると、次の場合に会話状態が失われる。

- panel windowの自動再生成
- WebView2 process failure
- display / DPI / resume復旧中の再構成
- 将来のUI reload

**必須方針**

アプリケーション寿命の `CodexVoiceCoordinator`（名称は任意）をC#側へ置き、最低でも次を所有させる。

- app-server processとJSON-RPC client
- account / capability / protocol compatibility状態
- root thread IDと子thread一覧
- voice session状態機械
- transcriptのメモリ上ring buffer
- reconnect policyと直近エラー
- mic / mute / hotkeyの論理状態

WebView2は次だけを担当する。

- `getUserMedia`
- `RTCPeerConnection`
- remote audio再生
- `AnalyserNode`による波形
- C# coordinatorとのtransportイベント交換

panelを通常の `Hide()` で閉じる場合はtransport継続を許可する。ただしpanel再生成またはWebView process failure時には、C# coordinatorがthreadとバックグラウンド作業を保持し、新しいWebView transportへ再接続できることを必須とする。

「パネル再生成中も音声を一瞬も切らさない」ことまで要件にする場合は、panelとは別の常駐WebView2 hostが必要になる。MVPでは、thread / 子エージェント継続を保証し、音声transportは自動再接続としてよい。

### B-2: `BridgeDispatcher` をapp-server JSON-RPC clientとして流用しない

**重大度: Critical**

既存の `BridgeDispatcher` はWebView UIとの内部bridgeであり、次の独自形式を使う。

- request IDは必須のstring
- `jsonrpc: "2.0"` フィールドなし
- 独自のresponse / error / event形式
- handler登録によるUI method dispatch

これはapp-serverのstdio JSON-RPC transportとは責務もframingも異なる。「構造が一対一なので流用できる」という前提は外す。

**必須方針**

専用の `CodexAppServerClient` を新設し、少なくとも次を実装する。

- process起動時のshell無効化
- stdin / stdout / stderrの分離
- stdoutのメッセージframing
- request ID採番とpending request相関
- response / error / notificationの別処理
- concurrent request
- request timeout / cancellation
- malformed JSONと未知notificationの安全な無視・記録
- initialize / capability negotiation
- protocol互換性不一致時のfail closed
- graceful shutdown、timeout後のprocess tree終了
- crash loopを防ぐ指数backoffと再起動上限

WebView向け `BridgeDispatcher` は、`codexVoice.start`、`codexVoice.mute`、`codexVoice.transportOffer` などのアプリ内部APIだけを受け持つ。

### B-3: lane高さを静的定数ではなく動的レイアウト状態にする

**重大度: Critical**

現在の `PanelSizeCatalog.AiLaneHeight` は静的な `const double = 0` であり、`DisplayLayoutService.CreateLayouts` はpanel sizeだけからtotal heightを決める。

計画では次の複数高さを要求している。

- compact: 64
- expanded: Small 190 / Medium 220 / Large 250
- feature disabled: 0

したがって「定数を変更するだけ」では実現できない。

**必須方針**

`VoiceLaneLayoutState` または同等の値を導入する。

- `disabled`
- `compact`
- `expanded`

`PanelSizeCatalog` は `PanelSize + VoiceLaneLayoutState` からmetricsを返す。次も同じmetricsを使う。

- `DisplayLayoutService.CreateLayouts`
- `PanelWindow` のWidth / Height / MinHeight / MaxHeight
- `HoverShellController.ResyncDisplayLayout`
- size変更とlane展開時のresize animation
- shell / display / UI verifier

provider領域の高さは固定し、lane分だけ下方向へ伸ばす設計は維持してよい。

---

## 3. 実装時の重要指摘

### H-1: Voice Laneはprovider registryへ登録しない

計画のStep 1にある `ProviderRegistry` の条件付き登録は削除する。Voice Laneはproviderと同時表示する横断UIであり、providerではない。

feature flagは `UserSettings` とvoice runtime compositionへ置く。無効時は次をすべて満たすこと。

- app-server processを起動しない
- WebViewにmicrophone permissionを要求しない
- global hotkeyを登録しない
- panel heightを増やさない
-UI bundle以外の常駐負荷を増やさない

### H-2: 旧 `AiLaneController` とCodex Voiceを別namespace / stateにする

既存の `Providers/AiLane/` は、Calendarの自然文解釈、承認、監査を行う別機能である。Codex Realtime Voiceのconnection / transcript / child thread状態と混ぜない。

推奨例:

- `CodexVoice/Runtime/`
- `CodexVoice/Transport/`
- `CodexVoice/Bridge/`
- Web method prefix: `codexVoice.*`

旧AI laneの承認カードやaudit最小化方針は、必要な部分だけ再利用する。

### H-3: microphone permissionを明示的に制限する

WebView2の `PermissionRequested` は無条件許可しない。

- 対象permissionがmicrophoneであること
- source originが `https://app.hoverpocket.local` であること
- userがVoice Laneを明示的に有効化・開始したこと
- 想定外permissionはdeny
- permission deniedを正常系としてUI表示

常時接続モードはMVPの既定から外し、実測後も明示的opt-inとする。

### H-4: billing / quota / session上限はStep 0完了まで未確定として扱う

計画にある「60分」「従量課金で高価」などは、一般のRealtime API仕様をCodex経由の契約・上限へそのまま当てはめない。

Step 0では、実際のCodex認証経路で次を記録する。

- start / readyまでの時間
- close reason
- rate limit snapshotの前後差
- sessionの実上限
-無音 / mute時の挙動

結果が確認できるまでは、UIの残り時間表示とローリング再接続時刻を固定しない。

### H-5: transcriptとログの保存境界を先に決める

既定ではtranscriptをディスクへ保存しない。

- UI表示用は件数または文字数上限付きring buffer
- audit logへprompt / transcript / model応答本文を書かない
- stderrやexceptionへ認証情報・SDP・会話本文を出さない
- 診断exportは明示操作時だけ、内容をユーザーに提示してから生成

### H-6: global hotkeyをライフサイクル管理する

- register失敗 / 競合をUIへ表示
-設定変更時に旧hotkeyを解除してから再登録
- panel再生成では重複登録しない
- app終了時に必ず解除
- feature無効時は登録しない

### H-7: voice runtimeを明示的な状態機械にする

最低限、次の状態を区別する。

- disabled
- codexMissing
- signedOut
- startingAppServer
- ready
- requestingPermission
- negotiating
- listening
- muted
- reconnecting
- stopping
- failedRecoverable
- failedBlocked

UI文言はこの状態から導出し、複数のboolを組み合わせて状態を表現しない。

---

## 4. 推奨実装順

### Phase 0: preflightと実測

リポジトリ本体へ音声UIを入れる前に、単体probeで次を確定する。

1. app-server起動・initialize
2. account / capability確認
3. voices取得
4. WebRTC SDP往復
5.接続レイテンシとclose reason
6. rate limit snapshot
7.作成threadのChatGPT / Codex Desktop側での可視性
8.非アクティブpanelでのmicrophone permission

結果を `docs/report/` と `progress/2026-08/` に残す。

### Phase 1: runtime基盤のみ

- `CodexAppServerClient`
- `CodexVoiceCoordinator`
- fake app-server / fake transport
-状態機械
- process crash / timeout / malformed JSON verifier

この段階では実microphoneを使わない。

### Phase 2: 最小vertical slice

到達点を次に限定する。

> featureを有効化 → panelを開く → 明示クリックで接続 → 1往復の音声 → transcript表示 → 切断

まだ子threadカード、常時接続、ローリング再接続、ChatGPTアプリ移動は入れない。

### Phase 3: panel lifecycleと操作性

- panel hide時mute
- panel再表示時resume
- panel / WebView再生成時reconnect
- global hotkey
- S / M / L × compact / expanded
- permission denied / device change / sleep-resume

### Phase 4: 子Codexセッション表示

- root / child threadの相関
-状態・経過時間・直近メッセージの最小表示
-移動手段はStep 0.5の実測結果で決める
- deep linkが無ければ `codex resume <threadId>` とthread ID copyを正式fallbackとする

### Phase 5: canary配布

- `win-canary` feedを安定版から分離
- feature既定off
- canary利用者だけopt-in
- crash / reconnect / permissionの診断を本文なしで収集

---

## 5. マージ条件

「feature flagがoffだから未完成でもmainへ入れてよい」ではなく、検証済みのvertical slice単位でマージする。

最低条件:

- feature off時の副作用が0
- Debug / Release warnings 0 / errors 0
-既存13 verifierがすべて成功
-新規voice verifierが成功
- app-server無し /未ログイン / protocol不一致が安全に無効化される
- panel再生成後にthread状態を失わない
- permission deniedでクラッシュしない
- S / M / L × compact / expandedの6レイアウトに収まる
- transcript /認証情報が永続ログへ出ない
- progress logと検証reportが更新される

---

## 6. レビュー運用

このDraft PRをCodex Voice Laneの継続レビュー面として使う。

各milestoneで実装commitをpushした後、次をPR本文またはコメントへ残す。

- 実装した到達点
-変更ファイル
-実行したコマンド
- verifier結果
-実機でのみ確認した項目
-未確認事項

レビューでは、最新headを基準に次の順で確認する。

1. 重大なライフサイクル / security / data-loss問題
2. 要件との一致
3. failure pathと回帰
4. test / verifierの十分性
5.保守性と細かな改善

実装コードが入るまではPRをDraftのまま維持する。Critical 3件を設計へ反映し、Phase 0の実測結果が記録されるまで、実装PRをready for reviewまたはmerge対象にしない。