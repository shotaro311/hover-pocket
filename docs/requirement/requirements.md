---
project_slug: hover-pocket
target: Windows version requirements
created: 2026-07-05
updated: 2026-08-13
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
- Windows 版は Controls、Calendar、Clipboard、Sticky Notes、Timer、Calculator を同じシェル内で切り替える。Mirror は Windows 版の対象外とし、macOS 版には残す。
- パネルは通常作業を邪魔せず、必要な時だけ最前面に出る。
- クリップボード、カレンダー、メディア制御などの強い権限は、明示的な状態表示、無効時の案内、最小保存で扱う。

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
- UI コンポーネント単位の色、余白、アイコンなどの詳細設計。ただし、Voice Laneの配置、表示モード、パネル寸法の不変条件は本要件で固定する。
- 永続化ファイルの最終スキーマ。
- Windows 1.0で使用する署名証明書と発行元の最終選択。

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
- Windows 0.2.xは公開ベータとし、コード署名証明書を取得するまで未署名であることをREADME、Release notes、成果物manifestへ明記する。
- Windows 1.0またはmacOS版と同等の正式版では、タイムスタンプ付きAuthenticode署名と公開成果物の署名readbackを必須にする。

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
- close 後に WebView2 やパネルの残像が残らない。
- 開閉直後にクリックが誤って下のアプリへ抜けない。

### R-UX-003: 全機能は同じポケット内で切り替わる

Must:

- Windows の Provider は `Controls`、`Calculator`、`Calendar`、`Clipboard`、`Sticky Notes`、`Timer` の順を初期登録候補にする。
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

### R-UX-005: 手操作、テキスト、音声は同じ機能を使う

Must:

- 手操作、テキスト、音声、生成Pocket Appは入力経路だけを分け、Calendar、Timer、Sticky Notes、Clipboard、Controlsなどの同じCapabilityを利用する。
- AI専用のProvider操作経路を増やさず、権限確認、実行、実行後readback、監査はHostが一元管理する。
- 生成Pocket AppはHeader、Voice Lane、承認UIを描画せず、Hostが提供するPocketSurface領域だけを描画する。

受け入れ条件:

- 同じ操作は入力経路にかかわらず、同じ実行計画、権限判断、結果receiptになる。
- AIまたは生成UIがProvider StoreやOS操作を直接呼び出せない。

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

- 以下の寸法はVoice無効時の既存`BaselinePanel`寸法として維持する。`BaselinePanelHeight = HeaderHeight + ProviderHostHeight`である。
- `Small`: 幅 520、高さ 372。
- `Medium`: 幅 600、高さ 430。
- `Large`: 幅 680、高さ 488。
- macOS版は追加で`Extra Large`: 幅 760、高さ 546を持つ。Windows版の現行3段階は変更しない。
- Header は高さ 54 を基準にする。
- Windows 版では上記を DIPs 基準で扱い、DPI scaling 後の物理ピクセルで崩れないようにする。
- Voice Lane有効時は`ShellTotalHeight = BaselinePanelHeight + VoiceLaneHeight`とする。現行Windowsコードの`ProviderHeight`はlegacy名称であり、本要件の`BaselinePanelHeight`を指す。Header 54を別途二重加算しない。
- Compact / Expanded切り替えではパネル上端と幅を維持し、増減した高さだけ下端を動かす。Voice LaneをProviderへ重ねたり、Providerを圧縮して収めたりしない。
- Voice Laneの高さはOS別design tokenとしてAN0で固定する。Windows Voice branchの`Compact=64`、`Expanded Small/Medium/Large=190/220/250`は初期値として再検証し、macOS Extra Largeを含むgolden fixtureを作る。

受け入れ条件:

- サイズ切り替え時、上端基準位置を維持したまま滑らかにリサイズする。
- Windows版はテキストサイズ`Small`、`Medium`、`Large`、macOS版は追加の`Extra Large`を含めて主要UIがはみ出さない。
- Windows の DIPs と物理ピクセルの差を吸収し、見た目のサイズ感を保つ。
- Voice Laneの`disabled / compact / expanded`を切り替えてもHeader矩形とProviderHost矩形は不変で、全体高さの差分はVoice Lane高さの差分と一致する。
- 利用可能な画面高さがExpandedの最低寸法を満たさない場合、Providerを縮めずCompactを維持し、展開できない理由を表示する。

### R-SHELL-004: 閉じる条件

Must:

- ポインターが起点またはパネル領域から離れた場合、短い delay 後に閉じる。
- 既存 macOS 版の操作感に合わせ、起点/preview の外側 4pt 相当までは hover region として許容する。
- close 判定は軽い polling で補助し、目安は 0.12 秒間隔とする。
- パネル内ドラッグを開始した場合、ドロップ先を邪魔しないようパネルを一時的に隠す。
- Settings を開く場合、hover panel を閉じる。
- Timer alert 表示中は、マウスが外へ出ても即時自動 close しない。

受け入れ条件:

- Sticky Notes の外部ドラッグで、ドラッグ元パネルがドロップ先を覆い続けない。
- パネル閉鎖中に内部 state が壊れず、再表示時に provider が正常に戻る。

### R-SHELL-005: Access window と Preview window の責務分離

Must:

- Windows 版でも、上端ホットゾーンを担当する軽量 access surface と、入力可能な preview panel surface を概念上分離する。
- access surface は常時控えめに表示し、入力可能な preview panel は開いている間だけ前面化する。
- preview panel はキーボード入力、ドラッグ、テキスト編集、Google OAuth 後の復帰を受けられる。
- Windows 版は約2秒ごとに access surface / preview panel の HWND、表示状態、必須 window style、frame を検査し、修復不能な window だけを再生成する。
- display / DPI変更、sleep復帰、session unlock / console・remote再接続では、即時・約0.45秒後・約1.4秒後に再同期とhealth checkを行う。

受け入れ条件:

- access surface だけが残っている idle 状態で、通常アプリの入力を奪わない。
- preview panel 表示中は TextBox、drag/drop、context menu、shortcut が provider に届く。
- WPFのhover通知またはnative window状態が失われても、120ms pointer pollingとhealth checkで再び開ける。

### R-SHELL-006: Voice Laneは全Provider共通の最下段に置く

Must:

- パネル構造は`Header + ProviderHost + VoiceLane`とする。Voice LaneはProvider内の要素や画面へのfixed overlayではなく、Hostが所有する通常layoutの最後のrowである。
- Voice Laneは全Providerと生成Pocket Appで同じinstanceを共有し、Provider切り替えやSurface再生成で会話sessionを作り直さない。
- Voice機能全体は既定オフとする。ユーザーが明示的に有効化した後の既定表示はCompactとし、自動listenは別の明示opt-inとする。
- `disabled / compact / expanded`の3表示モードを持つ。レーン面全体のクリックでは切り替えず、accessible nameを持つ明示的なexpand / collapse controlだけで切り替える。
- Compactには視覚的な固定タイトルを置かない。マイク、短く制限した波形、状態、直近会話1〜2行、現在root配下の表示session数、mute、expand、Voice session終了を置き、会話領域を波形より優先して伸縮させる。
- Compactには視覚タイトルがなくても、screen reader向けのVoice Lane region labelを持たせる。
- Expandedは左に現在会話のtranscript、右に現在のroot sessionと同じrootから派生したchild / descendant session cardを表示する。全過去会話の一覧、新規会話管理、削除UIは初回要件に含めない。
- session cardは安全なtitle、状態、経過時間または更新時刻、進捗、直近の安全な要約だけを表示し、raw command、filesystem path、全文transcriptを渡さない。
- Expandedはfullscreen、別Provider、Provider overlayにしない。長文と多数cardはVoice Lane内部で独立scrollし、Provider領域を縮めない。
- 書き込み承認要求と実行後receiptはHost所有のVoice Laneへ表示し、Providerまたは生成UIが同じ見た目を偽装できないようにする。
- muteは音声入出力だけを止め、child sessionをcancelしない。hoverによるパネルcloseはmuteとUI detachを行うが、明示的に終了していないroot / child taskを停止しない。Voice session終了ボタンはRealtime音声sessionだけを終了し、root / child taskは継続する。task cancelはsession card上の別操作とし、対象と影響を表示して別承認を求める。

受け入れ条件:

- すべての組み込みProviderと生成Pocket AppでVoice Laneが同じ最下段にあり、Provider切り替え後もroot session、transcript、child card状態が保持される。
- Compactには`Codex Voice`などの視覚タイトルがなく、波形は会話領域より短い。
- Expandedではパネル上端、幅、Header矩形、Provider矩形がCompact時と一致し、下端だけが下へ伸びる。
- Expandedは左transcript / 右root-scoped session cardsの2列を維持し、Smallでもcard列を自動で隠さない。必要時は情報量を減らし、列内scrollする。
- レーン背景のクリックでは表示モードが変わらず、明示controlだけが`aria-expanded`相当の状態を変更する。
- fullscreenのstate、route、buttonが存在しない。

## 4. Provider 機能要件

### 4.1 Mirror

Windows scope decision (2026-07-10):

- ユーザー判断により、Mirror と Microphone row は Windows 版の対象外とする。
- WindowsのMirror Providerと旧Microphone rowはカメラ・マイク権限、録音、camera sessionを持たない。
- Codex Voice Laneだけは別機能として、明示enable、専用permission、trusted origin、明示user gestureを満たす場合に限りマイクを利用できる。HoverPocketはraw音声を録音保存しない。
- macOS 版の Mirror 実装と配布要件は変更しない。

### 4.2 Controls

Must:

- Displays、Volume、Now Playing を縦積みのコンパクト UI として表示する。
- ディスプレイごとの明るさを表示し、対応ディスプレイではドラッグで調整できる。
- 対応していないディスプレイは `非対応` として表示し、操作を無効化する。
- 音量を取得し、調整、ミュート切り替えを実行できる。
- 再生中メディアがある場合、タイトル、ソース、アートワークまたはプレビュー、再生位置、再生/一時停止、前/次のトラック、10 秒戻し、10 秒送り、倍速操作を表示する。
- メディア操作の成功状態は、実際の状態を読み戻して表示する。
- ブラウザメディアのサムネイルをクリックすると、記録済みURLと一致するタブおよびブラウザウィンドウを前面へ出し、HoverPocketパネルを閉じる。

macOS 固有要件:

- 対象ブラウザウィンドウを取得できる場合、ScreenCaptureKit の `SCStream` を使い、30fps を基準とする低遅延ライブプレビューを表示する。
- ライブプレビューは Controls provider が表示中の間だけ起動し、非表示時は停止する。
- 画面収録権限が未許可の場合、対象ウィンドウを解決できない場合、ストリーム開始に失敗した場合、または初回フレームが2秒以内に届かない場合は、アートワークまたはプレースホルダーへ自動フォールバックする。
- 受動的なプレビュー表示から `CGRequestScreenCaptureAccess()` を呼ばず、未許可時に権限ダイアログを繰り返し表示しない。
- 描画待ちフレームは最新1枚へ集約し、UI負荷時に古いフレームが蓄積して遅延しないようにする。
- ブラウザのDOM操作が通常起動条件で拒否される場合、対象URL一致を確認してからブラウザ固有の再生速度ショートカットへフォールバックし、MediaRemoteの実再生速度が指定方向へ変化した時だけ表示へ反映する。

Windows 固有要件:

- ディスプレイ輝度は Windows 標準 API と DDC/CI の両方を候補にし、失敗時は明確に unsupported として扱う。
- メディア情報と倍速変更は Windows のメディアセッションを正本とし、0.25倍刻みで変更後の実再生速度を読み戻してから表示する。
- サムネイル操作は、再生セッションのsource/titleと一致する一意のトップレベルウィンドウだけを前面化し、成功後にHoverPocketパネルを閉じる。候補なし・複数候補・前面化失敗時は別ウィンドウを開かず、パネル内へ理由を表示する。
- Windows Graphics CaptureによるプレビューはControls provider表示中だけ起動し、非表示時は停止する。取得不能時はアートワークへフォールバックする。

受け入れ条件:

- YouTube などブラウザ再生で title/source/progress が取れる。
- macOS ではライブプレビュー検証時に完全な映像フレームを取得でき、取得不能条件ではフォールバック表示が維持される。
- Windowsでは「− / ＋」操作後の倍速がメディアセッションの読み戻し値と一致する。
- 倍速を押した直後に未確認の値を成功表示しない。
- サムネイル操作で別のメディアタブを誤って前面化しない。
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
- macOS版はCalendarの下段全幅を天気エリアとし、上段の月グリッド・予定詳細とは区切り線で分離する。下段左側へ当日の天気アイコン、状態、現在気温、最高/最低気温、降水確率、右側へ今後7日間の曜日、天気アイコン、最高/最低気温、降水確率を表示する。
- macOS版の天気地点は、明示操作による現在地取得、世界の都市・郵便番号検索、日本47都道府県の簡易選択に対応する。初期値は東京都（`13`）とし、既存の都道府県コード設定を同じ代表地点へ移行する。
- 現在地はユーザーが「現在地を使用」を実行した時だけCore Locationの許可を求める。常時追跡やバックグラウンド監視は行わない。
- 検索地点は安定した地点ID、表示名、国・行政区、国コード、緯度・経度、タイムゾーンを保存する。国や都道府県の固定リストだけに依存しない。
- APIキー不要のOpen-Meteo Geocoding APIとForecast APIを利用し、`timezone=auto`で地点の現地日付に沿った当日を含む8日分を取得する。画面内にOpen-Meteoへの帰属表示を置く。
- 温度単位は自動 / ℃ / ℉を選択できる。自動は保存地点の国コードを優先し、国コードがない現在地ではMacの地域設定を使う。
- 直近の取得結果を地点・温度単位ごとにローカル保存し、通信失敗時は保存済み予報を警告付きで表示する。保存済み予報がない場合は取得失敗と再試行を明示する。
- Open-Meteo無料APIは非商用利用条件を前提とし、商用配布へ移行する場合は有料APIまたはセルフホストへ切り替える。

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
- 上段右側の予定詳細と予定編集は、下段の天気エリアを押し下げず、表示領域を超える場合に縦スクロールできる。
- Calendarパネルを開いた時だけ、本日の天気アイコンを先に、続けて週間予報のアイコンを短い間隔で一度表示する。本日のアイコンは、macOS 15以上では晴れをRotate、晴れ時々曇りを雲固定・太陽のみRotate、曇り・霧をBreathe、雨をVariable Color、雪を下方向Wiggle、雷をPulseで表現し、約5秒で静止Viewへ置き換えて確実に停止する。macOS 14ではPulse / Variable Colorへフォールバックする。常時ループせず、Reduce Motion有効時はモーションなしで全アイコンを即時表示する。
- 週間予報は、天気アイコン固有の縦横寸法に影響されず、7日分の曜日、アイコン、気温、降水確率をそれぞれ同じY位置へ揃える。

受け入れ条件:

- 保存済み認証では再ログインなしで予定を取得できる。
- 権限不足時は再接続が必要な状態として明示する。
- 予定作成/編集/削除後、月グリッドと詳細が更新される。
- read-only calendar の予定は編集/削除できない。
- 削除前に確認を挟む。
- 世界都市検索で地点を選択でき、地点、タイムゾーン、温度単位が再起動後も復元される。
- 既存の47都道府県コード設定が同じ代表地点へ移行され、都道府県の簡易選択も継続して利用できる。
- 位置情報を拒否した場合も都市検索と都道府県選択を利用できる。
- 当日と今後7日間の予報が、macOS版のSmall / Medium / Large / Extra Largeの各パネル内へ収まる。
- 月グリッドと予定詳細・編集が下段の天気エリアへ重ならず、長い予定一覧と編集フォームを右ペイン内でスクロールできる。
- 天気アイコンは本日から週間の順で一度だけ表示され、本日の天候別効果は約5秒で静止状態へ戻り、表示完了後に消えたり再ループしたりしない。晴れ時々曇りでは雲の形を変形させず、太陽だけが回転する。
- 週間予報で晴れ、曇り、雨など高さが異なるアイコンが混在しても、曜日と各データ行が水平に揃う。
- APIへ実接続でき、オフライン時は保存済み予報または再試行表示へ切り替わる。

OS scope:

- 今回の天気表示はmacOS版を実装対象とする。
- Windows版へ展開する場合は、同じ地点保存モデル、世界都市検索、自動タイムゾーン、温度単位、当日＋今後7日間の表示項目、キャッシュ方針を共有し、現在地取得だけWindows位置情報APIで別途実装・検証する。

### 4.4 Clipboard

Must:

- テキストと画像のクリップボード履歴を表示する。
- テキスト履歴は最大 30 件、画像履歴は最大 20 件を基準にする。
- クリップボード監視は軽量に行い、既存版の目安として 0.75 秒間隔を基準にする。
- provider が有効な間だけ clipboard monitoring を開始し、provider が非表示/無効の場合は停止できる。
- 履歴項目クリックで全体プレビューを開き、コピー操作は各項目のコピーボタンから実行できる。
- テキストと画像の各履歴は、ゴミ箱ボタンから個別に削除できる。
- 通常タブはテキストと画像を中央で等分した split view、お気に入りタブはお気に入りだけを同じ split view で表示する。
- 全体プレビューでは画像全体をパネル内へ収め、テキストはスクロールして全文を読める。
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

- macOS版とWindows版は「ストップウォッチ」「タイマー」「ポモドーロタイマー」の3種類の追加カードを横並びで持つ。
- タイマーパネル内のストップウォッチは開始、一時停止、再開、停止、リセットができる。
- ストップウォッチは100分の1秒まで表示し、パネルを閉じたり別providerへ切り替えたりしてもアプリ稼働中は計測を継続する。
- 両OSの3つの追加カードは同じ高さのコンパクトな横並びとし、各パネルサイズへ収める。必要な場合だけパネル全体を縦スクロールする。
- 両OSは3カードすべてに「名前を設定（任意）」のtitle入力とcolor設定を持つ。colorは色ドット列ではなく左上の種類アイコンをクリックして変更する。Timer / Pomodoroはsound on/offも設定できる。
- 種類アイコンはストップウォッチ、砂時計、ターゲットの別形状とし、色だけに頼らず見分けられるようにする。macOS版のSF Symbolsは順に`stopwatch.fill`、`hourglass`、`target`を使う。
- 通常 Timer の既定値は 10 分、Pomodoro の既定値は work 25 分 / rest 5 分を基準にする。
- 時間は直接入力とインライン調整バーで調整できる。
- ポモドーロは work/rest を交互に切り替える。
- Pomodoro は work cycle count を表示する。
- 両OSの実行中カウントダウンは最大4つとし、複数ストップウォッチも別枠で最大4つまで同時に扱える。
- 両OSの「実行中」は1列のリストとし、ストップウォッチ、Timer、Pomodoroをtimer colorで識別できる薄い横長カードで縦に並べる。各カードは種類、設定名、残り時間または経過時間、pause / resume、stopを1行へまとめる。
- 両OSは「実行中」リストを独立したsurfaceで囲み、細いaccent lineと「新しく追加」見出しで下段の設定カードと明確に分ける。
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
- ストップウォッチ4件とカウントダウン4件を表示しても、各パネルサイズで1行カードと入力カードの内容が横にはみ出さず、必要な場合だけ縦スクロールできる。

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

### 4.8 Legacy AI command lane（Text）

Deferred:

- 旧AI command laneは計画・開発途中のため、現行アプリ UI からは一旦外す。4.9のCodex Voice Laneとは別機能として扱う。
- 旧Windows baseline roadmapのW1で検討した対象action候補はCalendar read dayとCalendar create eventであった。AI-native実装では4.9と最終実装プランのAN phaseを正本とする。
- 自然文例候補: `今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`。
- Calendar write は必ず承認 UI を通す。
- 実行結果、失敗、承認/却下は audit log に記録する。

Windows 代替要件:

- Apple Foundation Models は Windows では使えないため、AI provider は差し替え可能にする。
- 初期 Windows MVP では deterministic fallback だけでもよいが、旧AI command laneのUIは現行アプリからは一旦外す。
- 将来の local LLM または cloud LLM 接続は、カレンダー書き込みの承認原則を変えない。

受け入れ条件:

- Calendar read は承認なしで実行できる。
- Calendar create は承認しない限り実行されない。
- 失敗時に token や個人情報をログへ出さない。

### 4.9 Codex Voice Laneと共通Capability

Planned Must:

- Codex Voice Laneは4.8の旧テキストAI command laneを再表示するものではなく、R-SHELL-006に従う全Provider共通の入力・会話面とする。
- Calendar、Timer、Sticky Notes、Clipboard、Controls、Calculatorを`PocketCapability`として登録し、既存UI、Voice、Text、生成Pocket App、MCP Adapterが同じRegistryとBrokerを使う。
- Capability Registryを操作契約の単一正本とし、MCPは外部公開Adapterとして扱う。
- Capability Brokerを唯一の実行入口とし、schema検証、権限、承認、idempotency、実行、readback、監査、rollbackを一元管理する。
- 最初の縦断はToday Focus Pocketとする。今日のCalendar予定を読み、選択した予定に合わせてTimerを開始し、Sticky Notesへ今日の目的を保存する。
- Today FocusのCalendar readは承認不要、TimerとStickyへの書き込みは正確な引数を提示して承認し、IDで実行後readbackする。
- `calendar.event.create`は毎回書き込み前承認を求め、作成後にevent IDを取得してGETまたは同等queryでreadbackする。
- Voice、Text、生成Surface、macOS SwiftUIとWindows Calendar WebView双方の「選択予定から集中を開始」は同じcanonical workflow planをBrokerへ送る。
- current rootとそのchild / descendant session cardだけを表示する。全履歴browser、new / delete / archive管理は初回対象外とする。
- Pocket Appはmanifest、data schema、layout、workflow、permissions、testsをユーザーが確認・変更・削除・rollbackできるファイルとして保持する。
- 生成UIはauthoritative data、secret、重要処理を所有せず、削除・再生成してもユーザーの意図とデータが残る。
- Pocket Appのinstall / update / enable / disable / remove / rollbackは、Lifecycleの保存状態だけで成功にしない。Hostが検証済みimmutable packageを`PocketSurfaceRegistry`と実行runtimeへ反映し、同じapp ID、version、package digest、permission grantが描画・実行側でも観測できた後だけ成功receiptを返す。
- 生成Pocket Appはapp IDごとに独立したSurface / runtime entryとして登録する。任意の生成Appを組み込みToday Focusの固定slotへ差し替えない。
- 実Codex生成とactivationは、ローカルファイル読取り隔離と上記runtime activation readbackをmacOS / Windows双方で満たすまでfail closedとする。
- AI生成した任意native codeの即時hot installは本番要件にしない。native権限追加はworktree、review、署名、通常releaseを必須にする。

受け入れ条件:

- Voice、Text、既存UI、PocketSurfaceの同一要求が同じCapability ID、canonical plan digest、effect、承認判断、readback semanticsになる。receipt固有のID、時刻、originは入力ごとに異なってよい。
- 書き込み前は副作用がなく、成功表示は実行後readback一致を根拠にする。
- Pocket App lifecycleの成功receiptと、`PocketSurfaceRegistry` / execution runtimeが観測するapp ID、version、digest、permission grantが一致する。再起動後も一致し、disable / remove時は対象entryが実行不能、rollback / enable時は選択した検証済みentryが実行可能である。
- Codex、MCP、生成UIからProvider StoreまたはBridgeDispatcherへ直接到達できない。
- raw transcript、Calendar / Sticky本文、Clipboard本文、token、filesystem pathを監査ログへ残さない。
- Voice機能を無効にした場合、Codex process、microphone、WebRTC、追加レイアウトが起動せず、既存パネル寸法とProvider体験が変わらない。

## 5. Settings 要件

Must:

- UI language: Japanese / English。
- Display placement: Main / Sub / All。
- Panel size: Small / Medium / Large。
- Panel text size: Small / Medium / Large。
- macOS版はPanel size / Panel text sizeへExtra Largeを追加する。Windows版の現行3段階は変更しない。
- Provider switching: Click / Hover。
- Provider visibility: provider ごとの ON / OFF。
- Provider order: 並び替え。
- Provider selection: 前回開いた provider を優先するか、固定 default provider を使うか。
- Handle icon: B / C / None 相当。
- Top handle side area: 表示 / 非表示。
- Sticky Notes undo toast: 表示 / 非表示。
- Sticky Notes grid size: S / M / L。
- Calendar weather location: Current Location / worldwide city or postal code / Japanese prefecture。
- Calendar weather temperature unit: Auto / Celsius / Fahrenheit。
- Codex Voice Lane: OFF / ON。既定はOFF。
- Codex Voice Lane layout: Compact / Expanded。機能を有効にした直後の既定はCompact。
- Auto listen: OFF / ON。既定はOFFとし、Voice Lane有効化とは別に承認する。
- Check for Updates。

Windows 追加 Must:

- Start with Windows。
- Pause Clipboard Monitoring / Private Mode。
- Disable top-edge trigger while full-screen app is active。
- Reset panel position and display binding。
- Open data folder。

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
- クリップボード読み書きと、画像履歴のローカルPNG保存・個別削除。
- Windows 音量取得/設定/ミュート。
- Windows media session 読み取りと再生制御。未対応アプリには fallback を設計する。
- ディスプレイ輝度操作と unsupported fallback。
- Google OAuth は desktop loopback + PKCE を基本線にし、必要に応じて custom URI scheme を追加する。
- Credential Manager などの資格情報保存。
- ETW/EventSource または rotating file log などの診断ログ。
- 自動更新または更新通知。
- Windows 0.2.x公開ベータでは、署名状態を成果物manifestへ記録し、未署名時のSmartScreen警告を利用者へ明示する。
- Windows 1.0またはmacOS版と同等の正式版では、Authenticode署名付きで配布する。

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

- Controls、media、DDC/CI、Credential Manager などは Rust/Win32 側の実装品質が成否を握る。
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
- 最初の実装検証では、top-edge overlay、tray、多画面 DPI、Clipboard履歴保存・個別削除、Controls API の 5 点を spike する。

## 9. Windows基盤のMVPと段階的リリース

この章の`W0〜W4`は既存Windows基盤を構築した履歴上のroadmapである。AI-native最終計画の`AN0〜AN8`とは別namespaceとし、今後のAI-native実装順は`docs/plan/20260813_PLAN1.md`を正本とする。

### W0: 技術検証

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

### W1: 低 OS 依存 provider

Must:

- Calculator。
- Timer。
- Sticky Notes。
- Settings。

理由:

- HoverPocket の日常利用感を早く確認できる。
- OS 依存が比較的少なく、UI シェルの品質検証に向く。

### W2: Clipboard と Calendar

Must:

- Clipboard history。
- Google Calendar read/write。
- OAuth/credential storage。
- Private mode。

理由:

- 実用性が高いが、プライバシーと認証の設計が必要。

### W3: Controls

Must:

- Volume。
- Display brightness。
- Now Playing。
- Browser media fallback。

理由:

- OS 依存が強く、個別の Windows API 検証が必要。

### W4: 配布と更新

Must:

- Windows 0.2.x公開ベータでは、署名状態、checksum、OAuth metadata、feed versionをreadbackできるinstaller/package。
- Windows 1.0またはmacOS版と同等の正式版では、タイムスタンプ付きAuthenticode署名済みinstaller/package。
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
- Voice OFFでは現在のパネル寸法、起動process、microphone requestが変わらない。
- Voice ONでは全Provider共通のCompactが最下段へ表示され、Provider切り替え後も会話sessionが保持される。
- Compactから明示controlでExpandedへ切り替えると、Provider矩形を変えずパネル下端だけが下へ伸びる。
- macOSのSmall / Medium / Large / Extra LargeとWindowsのSmall / Medium / Largeで、off / compact / expandedのgeometry fixtureが通る。
- `OS × size × built-in Provider / generated PocketSurface fixture × off/compact/expanded`の直積でShell contractを検査する。

### 10.2 Provider E2E

- Controls: 音量/ミュートが実 OS 状態と一致する。
- Controls: unsupported display brightness が安全に無効化される。
- Controls: ブラウザ動画の再生情報と倍速が読み戻し確認される。
- Calendar: 保存済み認証で予定が取得される。
- Calendar: 日付 hover、クリック固定、追加、編集、削除が動く。
- Calendar: 権限不足 token は再接続扱いになる。
- Clipboard: テキスト/画像を履歴化し、全体プレビュー、コピー、お気に入り、個別削除ができる。
- Clipboard: 通常/お気に入りタブと、中央で等分したテキスト/画像 split view が崩れない。
- Sticky Notes: 作成、編集、色変更、並び替え、archive/delete、undo が動く。
- Timer: 両OSでカウントダウン4件 + ストップウォッチ4件まで同時実行でき、各項目のpause/resume/stopと終了アラートが動く。
- Calculator: 代表計算、キーボード入力、Error、copy が動く。
- Legacy AI command laneは後続検討へ戻し、現行アプリの初期体験からは外す。
- Codex Voice Laneは既定OFFとし、AI-native releaseでR-SHELL-006と4.9の受け入れ条件を満たした場合だけ明示enable可能にする。

### 10.3 非機能テスト

- アイドル時 CPU 使用率が継続的に高止まりしない。
- Clipboard monitoring 有効時でも UI が詰まらない。
- open/close 25 回 stress 後に window が増殖しない。
- sleep/wake 後に Timer と display binding が正常に戻る。
- ネットワークなしで Calendar/Update が失敗表示になり、他 provider は使える。
- 権限拒否時にクラッシュせず、Settings 導線を出す。
- app data 破損時にクラッシュせず既定状態へ復帰する。
- Voice Expandedの長文、0 / 1 / many child cards、mixed DPI、短い画面でもProviderを圧縮・被覆しない。
- Voice mute、hover close、Voice session終了がそれぞれ定義どおり動き、hover closeだけでchild taskをcancelしない。
- Reduce Motion、keyboard、screen reader、日本語 / 英語でCompact / Expandedを操作できる。

### 10.4 性能目標

Must:

- warm hover から空または軽量 provider のパネル表示まで 150ms 以内を目標にする。
- 通常 provider の初回表示は 500ms 以内を目標にする。
- idle 時 CPU 使用率は低負荷を維持し、media preview/clipboard polling が不要時に動き続けない。

受け入れ条件:

- 100 回 open/close stress 後に window、thread、timer が増え続けない。
- 長時間常駐後も tray、hot zone、provider switching が反応する。

## 11. Windows 固有の失敗モード

Must:

- 次の失敗モードを、要件・実装・検証で明示的に扱う。

失敗モード:

- 上端 hover が、自動非表示 taskbar、Snap Layouts、全画面アプリ、RDP、mixed DPI で誤発火する、または開かない。
- 常時最前面 panel が UAC secure desktop、ゲーム、管理者権限アプリ、仮想デスクトップで前面化できない。
- Explorer 再起動後に tray icon が消える。
- display brightness が DDC/CI、WMI、GPU、HDR、Night light、外部モニター固有仕様で取得/設定不能になる。
- media control が Windows Media Session 非対応アプリ、ブラウザタブ特定不可、保護コンテンツ、複数同時再生で不安定になる。
- clipboard が巨大画像、HTML/RTF/file clipboard、管理者/非管理者間 drag/drop、clipboard lock、企業ポリシーで失敗する。
- OAuth callback が custom URL scheme 未登録、firewall/proxy、既定ブラウザ、時計ずれで失敗する。
- update が実行中 exe の置換、アンチウイルス隔離、SmartScreen 評判、per-user/per-machine install 差で失敗する。

## 12. リリース判定チェックリスト

Windows 版を「macOS 版と同等に使える正式版」と判断するため、1.0公開前に次を満たす。0.2.x公開ベータはこのチェックリストを未達のまま正式版扱いしない。

Must:

- Windows 署名済み installer/package で初回起動、更新、アンインストール、再インストールが通る。
- macOS 版 verify 相当の Windows CLI 検証がある: Calendar、Controls/Media、Calculator。
- 追加でhover/panel、Clipboard、Sticky Notes、Timer、Codex Voice Laneのsmoke verifyと、Legacy AI command laneが非表示・default-offのままmountされないことを確認するnegative regression verifierがある。
- Windows 11、通常ユーザー、混在 DPI 複数モニター、外部ディスプレイ、Chrome/Edge 再生で手動 E2E が通る。
- 権限拒否、ネットワーク断、破損 JSON、sleep/wake、update 失敗の復旧シナリオが通る。
- token、OAuth secret、個人情報、clipboard 本文、audit log の扱いがレビュー済みで、不要な外部送信がない。
- macOS 専用差分が残る場合は README/release notes に明記する。

## 13. 未確定事項

要確認:

- Windows 版の初期技術スタック: Windows App SDK/WinUI 3、Tauri、WebView2 hybrid のどれを採るか。
- Windows 10 対応を必須にするか、Windows 11 専用でよいか。
- Clipboard private mode を Windows 初回 MVP の Must に含めるか。
- Controls の display brightness をどこまで保証するか。DDC/CI は機種差が大きい。
- Codex Voice Laneの標準runtime providerをCodex app-serverのpower-user mode、OpenAI Realtime / BYOK、別providerのどれにするか。Capability契約はruntimeから独立させる。
- session cardから別アプリへ移動する方式。対応APIを実測できるまでLane内詳細を既定にし、必要時の`codex resume <threadId>`は明示承認付き代替候補とする。
- user-owned Pocket App workspaceの既定場所。初回に可視folderを選択できる方針を第一候補にする。
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
