---
project_slug: hover-pocket
target: Windows version requirements
created: 2026-07-05
updated_by: codex
status: draft-integrated
source_app_release: v0.1.0-98
---

# HoverPocket Windows 版 要件定義

## 0. 結論

Windows 版の本質は、「画面上端へポインターを運ぶだけで、普段は邪魔にならない小さな起点から、毎日使う道具を暗いユーティリティパネルとして一瞬で取り出せる常駐アプリ」です。

単なるメニューバー代替、ランチャー、サイドバー、Web アプリではなく、次の体験を再現することを最優先にする。

- 画面上端の控えめな起点にホバーすると開き、離れると閉じる。
- パネルは短いアニメーションで上端から展開し、道具を「ポケットから取り出す」感覚を保つ。
- Mirror、Controls、Calendar、Clipboard、Sticky Notes、Timer、Calculator を同じシェル内で切り替える。
- パネルは通常作業を邪魔せず、必要な時だけ最前面に出る。
- クリップボード、カメラ、マイク、カレンダー、メディア制御などの強い権限は、明示的な状態表示、無効時の案内、最小保存で扱う。

## 1. 前提と範囲

### 1.1 対象

- 対象リポジトリ: `C:\Users\shotaro\code\shared\hover-pocket`
- 既存アプリ: macOS 版 `ホバーポケット` / `HoverPocket`
- 既存公開版: GitHub Release `v0.1.0-98`
- Windows 版の対象 OS: Windows 11 を主対象にし、可能なら Windows 10 も後続検証対象にする。

### 1.2 この要件書で固定すること

- Windows 版で再現すべき体験、機能、操作感。
- macOS 版と同等と見なす受け入れ条件。
- Windows 固有の制約、代替仕様、検証観点。
- 実装フェーズの優先順位。

### 1.3 この要件書でまだ固定しないこと

- 最終技術スタック。
- UI コンポーネント単位の詳細設計。
- 永続化ファイルの最終スキーマ。
- インストーラー方式、署名証明書、更新配信方式の最終選択。

### 1.4 Mac / Windows 横断ワークフロー

Must:

- macOS 版は Mac 実機の Codex が担当し、SwiftPM build、macOS UI、Sparkle、notarization、Gatekeeper、macOS appcast readback を確認する。
- Windows 版は Windows 実機の Codex が担当し、Windows build、installer、Velopack feed、Windows 実機 UI、update apply / restart を確認する。
- 共通仕様は先にこの `requirements.md` に書き、OS 別に実装する。
- 片方の OS だけで確認した挙動を、もう片方の完了として扱わない。
- 実装や配信に入る AI エージェントは、作業前に project root の `AGENTS.md`、`progress/progress.md`、この `requirements.md` を読む。

Release policy:

- macOS と Windows は GitHub Releases の `latest` を共有しない。
- macOS は macOS 専用 appcast URL を使う。
- Windows は Windows 専用 feed を使う。
- release asset 名は OS ごとに衝突しない名前にする。
- 配信後は各 OS の feed と成果物を別経路で readback する。

受け入れ条件:

- macOS release の後、macOS appcast と `HoverPocket.app` ZIP が読める。
- Windows release の後、Windows feed と installer / portable / package asset が読める。
- どちらかの release により、もう片方の更新 URL が 404 にならない。

## 2. 体験原則

### R-UX-001: 画面上端が入口である

Must:

- Windows 版は、タスクバーや通常ウィンドウではなく、画面上端中央の小さな起点から開く。
- ノッチがない Windows PC では、macOS 版の `miniBar` に相当する上端ミニバーを標準入口にする。
- マウスを画面上端のホットゾーンへ入れるとパネルが開き、ホットゾーンまたはパネルから十分に離れると閉じる。

受け入れ条件:

- 通常作業中、起点は視覚的に控えめで、常時邪魔にならない。
- ポインターを上端へ運んだ時だけ、ユーザーが意図して開ける。
- フルスクリーン動画、ゲーム、リモートデスクトップ中は、誤発火を避ける抑制設定を持つ。

### R-UX-002: 開閉は短く、軽く、連続操作に強い

Must:

- パネルは上端付近の小さい collapsed 状態から、短時間で最終サイズへ展開する。
- 既存 macOS 版の目安として、open/close duration は `0.22s`、close delay は `0.06s`。
- 閉じかけで再ホバーした場合、カクつきや瞬間移動を避け、現在位置から開き直す。
- Reduce Motion 相当の OS 設定またはアプリ設定が有効な場合、拡大縮小アニメーションを抑制する。

受け入れ条件:

- 25 回以上の連続 open/close で、ウィンドウが増殖しない。
- close 後にカメラ映像やパネル残像が残らない。
- 開閉直後にクリックが誤って下のアプリへ抜けない。

### R-UX-003: 全機能は同じポケット内で切り替わる

Must:

- Provider は `Mirror`、`Controls`、`Calculator`、`Calendar`、`Clipboard`、`Sticky Notes`、`Timer` の順を初期登録候補にする。
- Provider header には現在の provider 名、パネルサイズ切り替え、provider アイコン、更新アイコン、設定アイコンを置く。
- provider アイコンは Click 切り替えと Hover 切り替えを設定で選べる。
- provider はドラッグまたは代替操作で並び替えられる。
- provider は表示/非表示を切り替えられるが、少なくとも 1 つは常に表示される。

受け入れ条件:

- パネルを閉じずに provider を切り替えられる。
- 切り替え時に選択状態、タイトル、本文が同期して更新される。
- 並び替え、非表示、前回選択 provider は再起動後も保持される。

### R-UX-004: Windows らしさよりも HoverPocket らしさを優先する

Must:

- UI は Windows の標準設定画面風ではなく、既存の暗いコンパクトユーティリティパネルを再現する。
- 角丸、余白、アイコン中心の操作、コンパクトなテキスト、淡い区切り線、暗色背景を維持する。
- Windows 側の慣習に合わせるのは、権限ダイアログ、トレイメニュー、インストール、更新、通知、キーボード操作に限る。

受け入れ条件:

- macOS 版ユーザーが、初回起動直後に同じアプリだと分かる。
- Provider 内の操作は既存 README の説明と矛盾しない。

## 3. シェルとウィンドウ要件

### R-SHELL-001: 常駐とトレイ

Must:

- Windows 版は常駐アプリとして動作し、タスクトレイにアイコンを表示する。
- 通常時はタスクバーに通常ウィンドウを出さない設定を既定にする。
- トレイメニューから `Open Panel`、`Settings`、`Check for Updates`、`Quit` を実行できる。
- 多重起動を防ぎ、2 回目の起動は既存インスタンスへフォーカスまたはパネル表示を依頼する。

Should:

- Windows 起動時に自動起動する設定を用意する。
- 自動起動は既定オフにし、設定画面から明示的に有効化する。

### R-SHELL-002: マルチディスプレイ

Must:

- 表示先設定は `Main`、`Sub`、`All` を持つ。
- `All` では各ディスプレイ上端に起点を表示し、マウスが入ったディスプレイでパネルを開く。
- DPI スケールが異なる複数ディスプレイでも、パネル位置、ホットゾーン、サイズが破綻しない。
- ディスプレイ接続/切断、解像度変更、DPI 変更後に起点位置を再計算する。

受け入れ条件:

- メイン 100%、サブ 150% などの mixed DPI で、パネルが画面外へ出ない。
- サブディスプレイだけの環境でも起動できる。
- `Sub` 選択時にサブがない場合は `Main` へ安全に戻る。

### R-SHELL-003: パネル寸法

Must:

- Provider 領域サイズは既存値を基準にする。
- `Small`: 幅 520、高さ 372。
- `Medium`: 幅 600、高さ 430。
- `Large`: 幅 680、高さ 488。
- Header は高さ 54 を基準にする。
- Windows 版では上記を DIPs 基準で扱い、DPI scaling 後の物理ピクセルで崩れないようにする。

受け入れ条件:

- サイズ切り替え時、上端基準位置を維持したまま滑らかにリサイズする。
- テキストサイズ `Small`、`Medium`、`Large` で主要 UI がはみ出さない。
- Windows の DIPs と物理ピクセルの差を吸収し、見た目のサイズ感を保つ。

### R-SHELL-004: 閉じる条件

Must:

- ポインターが起点またはパネル領域から離れた場合、短い delay 後に閉じる。
- 既存 macOS 版の操作感に合わせ、起点/preview の外側 4pt 相当までは hover region として許容する。
- close 判定は軽い polling で補助し、目安は 0.12 秒間隔とする。
- パネル内ドラッグを開始した場合、ドロップ先を邪魔しないようパネルを一時的に隠す。
- Settings を開く場合、hover panel を閉じる。
- Timer alert 表示中は、マウスが外へ出ても即時自動 close しない。

受け入れ条件:

- Clipboard 画像/テキスト、Sticky Notes の外部ドラッグで、ドラッグ元パネルがドロップ先を覆い続けない。
- パネル閉鎖中に内部 state が壊れず、再表示時に provider が正常に戻る。

### R-SHELL-005: Access window と Preview window の責務分離

Must:

- Windows 版でも、上端ホットゾーンを担当する軽量 access surface と、入力可能な preview panel surface を概念上分離する。
- access surface は常時控えめに表示し、入力可能な preview panel は開いている間だけ前面化する。
- preview panel はキーボード入力、ドラッグ、テキスト編集、Google OAuth 後の復帰を受けられる。

受け入れ条件:

- access surface だけが残っている idle 状態で、通常アプリの入力を奪わない。
- preview panel 表示中は TextBox、drag/drop、context menu、shortcut が provider に届く。

## 4. Provider 機能要件

### 4.1 Mirror

Must:

- Web カメラ映像を鏡として表示する。
- 映像は左右反転する。
- カメラは Mirror provider が active な間だけ起動する。
- close 後はすぐ破棄せず、短い再ホバーに備えた grace を持つ。既存版の目安は 4 秒。
- 初回利用時に Windows のカメラ権限が必要であることを表示する。
- camera permission の requesting、denied、restricted、no camera、failed を状態として扱い、クラッシュせず案内を表示する。
- 外部モニター利用時にカメラが存在しない場合、Mirror を自動非表示または利用不可表示にできる。

Should:

- カメラ権限が許可済みなら、アプリ起動時に軽く prewarm して初回表示を短縮する。
- 表示中にカメラ接続/切断が起きても、provider 表示を更新する。

Microphone row:

- 設定で表示/非表示を切り替えられる。
- 表示中だけマイクレベルメーターを動かす。
- 一時録音、停止、再生を提供する。
- 録音データはメモリ上だけで扱い、音声ファイルとして保存しない。
- 録音は短時間用途に限定する。既存版の要件抽出では最大 20 秒を基準にする。

受け入れ条件:

- 連続 open/close 後もカメラが掴みっぱなしにならない。
- Mirror を閉じた後、CPU/カメラ/マイク利用が停止する。
- 権限拒否後、設定から復帰できる導線がある。

### 4.2 Controls

Must:

- Displays、Volume、Now Playing を縦積みのコンパクト UI として表示する。
- ディスプレイごとの明るさを表示し、対応ディスプレイではドラッグで調整できる。
- 対応していないディスプレイは `非対応` として表示し、操作を無効化する。
- 音量を取得し、調整、ミュート切り替えを実行できる。
- 再生中メディアがある場合、タイトル、ソース、アートワークまたはプレビュー、再生位置、再生/一時停止、10 秒戻し、10 秒送り、倍速操作を表示する。
- メディア操作の成功状態は、実際の状態を読み戻して表示する。

Windows 固有要件:

- ディスプレイ輝度は Windows 標準 API と DDC/CI の両方を候補にし、失敗時は明確に unsupported として扱う。
- メディア情報は Windows のメディアセッション情報、ブラウザタブ連携、フォールバックの順で設計する。
- ブラウザ動画の倍速変更は、対象タブを誤認しないよう URL/title で照合する。

受け入れ条件:

- YouTube などブラウザ再生で title/source/progress が取れる。
- 倍速を押した直後に未確認の値を成功表示しない。
- メディア情報取得やブラウザ操作が失敗しても UI が固まらない。

### 4.3 Calendar

Must:

- Google アカウントで接続し、Google Calendar を表示できる。
- 月グリッドを表示し、今日、選択日、予定ありの日が分かる。
- 月グリッドは 6 週分、つまり 42 日セルを基準にする。
- 日付 hover で当日の予定をプレビューできる。
- 日付クリックで詳細を固定できる。
- 予定の追加、編集、削除ができる。
- 書き込みには `calendar.events` 相当の権限が必要で、古い read-only credential は再接続扱いにする。
- タイトル、開始/終了時刻、終日、場所、メモ、対象カレンダーを扱う。
- 日付セルのダブルクリックから新規予定を作成できる。
- 日付セルから新規予定を作る場合、既定時刻は選択日の 9:00-10:00 を基準にする。

OAuth:

- PKCE を使う。
- OS 既定ブラウザで Google 認証画面を開く。
- Windows ではカスタム URI scheme または loopback redirect をサポートする。
- refresh token は Windows Credential Manager など OS の安全な資格情報ストアに保存する。
- token や secret はファイル、ログ、Git に出さない。

操作感:

- 認証確認中でも空の月グリッドを先に描画する。
- 予定取得は背後で更新する。
- 日時入力は手入力、ドラッグ、スクロール、インライン調整バーに対応する。
- 調整バーはレイアウトを押し広げず、固定レーン内に表示する。

受け入れ条件:

- 保存済み認証では再ログインなしで予定を取得できる。
- 権限不足時は再接続が必要な状態として明示する。
- 予定作成/編集/削除後、月グリッドと詳細が更新される。
- read-only calendar の予定は編集/削除できない。
- 削除前に確認を挟む。

### 4.4 Clipboard

Must:

- テキストと画像のクリップボード履歴を表示する。
- テキスト履歴は最大 30 件、画像履歴は最大 20 件を基準にする。
- クリップボード監視は軽量に行い、既存版の目安として 0.75 秒間隔を基準にする。
- provider が有効な間だけ clipboard monitoring を開始し、provider が非表示/無効の場合は停止できる。
- 履歴項目クリックで再コピーできる。
- テキストと画像を外部アプリへドラッグできる。
- 画像は PNG 相当に正規化し、重複はハッシュで抑制する。
- 画像ファイルと履歴 metadata をローカル Application Data 配下に保存する。
- metadata は `history.json` 相当、画像実体は個別 PNG ファイルとして分ける。

Should:

- Private mode を追加し、クリップボード監視を一時停止できる。
- パスワードマネージャーや特定アプリ由来のコピーを除外する設定を持つ。
- 履歴保存期間または全消去を設定できる。

受け入れ条件:

- パネルが閉じていても監視は設定どおり継続する。
- 画像ドラッグ時、受け取り側アプリで画像ファイルとして扱える。
- 機密っぽいデータを保存する可能性を Settings と README で明示する。

### 4.5 Sticky Notes

Must:

- 付箋をボードグリッドで表示する。
- 付箋は title、body、color、createdAt、updatedAt、archivedAt、sortIndex を持つ。
- 付箋クリックで inline editor に切り替わる。
- 編集内容は別付箋クリック、付箋外クリック、色変更、archive/delete のタイミングで確定する。
- `Control + Enter` で編集確定できる。
- タイトルと本文が空の新規付箋は保存せず破棄する。
- 色スウォッチのダブルクリックで、その色の新規付箋を作る。
- グリッドサイズは `S`、`M`、`L` で切り替えられる。
- 付箋はドラッグで並び替えられる。
- 外部ドラッグで本文を他アプリへ渡せる。
- ドラッグ中の下部ゴミ箱ドロップでアーカイブできる。
- 右クリックメニューから編集、色変更、アーカイブ、削除ができる。
- アーカイブ/削除後の Undo toast は Settings で表示/非表示を切り替えられる。

受け入れ条件:

- 並び替え後に薄い残像や重複表示が残らない。
- 再起動後、並び順、色、内容が保持される。
- Undo で直前の archive/delete を戻せる。

### 4.6 Timer

Must:

- 「タイマー」と「ポモドーロタイマー」の 2 種類の入力カードを持つ。
- 各カードに title、color、sound on/off を設定できる。
- 通常 Timer の既定値は 10 分、Pomodoro の既定値は work 25 分 / rest 5 分を基準にする。
- 時間は直接入力とインライン調整バーで調整できる。
- ポモドーロは work/rest を交互に切り替える。
- Pomodoro は work cycle count を表示する。
- 実行中タイマーは最大 2 つ。
- ピン留め preset は最大 4 つ。
- 実行中タイマーは pause、resume、stop できる。
- 残り時間は絶対終了時刻ベースで計算し、スリープ復帰後も大きく狂わない。
- タイマー終了時はパネルを自動表示し、Timer provider を開く。
- 音ありの場合は停止までループ再生する。
- 終了時はハンドル/ミニバーを timer color で bounce または静的ハイライト表示にする。

受け入れ条件:

- アプリ再起動後、未期限切れの実行中タイマーと pinned preset が復元される。
- 期限切れの過去タイマーは、遅れて鳴らさず破棄する。
- Reduce Motion 有効時は通知アニメーションを静的表示にする。

### 4.7 Calculator

Must:

- 四則演算、小数、符号反転、パーセント、バックスペース、AC、コピーを提供する。
- 数字、演算子、Enter、Escape、Backspace のキーボード入力に対応する。
- `0` は 2 列幅として配置する。
- 演算子表記は `÷`、`×`、`−`、`+` を基準にする。
- 0 除算など計算できない入力は `Error` と表示する。
- `Error` 表示中は copy を無効化し、次の入力で復帰できる。
- 計算結果はコピーできる。

受け入れ条件:

- キーパッドがパネルサイズで崩れない。
- 大きいパネルでもキーが横に伸びすぎない。
- 代表計算ケースを CLI またはユニットテストで検証できる。

### 4.8 AI command lane

Deferred:

- AI command lane は計画・開発途中のため、現行アプリ UI からは一旦外す。
- 後続で戻す場合も、Provider 領域を侵食しない高さ設計にする。
- Phase 1 の対象 action 候補は Calendar read day と Calendar create event とする。
- 自然文例候補: `今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`。
- Calendar write は必ず承認 UI を通す。
- 実行結果、失敗、承認/却下は audit log に記録する。

Windows 代替要件:

- Apple Foundation Models は Windows では使えないため、AI provider は差し替え可能にする。
- 初期 Windows MVP では deterministic fallback だけでもよいが、AI lane の UI は現行アプリからは一旦外す。
- 将来の local LLM または cloud LLM 接続は、カレンダー書き込みの承認原則を変えない。

受け入れ条件:

- Calendar read は承認なしで実行できる。
- Calendar create は承認しない限り実行されない。
- 失敗時に token や個人情報をログへ出さない。

## 5. Settings 要件

Must:

- UI language: Japanese / English。
- Display placement: Main / Sub / All。
- Panel size: Small / Medium / Large。
- Panel text size: Small / Medium / Large。
- Provider switching: Click / Hover。
- Provider visibility: provider ごとの ON / OFF。
- Provider order: 並び替え。
- Provider selection: 前回開いた provider を優先するか、固定 default provider を使うか。
- Handle icon: B / C / None 相当。
- Top handle side area: 表示 / 非表示。
- Mirror microphone row: 表示 / 非表示。
- Mirror on secondary displays: 表示 / 非表示。
- Sticky Notes undo toast: 表示 / 非表示。
- Sticky Notes grid size: S / M / L。
- Check for Updates。

Windows 追加 Must:

- Start with Windows。
- Pause Clipboard Monitoring / Private Mode。
- Disable top-edge trigger while full-screen app is active。
- Reset panel position and display binding。
- Open data folder。
- Open Windows privacy settings for Camera/Microphone when permission is blocked。

## 6. データ保存とセキュリティ

### R-DATA-001: 保存場所

Must:

- アプリデータは Windows のユーザープロファイル配下に保存する。
- 推奨候補: `%APPDATA%\HoverPocket\` または `%LOCALAPPDATA%\HoverPocket\`。
- Sticky Notes、Clipboard、Timer、AuditLog は別ディレクトリに分ける。
- 画像 Clipboard はファイル、metadata は JSON として保存できる。
- 設定は OS 標準設定ストアまたは JSON へ保存し、破損時に既定値へ戻せる。

### R-DATA-002: 秘密情報

Must:

- Google refresh token は Windows Credential Manager など OS の資格情報ストアへ保存する。
- OAuth client secret、token、notary/signing credentials、API key は Git、ログ、progress、README に出さない。
- audit log には action metadata と結果だけを保存し、token や認証レスポンス本文を保存しない。

### R-DATA-003: プライバシー

Must:

- Clipboard history は機密情報を保存しうるため、README と Settings で明示する。
- Private Mode で一時停止できる。
- ユーザーが履歴を全削除できる。
- Mirror の一時録音はメモリ上だけで扱い、ファイル保存しない。

Should:

- Clipboard history に保存しないアプリ名、ウィンドウ名、データ型を指定できる。
- 保存期間の上限を設定できる。

## 7. Windows OS 能力要件

Windows 版の実装方式は未決定だが、次の OS 能力を満たす必要がある。

Must:

- 常駐トレイアイコン。
- Explorer 再起動後の tray icon 復帰。
- 多重起動防止。
- 非表示に近い access window と、入力可能な preview overlay の分離。
- 透明または装飾なしの常時最前面 overlay window。
- mixed DPI のマルチモニター座標変換。
- monitor 追加/削除、sleep/wake 復帰時の再同期。
- グローバルなマウス位置監視または上端ホットゾーン window。
- Win32 Clipboard 変更通知、または同等の clipboard listener。
- クリップボード読み書きと画像ファイル drag/drop。
- カメラとマイク利用、権限状態の検出。
- Windows 音量取得/設定/ミュート。
- Windows media session 読み取りと再生制御。未対応アプリには fallback を設計する。
- ディスプレイ輝度操作と unsupported fallback。
- Google OAuth は desktop loopback + PKCE を基本線にし、必要に応じて custom URI scheme を追加する。
- Credential Manager などの資格情報保存。
- ETW/EventSource または rotating file log などの診断ログ。
- 自動更新または更新通知。
- Authenticode 署名付き配布。

Should:

- Windows 通知または独自上端アラート。
- media thumbnail が必要な場合は Windows Graphics Capture 相当を検証する。
- WebView2 を使う場合は Evergreen Runtime の存在確認またはインストーラーでの同梱/導入確認。
- MSIX または installer による protocol registration、startup registration、runtime dependency check。

## 8. 技術選定に関する初期判断

これは要件であり、最終技術選定ではない。

### 候補 A: Windows App SDK / WinUI 3 + native services

向いている点:

- Windows の windowing、composition、input、packaging、runtime、notifications との親和性が高い。
- Microsoft Learn では Windows App SDK が modern Windows APIs と UI/windowing namespace を提供する。
- packaged/unpackaged どちらでも Windows App SDK runtime 初期化が論点になる。

懸念:

- 既存 SwiftUI UI を直接再利用できない。
- カスタム top-edge overlay と system-level controls は Win32 interop が必要になりやすい。

### 候補 B: Tauri v2 + Rust native services + Web UI

向いている点:

- トレイ、deep link、window customization、plugin、Rust command integration を持つ。
- UI の再現を HTML/CSS で高速に進めやすい。
- 将来 macOS/Windows の UI を寄せやすい可能性がある。

懸念:

- Controls、Mirror、media、DDC/CI、Credential Manager などは Rust/Win32 側の実装品質が成否を握る。
- ネイティブらしい overlay/window focus/drag/drop は追加検証が必要。

### 候補 C: Native shell + WebView2 UI

向いている点:

- WebView2 は Chromium ベースの UI を Windows desktop app に埋め込める。
- Microsoft docs では多くの WebView2 app で Evergreen Runtime が推奨され、固定版は厳密な互換性要件向け。

懸念:

- WebView2 runtime の存在確認、配布、更新責任が増える。
- 高頻度 overlay UI と OS 操作の境界設計が必要。

推奨前提:

- 要件定義段階では、技術選定より先に「Windows native shell 能力」と「provider UI/logic の分離」を固定する。
- 最初の実装検証では、top-edge overlay、tray、多画面 DPI、Clipboard drag/drop、camera permission の 5 点を spike する。

## 9. MVP と段階的リリース

### Phase 0: 技術検証

Must:

- トレイ常駐。
- top-edge mini bar。
- hover open/close。
- multi-monitor/DPI。
- transparent/topmost overlay。
- アプリ終了/再起動/多重起動防止。

完了条件:

- 空パネルが上端から 0.22 秒前後で開閉する。
- Main/Sub/All の最小挙動が動く。
- フルスクリーン抑制の可否が判断できる。

### Phase 1: 低 OS 依存 provider

Must:

- Calculator。
- Timer。
- Sticky Notes。
- Settings。

理由:

- HoverPocket の日常利用感を早く確認できる。
- OS 依存が比較的少なく、UI シェルの品質検証に向く。

### Phase 2: Clipboard と Calendar

Must:

- Clipboard history。
- Google Calendar read/write。
- OAuth/credential storage。
- Private mode。

理由:

- 実用性が高いが、プライバシーと認証の設計が必要。

### Phase 3: Mirror と Controls

Must:

- Camera mirror。
- Microphone row。
- Volume。
- Display brightness。
- Now Playing。
- Browser media fallback。

理由:

- OS 依存が強く、個別の Windows API 検証が必要。

### Phase 4: 配布と更新

Must:

- 署名付き installer/package。
- 自動更新または更新確認。
- GitHub Releases への Windows asset。
- 初回起動、権限、アンインストール時のデータ扱いを確認。

## 10. 受け入れテスト

### 10.1 シェル E2E

- 起動後、通常ウィンドウではなくトレイ常駐する。
- 画面上端中央へマウスを移動すると起点が反応する。
- パネルが collapsed 状態から開く。
- パネルからマウスを離すと close delay 後に閉じる。
- `Small`、`Medium`、`Large` が上端固定で切り替わる。
- Click/Hover provider switching が設定どおり動く。
- provider 並び替えと非表示が再起動後に保持される。
- Main/Sub/All が mixed DPI で動く。

### 10.2 Provider E2E

- Mirror: カメラ権限許可後に左右反転表示し、閉じるとカメラが停止する。
- Mirror mic: 一時録音、停止、再生ができ、ファイルが作られない。
- Controls: 音量/ミュートが実 OS 状態と一致する。
- Controls: unsupported display brightness が安全に無効化される。
- Controls: ブラウザ動画の再生情報と倍速が読み戻し確認される。
- Calendar: 保存済み認証で予定が取得される。
- Calendar: 日付 hover、クリック固定、追加、編集、削除が動く。
- Calendar: 権限不足 token は再接続扱いになる。
- Clipboard: テキスト/画像を履歴化し、クリックで再コピーできる。
- Clipboard: 画像/テキストを外部アプリへ drag/drop できる。
- Sticky Notes: 作成、編集、色変更、並び替え、archive/delete、undo が動く。
- Timer: 2 件まで同時実行でき、pause/resume/stop と終了アラートが動く。
- Calculator: 代表計算、キーボード入力、Error、copy が動く。
- AI lane は後続検討へ戻し、現行アプリの初期体験からは外す。

### 10.3 非機能テスト

- アイドル時 CPU 使用率が継続的に高止まりしない。
- Clipboard monitoring 有効時でも UI が詰まらない。
- open/close 25 回 stress 後に window が増殖しない。
- sleep/wake 後に Timer と display binding が正常に戻る。
- ネットワークなしで Calendar/Update が失敗表示になり、他 provider は使える。
- 権限拒否時にクラッシュせず、Settings 導線を出す。
- app data 破損時にクラッシュせず既定状態へ復帰する。

### 10.4 性能目標

Must:

- warm hover から空または軽量 provider のパネル表示まで 150ms 以内を目標にする。
- 通常 provider の初回表示は 500ms 以内を目標にする。
- Mirror は初回権限やデバイス初期化を除き、1 秒以内に表示を開始する。
- idle 時 CPU 使用率は低負荷を維持し、camera/mic/media preview/clipboard polling が不要時に動き続けない。

受け入れ条件:

- 100 回 open/close stress 後に window、thread、timer、camera session が増え続けない。
- 長時間常駐後も tray、hot zone、provider switching が反応する。

## 11. Windows 固有の失敗モード

Must:

- 次の失敗モードを、要件・実装・検証で明示的に扱う。

失敗モード:

- 上端 hover が、自動非表示 taskbar、Snap Layouts、全画面アプリ、RDP、mixed DPI で誤発火する、または開かない。
- 常時最前面 panel が UAC secure desktop、ゲーム、管理者権限アプリ、仮想デスクトップで前面化できない。
- Explorer 再起動後に tray icon が消える。
- camera/mic が Windows privacy、ドライバ、別アプリ使用中、仮想デバイス、デバイス抜き差しで失敗する。
- display brightness が DDC/CI、WMI、GPU、HDR、Night light、外部モニター固有仕様で取得/設定不能になる。
- media control が Windows Media Session 非対応アプリ、ブラウザタブ特定不可、保護コンテンツ、複数同時再生で不安定になる。
- clipboard が巨大画像、HTML/RTF/file clipboard、管理者/非管理者間 drag/drop、clipboard lock、企業ポリシーで失敗する。
- OAuth callback が custom URL scheme 未登録、firewall/proxy、既定ブラウザ、時計ずれで失敗する。
- update が実行中 exe の置換、アンチウイルス隔離、SmartScreen 評判、per-user/per-machine install 差で失敗する。

## 12. リリース判定チェックリスト

Windows 版を「macOS 版と同等に使える」と判断するため、初回公開前に次を満たす。

Must:

- Windows 署名済み installer/package で初回起動、更新、アンインストール、再インストールが通る。
- macOS 版 verify 相当の Windows CLI 検証がある: Calendar、Camera、Media、Calculator。
- 追加で hover/panel、Clipboard、Sticky Notes、Timer、AI lane の smoke verify がある。
- Windows 11、通常ユーザー、混在 DPI 複数モニター、camera/mic あり/なし、外部ディスプレイ、Chrome/Edge 再生で手動 E2E が通る。
- 権限拒否、ネットワーク断、破損 JSON、sleep/wake、update 失敗の復旧シナリオが通る。
- token、OAuth secret、個人情報、clipboard 本文、audit log の扱いがレビュー済みで、不要な外部送信がない。
- macOS 専用差分が残る場合は README/release notes に明記する。

## 13. 未確定事項

要確認:

- Windows 版の初期技術スタック: Windows App SDK/WinUI 3、Tauri、WebView2 hybrid のどれを採るか。
- Windows 10 対応を必須にするか、Windows 11 専用でよいか。
- Clipboard private mode を Windows 初回 MVP の Must に含めるか。
- Controls の display brightness をどこまで保証するか。DDC/CI は機種差が大きい。
- AI command lane を再投入する時期と、Windows 版 model provider を deterministic fallback のみで開始するか local LLM も初期から入れるか。
- 配布方式を MSIX、winget、installer、portable のどれにするか。
- 自動更新を Sparkle 相当の独自 updater にするか、installer/Store/winget に任せるか。
- Google の現行 macOS 実装は iOS OAuth client + custom scheme 優先だが、Windows desktop は loopback redirect + PKCE を第一候補にする。

## 14. 参考にした一次情報

リポジトリ内:

- `README.md`
- `Package.swift`
- `progress/progress.md`
- `Sources/HoverPocket/Windowing/PanelGeometry.swift`
- `Sources/HoverPocket/Windowing/PanelAnimationTiming.swift`
- `Sources/HoverPocket/Windowing/HoverWindowController.swift`
- `Sources/HoverPocket/Providers/ProviderRegistry.swift`
- `Sources/HoverPocket/Providers/*.swift`
- `Sources/HoverPocket/State/AppSettings.swift`
- `Sources/HoverPocket/State/ClipboardHistoryStore.swift`
- `Sources/HoverPocket/State/StickyNotesStore.swift`
- `Sources/HoverPocket/State/TimerStore.swift`
- `Sources/HoverPocket/State/AICommandStore.swift`
- `Sources/HoverPocket/Services/AppUpdater.swift`
- `Sources/HoverPocket/Services/GoogleOAuthService.swift`
- `Sources/HoverPocket/Services/GoogleOAuthKeychainStore.swift`
- `Sources/HoverPocket/Services/AuditLog.swift`
- `Sources/HoverPocket/Views/HoverPanelShell.swift`
- `Sources/HoverPocket/Views/ProviderHeaderView.swift`
- `Sources/HoverPocket/Views/AICommandPaletteView.swift`
- `Sources/HoverPocket/App/*VerificationCommand.swift`

外部一次情報:

- Windows App SDK API namespaces: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt
- Windows App SDK DeploymentManager.Initialize: https://learn.microsoft.com/en-us/windows/windows-app-sdk/api/winrt/Microsoft.Windows.ApplicationModel.WindowsAppRuntime.DeploymentManager.Initialize
- Windows notification area: https://learn.microsoft.com/en-us/windows/win32/shell/notification-area
- Win32 SetWindowPos: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos
- Win32 clipboard listener: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-addclipboardformatlistener
- Core Audio EndpointVolume API: https://learn.microsoft.com/en-us/windows/win32/coreaudio/endpointvolume-api
- Monitor Configuration API: https://learn.microsoft.com/en-us/windows/win32/monitor/monitor-configuration
- GlobalSystemMediaTransportControlsSessionManager: https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager
- Windows Graphics Capture: https://learn.microsoft.com/en-us/windows/apps/develop/media-authoring-processing/screen-capture
- Credential Locker: https://learn.microsoft.com/en-us/windows/apps/develop/security/credential-locker
- MSIX overview: https://learn.microsoft.com/en-us/windows/msix/overview
- Google OAuth native apps: https://developers.google.com/identity/protocols/oauth2/native-app
- WebView2 distribution: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution
- WebView2 developer guide: https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/developer-guide
- Tauri v2 system tray: https://v2.tauri.app/learn/system-tray
- Tauri v2 deep linking: https://v2.tauri.app/plugin/deep-linking
