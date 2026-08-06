# Codex Voice Lane 実装計画

- 作成日: 2026-08-06
- ブランチ: `feature/codex-voice-lane`
- 状態: **計画のみ。実装コードは未着手**

---

## 0. このブランチ / worktree の目的

HoverPocket に **Codex の realtime voice mode（GPT ライブボイス）を「上端ホバーで即座に会話できるレーン」として搭載する**ための、
実装専用の作業領域である。

worktree を分ける理由は次の2点。

1. `main` のワークツリーを占有しないため、**公開中の Windows 0.2.5 に対する修正やアップデート配信を並行して継続できる**。
2. この機能は Codex の experimental API に依存しており、頓挫の可能性がある。
   ブランチごと破棄しても `main` に痕跡が残らない状態を保つ。

このドキュメントは、実装着手前に**設計の妥当性を第三者レビューに掛けるための自己完結の資料**である。
本文中の「検証済み」と書かれた事項は、すべて開発機（Windows 11 / codex-cli 0.144.3）で実際に実行して確認したもの。

### レビューで特に見てほしい観点

1. **アーキテクチャの選択**: WebView2 に `RTCPeerConnection` を持たせ、C# は app-server の JSON-RPC 中継に徹する構成が妥当か。
2. **ライフサイクル設計**: パネル（ホバーで開閉する UI）の表示状態と、音声セッション／バックグラウンド作業の寿命を分離する設計が破綻していないか。
3. **experimental API への依存**: Codex 側のプロトコル変更に対する防御が十分か。
4. **未解決事項（第9章）**: 特に「子 Codex セッションへの移動」の落とし所。
5. **レイアウト**: 幅 520〜680px という制約下で、要求された情報量を破綻なく収められているか。

---

## 1. 背景と狙い

HoverPocket は、画面上端へマウスを重ねるだけでユーティリティを取り出せる常駐アプリである
（macOS / Windows。Windows は公開ベータ 0.2.5）。

AI エージェントが OS やアプリの操作を担い、API はエージェントが使う前提になっていく流れの中で、
希少になるのは**アプリの UI ではなく人間の注意と承認**である。エージェントは非同期・ヘッドレスで、
複数マシンにまたがって動く。そこで壊れるのは次の3点。

- エージェントが破壊的操作の手前で止まり、人間がターミナルを見に行くまで待たされる
- 完了報告がログに埋もれる
- 「今エージェントが何をしているか」を常時把握する場所がない

HoverPocket の本質的な資産は電卓やタイマーではなく、**0クリックで到達できる常駐サーフェス**である。
ここを「声で頼む → 裏で Codex が走る → 進捗と成果物が同じ場所に返る」の受け皿にする。

既存の 6 provider（Controls / Calculator / Calendar / Clipboard / Sticky Notes / Timer）は変更しない。
安定版利用者には既定で一切見えない状態で開発を進める。

---

## 2. 検証済みの事実

開発機で実際に `codex app-server` へ JSON-RPC を送って確認した結果。

| 事項 | 結果 |
|---|---|
| Codex CLI | `codex-cli 0.144.3` |
| 認証状態 | `account/read` → `planType: "prolite"`。ChatGPT サブスクリプション認証であり、API キーではない |
| **realtime の稼働実績** | `$CODEX_HOME/realtime-voice-continuity.json` が **2026-08-04 更新・7スレッド分**存在。**現アカウントで realtime voice が既に動いている** |
| realtime API 到達性 | `thread/realtime/listVoices` が実データを返す（v1 9音声 / v2 10音声） |
| ゲート条件 | `initialize` の `capabilities.experimentalApi: true` のみ。付けない場合は `requires experimentalApi capability` で拒否される。`realtime_conversation` feature flag（`under development` / 既定 false）は**不要** |
| WebRTC 経路 | `thread/realtime/start` に `transport: {type:"webrtc", sdp}` を渡す。answer SDP は `thread/realtime/sdp` 通知で返る。公式仕様に「ブラウザまたは WebView が `RTCPeerConnection` を所有する場合」の用途と明記されている |
| 課金経路 | config キーに `experimental_realtime_webrtc_call_base_url` が存在し、接続先は Codex バックエンド。platform.openai.com の Realtime API を直接叩く構造ではない |
| 会話テキスト | `thread/realtime/transcript/delta` `{threadId, role, delta}` と `transcript/done` |
| 子エージェント | ThreadItem に `senderThreadId` / `receiverThreadIds` / `agentsStates`（threadId → CollabAgentState）/ `tool` / `status` / `model`。上流では `collabToolCall`（`spawn_agent` / `send_input` / `resume_agent` / `wait` / `close_agent`） |
| 子孫スレッドの列挙 | `thread/list` に `ancestorThreadId`（要 experimentalApi） |
| 認証フロー | `account/login/start`（`chatgpt` / `chatgptDeviceCode` / `apiKey`）、`account/login/completed` 通知、`account/logout`、`account/read`、`account/rateLimits/read`。**Codex 側が OAuth とトークン更新を所有するため、自前 OAuth 実装は不要** |
| セッション上限 | Realtime API は現行 60 分（15分 → 30分 → 60分と延長されてきた）。上限到達で切断されるため再接続が必要 |
| セッションの所在 | `sourceKind` は `cli` / `desktop` / `vscode` の3種のみ。**すべて `$CODEX_HOME/sessions/` のローカル rollout であり、クラウド種別は存在しない** |
| Codex Cloud | `codex cloud list` → タスク 0 件（未使用） |
| ディープリンク | app-server プロトコルに**該当メソッドなし**。`codex app` は workspace パスのみ受け付ける。`codex://` URL スキームは開発機に未登録 |
| `codex resume <UUID>` | セッションID（UUID）指定に対応。**検証済みの確実な移動手段** |

### 未実測（Step 0 / 0.5 で確定させる）

- 接続確立までの実レイテンシ（予熱で足りるか、常時接続が要るかの判断材料）
- Codex 経由でのセッション上限の実値
- ミュート方式のコスト差（`track.enabled = false` は無音を送信し続ける。`replaceTrack(null)` は送信を停止する）
- HoverPocket が作ったスレッドが ChatGPT アプリのセッション一覧に現れるか

---

## 3. 確定要件

### 3.1 形態

**provider ではなく lane。**Calendar や Clipboard を表示したまま会話できること。
声で操作する道具である以上、「今週の予定を見ながら、声で予定を足す」が同一画面で成立する必要がある。

### 3.2 表示モード（全画面表示は禁止）

| モード | 内容 | 用途 |
|---|---|---|
| **コンパクト**（既定） | 会話中アニメーション + 音声波形 + ミュート + 直近 transcript 1〜2行 | 会話が主で、履歴やセッション操作が不要なとき |
| **通常（拡大）** | transcript が縦に流れる + 右側に子 Codex セッションのカードリスト | 履歴を追う、セッションへ移動するとき |

レーン内のボタンで相互に切り替える。
**パネル全体を覆う全画面表示にはしない。**HoverPocket の「ポケットからパッと取り出す」体験が壊れるため。

### 3.3 ライフサイクル

- **パネルを閉じても、会話とバックグラウンド作業は継続する。強制シャットダウンしない。**
- パネルを閉じたときの挙動:
  - マイクは**ミュート**になる（こちらの声は Codex に届かない）
  - 常時起動オプションが **OFF** のときは、会話のキャッチボールが一区切りついた時点で**自動的にセッションを閉じる**
  - 子 Codex セッションの作業は**常に継続する**
- 上記の挙動は**設定で変更可能**にする（実測しながら調整する前提）

### 3.4 機能要件

1. 会話中であることが視覚的に分かるアニメーション
2. 会話中のチャットが流れて表示される（transcript）
3. 右側に、裏で動いている Codex セッションのカードリスト
4. カードから該当セッションへ移動できる（第9章参照）
5. 音声レベルの波形表示
6. ミュートボタン + **グローバルホットキー**（パネル非表示中でも切替可能）
7. セッション残り時間の表示（オプション）
8. Small / Medium / Large すべてで崩れ・はみ出しがない

---

## 4. 設計

### 4.1 全体構成

```
[WebView2 (Chromium)]                     [C# / WPF Shell]              [codex app-server]
  getUserMedia
  RTCPeerConnection  --- offer SDP --->  WebMessage 中継  --- JSON-RPC --->  thread/realtime/start
                     <--- answer SDP ---                 <--- 通知 ---       thread/realtime/sdp
  AnalyserNode(波形)
  transcript 描画    <------------------ 通知中継 <--------------------      transcript/delta
        |
        +===================== 音声は WebRTC で直接 =====================+
```

要点は、**音声そのものは app-server を経由せず WebRTC で直接流れる**こと。
したがって遅延は Realtime API 本来の値になり、C# 側は制御信号の中継に徹する。

C# 側の受け口は新規ではない。`windows/src/HoverPocket.Shell/Bridge/BridgeDispatcher.cs` が
すでに `method` → ハンドラの JSON ディスパッチャであり、app-server の JSON-RPC と構造が一対一で対応する。

### 4.2 レーンの高さ（既存レイアウト機構をそのまま使う）

`windows/src/HoverPocket.Shell/Configuration/PanelSizeCatalog.cs` には
**すでに `AiLaneHeight` が存在し、現在 0 が入っている**。
`PanelSizeMetrics.TotalHeight => ProviderHeight + AiLaneHeight` であるため、
**この値を変えるだけでパネルが下方向に伸び、provider 領域は一切潰れない。**

| サイズ | 幅 | provider 高 | コンパクト | 拡大 |
|---|---|---|---|---|
| Small | 520 | 372 | 64 | 190 |
| Medium | 600 | 430 | 64 | 220 |
| Large | 680 | 488 | 64 | 250 |

拡大モードは transcript を左、カード列を右に置く2カラム。
Small（幅 520px）はカード列が狭くなるため、カードの情報量を落とすか折りたたみ可能にする（レイアウト検証で確定）。

### 4.3 常駐と再接続

- `codex app-server --stdio` を C# が常駐プロセスとして管理する（異常終了時は再起動）
- Realtime セッションは上限手前でローリング再接続する。`thread/realtime/closed` を拾って自動復帰する
- 残り時間表示は `thread/realtime/started` からの経過時間で算出する（上限の実値は Step 0 で実測）

### 4.4 ミュート

- WebView2 側で `track.enabled = false`（標準的で確実）を既定とし、
  `replaceTrack(null)`（送信そのものを停止）をコスト面で比較検証する
- グローバルホットキーは Win32 `RegisterHotKey` + `WM_HOTKEY`。
  受け口は既存の `windows/src/HoverPocket.Shell/Windows/NoActivateWindow.cs` の `Win32MessageReceived`

### 4.5 起動レイテンシへの対処

パネルの開閉は 0.22 秒だが、app-server の起動と WebRTC ネゴシエーションはその速度では終わらない。
以下の3モードを設定で選べるようにする。

| モード | 挙動 | 体感 | マイク |
|---|---|---|---|
| 予熱（既定） | app-server とスレッドは常駐。セッションは上端への接近検知で開始 | ほぼ待たない | 掴まない |
| 常時接続 | セッションを張りっぱなし、非ホバー時はミュート | 待ちゼロ | **常時掴む** |
| 都度起動 | ホバーで初めて接続 | 数秒待つ | 掴まない |

「予熱」が効くのは、遅延の大半が app-server のプロセス起動とスレッド初期化にあり、
WebRTC のネゴシエーション自体は速いためである。上端への接近検知は、既存のポインタ追跡の延長で実装できる。

---

## 5. 既存資産と新規実装

### 5.1 再利用するもの

| 資産 | 場所 | 内容 |
|---|---|---|
| レーン用の高さ枠 | `Configuration/PanelSizeCatalog.cs` | `AiLaneHeight` が既に存在（現在 0） |
| レーン用 UI 階層 | `windows/ui/ailane/` | `providers/` と別階層。lane として設計されていた |
| 承認・監査の骨格 | `Providers/AiLane/` | `AiLaneController`（承認カード提示 → 承認/却下 → 実行の状態機械）、`AiLaneAuditLog`（90日保持 JSONL） |
| JSON-RPC ディスパッチャ | `Bridge/BridgeDispatcher.cs` | app-server の JSON-RPC と構造が一対一 |
| 活性化切替 | `Windows/NoActivateWindow.cs` | `SetActivationEnabled` / `ActivatesOnMouseInteraction` |
| Win32 メッセージフック | `NoActivateWindow.Win32MessageReceived` | `WM_HOTKEY` の受け口 |
| 設定永続化 | `Configuration/UserSettings.cs` | bool フィールドを追加するだけ |
| 検証コンソール | `Verification/` | 既存 13 verifier |

### 5.2 新規に必要なもの

- WebView2 の `PermissionRequested` ハンドラ（マイク許可。**現状ハンドラは存在しない**）
- グローバルホットキー（`RegisterHotKey` / `WM_HOTKEY`。**リポジトリに前例なし**）
- app-server 常駐プロセス管理 + stdio JSON-RPC クライアント
- Realtime セッションのローリング再接続
- 音声波形（Web Audio `AnalyserNode`）
- 追加する設定: 実験フラグ / 起動モード（予熱・常時・都度）/ 残り時間表示 / ミュートホットキー / 既定表示モード

---

## 6. 進め方

### Step 0: 実接続テスト（リポジトリのコードを触らない）

スクリプト単体で `thread/realtime/start` を1回実行し、以下を実測する。

- 接続確立までの実レイテンシ
- セッション上限の実値
- `account/rateLimits/read` の前後比較による課金経路の確認
- WebRTC の SDP 往復成立

### Step 0.5: ChatGPT アプリ連携の可否判定

HoverPocket 相当のクライアント名で作ったスレッドが、ChatGPT アプリのセッション一覧に現れるかを確認する。
結果によってカードのクリック挙動を確定させる（第9章）。

### Step 1: 本ブランチで実装

`ProviderRegistry` / `UserSettings` に**既定オフの実験フラグ**を置く。
`ProviderRegistry.CreateDefault()` は現在固定リストを返しているだけなので、条件付き登録に変更する。
フラグがオフの利用者には、機能が存在しないのと同じ状態になる。

到達点は「ホバー → 音声接続 → 発話が transcript としてパネルに出る」。
ここが通れば残りは積み上げになる。

### Step 2: 既定オフのまま `main` へマージ

未完成でもフラグがオフなら誰にも影響しない。既存の修正と同じ土俵に乗せる。

### Step 3: 他人にテストしてもらう段階で Velopack のチャンネルを分離

`windows/script/publish_release.ps1` の `--channel win`（131行目）と
`updateChannel`（153行目）をパラメータ化し、`win-canary` を作る。
安定版利用者の更新フィードには一切流れない。

---

## 7. 検証方針

リポジトリの既存文化（13 verifier + progress ログ）に合わせる。

- Debug / Release 両構成で warnings 0 / errors 0
- 既存 13 verifier + 新規 `--verify voice`（実セッション不要のモック検証）が exit 0
- Windows UI JavaScript 全ファイルの syntax check
- **S / M / L × コンパクト / 拡大 の 6 通りでレイアウト検証**（崩れ・はみ出しなし）
- Codex 未検出・未ログイン時にレーンが安全に無効化されることの確認
- 実音声の E2E はユーザー手動（音声は自動検証できないため）
- `progress/YYYY-MM/` に作業ログ、`docs/report/` に検証結果を残す

---

## 8. 織り込み済みのリスク

- **app-server も realtime も experimental である。**Codex の更新でプロトコルが変わり得る。
  `initialize` の応答からバージョンを取り、想定外なら**レーンを静かに無効化する**防御を最初から入れる。
- **利用者の端末に Codex CLI とサブスクリプション契約が必要。**同梱できないため、
  未インストール／未ログインは正常系として扱う（Google Calendar 未接続と同じ扱い）。
- **常時接続モードを有効にするとマイクを掴み続ける。**
  Windows のマイク使用中インジケーターが出続けるため、既定オフ + レーン上での状態明示を必須とする。
- **Realtime の音声は従量課金として高価である。**常時接続を既定にしない理由の一つ。

---

## 9. 未解決事項

### 9.1 子 Codex セッションへの「移動」の実体

**要求**: カードを押すと、ChatGPT アプリ（旧 Codex アプリ）の該当会話に飛べること。
パネル内にフルのチャット UI を実装するのは重いので避けたい。

**調査結果**:

- app-server のプロトコルに**ディープリンクの手段は存在しない**
- `codex app` は workspace のパスのみ受け付け、スレッド指定はできない
- `codex://` URL スキームは開発機に未登録
- `sourceKind` は `cli` / `desktop` / `vscode` の3種で、**すべて `$CODEX_HOME/sessions/` のローカル rollout**。
  クラウド種別は存在しない
- 一方 `desktop` という種別が存在することは、**デスクトップ側の Codex が同じローカルセッションストアを共有している**
  ことを示唆する。したがって HoverPocket が作ったスレッドが ChatGPT アプリの一覧に現れる可能性はあるが、未検証

**実装方針（上から順に、使えるものを採用）**:

1. ChatGPT アプリで開く（**Step 0.5 の実測結果で採否を決める**）
2. `codex resume <threadId>` を新規ターミナルで起動（**検証済み・確実**）
3. カード上に軽量サマリを出す（最新の agentMessage 1件、実行中コマンド名、状態、経過時間）

**パネル内にフルのチャット UI は実装しない。**カードは「状態の可視化」と「移動の起点」に限定する。

### 9.2 マルチエージェントの起動条件

仕様上 `multiAgentMode` は常に `explicitRequestOnly` を返し、
能動的なマルチエージェント動作の源は Ultra reasoning effort であるとされている。
つまり「勝手に裏で Codex が増える」体験にするには、明示的にそう指示する必要がある。
音声プロンプト側の設計（`realtimeStartInstructions`）で誘導できるかは要検証。

### 9.3 非アクティブウィンドウでのマイク取得

パネルは `WS_EX_NOACTIVATE` の非アクティブウィンドウである
（`NoActivateWindow`: `ShowActivated = false` / `Focusable = false`）。
この状態で `getUserMedia` が通るかは実機確認が必要。
`ActivatesOnMouseInteraction` → `SetActivationEnabled(true)` でクリック時に活性化する仕組みは既にあるため、
最悪でも「初回はクリックが必要」に落とせる見込み。

---

## 参考

- [codex-rs/app-server README（openai/codex 公式）](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)
- [Unlocking the Codex harness: how we built the App Server | OpenAI](https://openai.com/index/unlocking-the-codex-harness/)
- [Realtime conversations | OpenAI API](https://platform.openai.com/docs/guides/realtime-conversations)
