---
project_slug: hover-menu-preview
updated: 2026-06-09
updated_by: codex
status: active
---

# Project Progress: ノッチポッケ

## 概要

- `ノッチポッケ` は、macOS 画面上部のノッチ付近へホバーすると、ミラー、Google Calendar、Clipboard 履歴を素早く開ける prototype app。
- `/Users/shotaro/Documents/Codex/.../outputs/hover-menu-preview` で作成した prototype を、開発継続用に `/Users/shotaro/code/share/hover-menu-preview` へ移行済み。

## 最新の検証済み状態

- 移行元 prototype は `./script/build_and_run.sh --verify` 成功済み。
- 移行先 `/Users/shotaro/code/share/hover-menu-preview` で `./script/build_and_run.sh --verify` 成功済み。
- 2026-06-03: 上部 pill の 5pt top inset を削除し、`CGWindowListCopyWindowInfo` で `Y = 0` を確認済み。
- 2026-06-03: preview panel の opening animation を追加し、`optionOnScreenOnly` の frame sampling で `h=199 -> 267 -> 297 -> 308 -> 312` への拡大を確認済み。
- 2026-06-03: pill を top corners square / bottom corners rounded の top-docked shape に変更し、window 切り出しで確認済み。
- 2026-06-03: pill height を 33pt に伸ばし、下端の細い隙間を抑えたことを切り出し画像と window frame で確認済み。
- 2026-06-03: notch sizing と `33pt = safeAreaInsets.top + 1pt` の設計メモを `README.md` に記録済み。
- 2026-06-03: 二段階の `neck / elastic overshoot` animation はもっさり見えたため撤回し、直前の `source -> final` のシンプルなノッチ中央 morphing に戻したことを確認済み。
- 2026-06-03: preview close animation を open と同じ `0.32s` にし、timing curve も open の逆カーブにして、開く動きの逆再生として閉じることを frame sampling で確認済み。
- 2026-06-03: top pill の text / session count 表示を消し、ノッチ左側の小さい `arrow.right` handle だけを表示する状態に変更済み。
- 2026-06-03: `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` から実ノッチ幅を取り、left handle 右端をノッチ左端へ揃えて、ノッチ裏まで黒い UI base を敷くように変更済み。
- 2026-06-03: top pill の shadow を無効化し、上端 `3pt` を黒で overfill して、上部の細いスリット状の抜けを埋めたことをピクセル検査で確認済み。
- 2026-06-03: 左上 handle のラウンド形状変更は意図と違ったため撤回し、元の連続した黒ベース形状へ戻したことを確認済み。
- 2026-06-03: `main.swift` の単一ファイル構成を App / Windowing / State / Models / Providers / Views / Support に分割し、今後の追加機能を `NotchProvider` として差し込む土台へ変更。デモ用 sessions / usage 表示は削除済み。
- 2026-06-03: Display placement 設定を追加。`Auto / Main / Sub` で表示先を選べるようにし、ノッチなし画面では fake notch ではなく top-center handle に切り替えるよう変更済み。
- 2026-06-04: Built-in `Mirror` provider を追加し、panel active 中だけ Mac camera を起動する鏡機能を実装。`swift build`、`./script/build_and_run.sh --verify`、`NSCameraUsageDescription`、hover 後 panel onscreen を確認済み。
- 2026-06-04: Mirror hover 時の crash を修正。原因は camera session start と preview layer attach の race。preview layer 常駐化、4秒 warm grace、`vga640x480` preset、OSLog を追加。hover stress 後も process 生存、該当例外なし、close 後 CPU 0% を確認済み。
- 2026-06-04: Mirror close 時の点滅 / 残像対策として、close animation 中は content を維持し、window `orderOut` 後に `contentVisible=false` にする順序へ変更。open / close window state と crash 例外なしを確認済み。
- 2026-06-04: Mirror の軽快化として、見た目の animation は維持したまま、`contentVisible` と provider active state を分離。camera access 許可済みなら app launch 時に session 構成だけ prewarm し、`startRunning()` は hover active 時だけに限定。`.eventDriven` provider の panel open refresh も skip するように変更。`swift build`、`./script/build_and_run.sh --verify`、hover in/out metadata、crash 例外なしを確認済み。
- 2026-06-04: Mirror 表示のカクつき / ちらつき対策を追加。camera preview layer の layout 時に暗黙 Core Animation を無効化し、開閉 animation 中だけ preview window shadow を切るように変更。閉じかけからの再 hover では collapsed frame へ戻さず、現在の frame / alpha から開き直す。live camera への SwiftUI blur も削除。`swift build`、`./script/build_and_run.sh --verify`、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: Mirror が UI 枠より遅れて表示される問題を修正。preview window animation 開始前に `contentVisible=true` を非アニメーションで反映し、ミラー映像が枠の clip と同時に広がるように変更。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: close 時にカメラ映像の残像が残る問題を抑えるため、close animation 開始時点で `providerActive=false` にし、panel 本体より先に camera preview を fade out するように変更。camera preview fade は `0.12s -> 0.06s` に短縮。`swift build`、`./script/build_and_run.sh --verify`、open/close metadata、idle CPU 0%、crash 例外なしを確認済み。
- 2026-06-04: 繰り返し open / close 後にもっさりする体感への処理系対策を追加。close fallback reset task を単一管理して古い task を cancel、`contentVisible` / `providerActive` / camera status の同値 publish を抑制、同一 provider 選択を no-op 化、close delay task の参照を実行後に解放。25 cycle stress 後も pill window 1枚へ復帰し、warm grace 後 CPU 0.0%、crash 例外なしを確認済み。
- 2026-06-04: `GoogleCalendarProvider` を追加。Google installed app OAuth の loopback redirect + PKCE、Keychain token保存、Calendar API `calendarList.list` / `events.list`、月グリッド + 日付hover詳細UI、Settings の connect / disconnect 導線を実装。`swift build`、`./script/build_and_run.sh --verify`、dummy OAuth値の `Info.plist` 注入、loopback socket port確保、callback早着対策、setup check、crash 例外なしを確認済み。gcloud / Calendar API は設定済み。`gcloud iam oauth-clients` と既存gcloud tokenではCalendar OAuth検証に使えないことも確認済み。実Googleアカウント取得には OAuth desktop client ID 設定が必要。
- 2026-06-04: `shotaro.matsu0311@gmail.com` のChrome `Default` profileで Google Auth Platform の Desktop OAuth client を作成し、`.env.local` に client ID / secret を保存。実OAuth consent、Keychain保存、Calendar API取得まで検証済み。`./script/verify_google_calendar.sh --force-google-sign-in` は `calendar_sources=5`、`events_in_visible_grid=53`、`days_with_events=37`、`today_events=3`。保存済み認証での再取得も `used_login_flow=false` で成功。`./script/build_and_run.sh --verify`、`git diff --check`、起動後 `CPU 0.0%`、直近crash例外なしを確認済み。
- 2026-06-07: Google Calendar の日付クリック詳細固定、予定追加、編集、削除 UI と Calendar API 書き込み処理を追加。OAuth scope を `calendar.events` に変更し、古い read-only credential は再接続が必要な状態として扱うようにした。`swift build`、`./script/check_google_calendar_setup.sh`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。実Googleアカウントの write scope 追加同意は OAuth callback 待ちで未完了。
- 2026-06-07: Clipboard provider を追加。テキスト/画像 clipboard 履歴、画像の Application Support 保存、クリック再コピー、外部アプリへの drag/drop provider を実装。provider の表示/非表示、順番、最後に開いた panel / default panel 設定を追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。起動後 CPU 0.0% を確認。
- 2026-06-07: Codex chat 欄への画像 drag/drop が効かない報告を受け、drag 開始直後に hover panel を一時非表示にし、画像 drag payload を file URL 起点の `NSItemProvider` に変更。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: Mirror provider に A案ベースの compact microphone check row を追加。設定で表示/非表示を切替可能。Mirror microphone row 表示中は `AVAudioEngine` で meter を自動起動し、panel 非表示/非active/設定OFFで停止。button は一時録音用に変更し、`録音 -> 停止 -> 再生 -> 再生完了後にメモリから削除` の流れにした。audio file は作成しない。`NSMicrophoneUsageDescription` を generated app bundle に追加。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-07: アプリ名を `ノッチポッケ` に決定。SwiftPM package / executable / generated app bundle を `NotchPokke` に変更し、bundle 表示名を `ノッチポッケ` に設定。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。`.env.local` は ignore 済みで、公開対象 tracked files に実OAuth値やtokenがないことを確認。GitHub public repository `shotaro311/notch-pokke` へ push 済み。
- 2026-06-07: README を日本語中心へ全面更新。概要、機能、実行方法、Google Calendar 設定、表示先、実装メモ、ノッチサイズ、注意事項を日本語で読めるようにした。
- 2026-06-08: パネルを開いたまま provider アイコンを切り替えると機能だけ切り替わりアイコン選択状態が更新されない問題を修正。ヘッダーを `ProviderStore` 監視の `ProviderHeaderView` に分離。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- 2026-06-08: GitHub Actions `Codex PR Router` を追加。PR作成/更新/レビュー時に変更ファイルを分類し、Mac worker 向け origin / autofix / human merge / docs-only auto-merge safe ラベルを付ける。trusted author の docs-only PR だけ auto-merge 有効化を試みる。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows 両方へ配置。Mac / Windows Codex Automation を毎日 10:00 / 12:00 / 15:00 / 18:00 / 21:00 に設定し、対象PRがない場合は軽量チェックだけで終了する運用にした。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。`.github/*.md` の docs-only 誤判定も修正し、Mac / Windows plugin へ反映済み。
- 2026-06-08: PR `#2` で表示領域サイズを `小 / 中 / 大` の3段階に切り替える機能を追加。Settings とパネル見出し右側の `小 中 大` ボタンから変更でき、表示中のパネルはイージング付きで `456 x 326pt / 520 x 372pt / 600 x 430pt` にリサイズされることを実ウィンドウフレームで確認済み。
- 2026-06-08: PR `#2` の追加修正として、ヘッダーのサイズ表示を現在サイズ1文字だけに変更。サイズ変更時は上端 `Y = 33` を維持することを実ウィンドウフレームで確認。今後のPR作成運用も Mac / Windows ともに Draft ではなく Ready PR 前提へ変更済み。
- 2026-06-09: 上部ヘッダー右端の電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings で `Icon switching` を `Click / Hover` から選べるようにし、`Hover` ではアイコンにポインタを重ねた時点で provider が切り替わる。追加でヘッダーUIを `ProviderHeaderView.swift` へ分離し、`ProviderStore` の設定監視を provider 構成関連に限定。`swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。

## 進行中

- Codex: `ノッチポッケ` として GitHub public repository へ公開済み。`Mirror` provider は crash / 重さ / close 残像 / ちらつき / UI 枠との同期 / 繰り返し開閉時の処理蓄積対策まで実装済み。provider アイコン切替時のヘッダー選択状態更新バグも修正済み。`Calendar` provider は Google account login、calendarList、events.list、日付別イベント抽出まで実アカウントで検証済み。追加で予定追加、編集、削除の API / UI は実装済みで、write scope の再接続待ち。`Clipboard` provider は text/image 履歴、local image 保存、再コピー、drag/drop まで実装済み。パネル表示領域は `小 / 中 / 大` で切替可能で、ヘッダーには現在サイズ1文字だけを表示する。上部ヘッダーの電源アイコンは廃止済みで、provider アイコン切替は Settings から `Click / Hover` を選択できる。GitHub PR の自動分類と Mac / Windows Codex Automation による自動修正運用の入口動作も実PRで確認済み。

## 次アクション

- `./script/build_and_run.sh --verify` で移行先の build / launch を確認する。
- Mirror の初回 permission UX と表示品質を調整する。
- Calendar provider の初回表示UXと日付hover詳細の見た目を実画面で微調整する。
- Calendar provider の write scope 追加同意後、一時イベントの作成・編集・削除を実アカウントで確認する。
- Clipboard provider の text/image drag/drop を、Finder / Slack / browser input など複数アプリで手動確認する。
- Clipboard image drag/drop を Codex chat 欄で再確認する。
- アプリ化の要件を決める: 終了/自動起動、Google OAuth consent screen、設定項目、今後追加する provider。
- 次の本物のレビューコメント付きPRで、Codex Automation がレビュー内容を読んで修正commitを積むところまで確認する。

## Blocker / Risk

- 現時点はローカル prototype。署名、notarization、LaunchAgent、自動起動は未実装。
- 初回 camera permission はユーザー操作が必要。
- 自動検証では顔が写る映像確認は避けている。ユーザー側で mirror 映像の見え方確認が必要。
- 機密情報や token は含めていない。
- `.env.local` には Google OAuth client ID / secret が入っているため、値を出力せず、repo に含めない。
- Google OAuth consent screen が Testing の場合、登録済み test user のみログイン可能。一般公開には Google OAuth app verification が必要になる可能性がある。
- Calendar event 書き込みには `calendar.events` scope が必要。既存の read-only token では再接続が必要。
- Clipboard history は機密テキストも拾えるため、今後は除外ルール、保存期間設定、private mode を追加する余地がある。
- Microphone meter は Mirror microphone row 表示中に自動起動する。初回 permission prompt は手動操作が必要。
- 再ビルド後の ad-hoc 署名では camera / microphone permission prompt が再表示されることがある。配布時は安定した署名で確認する。

## 引き継ぎ

- Project root: `/Users/shotaro/code/share/hover-menu-preview`
- GitHub: `https://github.com/shotaro311/notch-pokke`
- Run: `./script/build_and_run.sh --verify`
- Product name: `ノッチポッケ` / `NotchPokke`
- UI source: `Sources/HoverMenuPreview/Views/`
- Windowing source: `Sources/HoverMenuPreview/Windowing/`
- Provider source: `Sources/HoverMenuPreview/Providers/`

## 重要パス

- Project root: `.`

## 詳細ログ

- [2026-06-09](2026-06/2026-06-09_hover-menu-preview.md)
- [2026-06-08](2026-06/2026-06-08_hover-menu-preview.md)
- [2026-06-07](2026-06/2026-06-07_hover-menu-preview.md)
- [2026-06-04](2026-06/2026-06-04_hover-menu-preview.md)
- [2026-06-03](2026-06/2026-06-03_hover-menu-preview.md)
- [2026-06-02](2026-06/2026-06-02_hover-menu-preview.md)

## 旧進捗ソース

- 一時成果物: `/Users/shotaro/Documents/Codex/2026-06-02/files-mentioned-by-the-user-2026/outputs/hover-menu-preview`

## 移行検証後の削除候補

- [cleanup-candidates.md](cleanup-candidates.md)

## 最近の更新

- 2026-06-07: Calendar provider に日付クリック固定、予定追加、編集、削除 UI / API を追加。OAuth scope は `calendar.events` に変更し、既存 read-only credential は再接続扱いにした。
- 2026-06-07: Clipboard provider と provider 表示/順番/default panel 設定を追加。
- 2026-06-07: Clipboard image drag の drop 互換性改善として、panel 一時非表示と file URL provider を追加。
- 2026-06-07: Mirror 下に compact microphone check row と Settings toggle を追加。
- 2026-06-07: Microphone permission 許可直後の crash を修正。CoreAudio tap closure を MainActor から分離し、権限待ち中に panel が閉じた場合は後から mic を起動しないようにした。
- 2026-06-07: Microphone meter 無反応対策として、input tap を `outputFormat(forBus:)` に変更し、dBFS ベースの感度へ調整。
- 2026-06-07: Microphone meter を Mirror 表示中に自動起動する仕様へ変更。右端 button は一時録音/停止/再生にし、再生完了後にメモリ上の録音を削除する。
- 2026-06-07: Microphone button 操作後に panel が閉じない問題を修正。preview 表示中だけ window controller 側で mouse location を監視して hover exit 取りこぼしを補完し、open animation 中の mouse event 無効時間を短縮。録音ボタンの hit area も 30pt に拡大。
- 2026-06-07: アプリ名を `ノッチポッケ` に決定し、SwiftPM package / executable / generated app bundle の公開名を `NotchPokke` へ変更。bundle 表示名は `ノッチポッケ`。
- 2026-06-07: GitHub public repository `shotaro311/notch-pokke` を作成し、`main` を push。`gh repo view` で visibility `PUBLIC` を確認。
- 2026-06-07: README を日本語中心へ更新し、公開 GitHub のトップで概要と使い方が伝わる状態にした。
- 2026-06-08: provider アイコン切替時のヘッダー未更新バグを修正。`ProviderHeaderView` が `ProviderStore` を直接監視する構成に変更。
- 2026-06-08: `Codex PR Router` workflow を追加し、ハイブリッド自動修正運用の GitHub 側分類を導入。
- 2026-06-08: `github-codex-autofix` plugin を Mac / Windows に配置し、両環境で Codex Automation を設定。Windows 側は peer 経由で zip SHA 一致、script 存在、`list-targets` 対象なしを確認。
- 2026-06-08: 実PR `#1` で `Codex PR Router` のラベル付与、Mac helper の対象PR検出、claim / release、Windows helper の Mac向けPR除外を確認。検証PRはマージせず閉じ、テストブランチは削除済み。
- 2026-06-08: PR `#2` でパネル表示領域の `小 / 中 / 大` サイズ切替を追加。ヘッダーの `小 中 大` ボタンと Settings の `Panel size` picker から変更できる。
- 2026-06-08: PR `#2` のサイズボタンを現在サイズ1文字表示へ変更し、サイズ変更時の上端固定を確認。Mac / Windows のPR作成手順も Ready PR 前提へ更新。
- 2026-06-09: 上部ヘッダーの電源アイコンを廃止し、provider アイコン群と設定ボタンの間に薄い縦線の仕切りを追加。Settings の `Icon switching` で `Click / Hover` を選べるようにした。リファクタリングとして `ProviderHeaderView.swift` を分離し、`ProviderStore` の不要な設定変更再通知を減らした。
- 2026-06-04: Mirror close 時の点滅対策として、content 非表示化を window `orderOut` 後へ移動。
- 2026-06-04: Mirror の軽快化として、camera prewarm / provider active 分離 / eventDriven refresh skip を追加。見た目の animation は変更なし。
- 2026-06-04: Mirror のカクつき / ちらつき対策として、camera preview layer の暗黙 animation 無効化、animation 中 shadow off、閉じかけ再 hover の frame snap 防止、live camera への blur 削除を追加。
- 2026-06-04: Mirror が UI 枠より遅れて追従する問題に対応し、content reveal を window animation 完了後ではなく開始前へ移動。
- 2026-06-04: Mirror close 時の camera 残像対策として、close 開始時に provider active を落とし、camera preview fade を短縮。
- 2026-06-04: 繰り返し開閉時の処理系改善として、reset task 単一管理、同値 publish 抑制、camera active 重複通知抑制、provider select no-op を追加。
- 2026-06-04: `GoogleCalendarProvider`、Google OAuth loopback + PKCE、Keychain token保存、Calendar API client、月表示 + 日付hover詳細UI、Settings接続導線を追加。
- 2026-06-04: Google Calendar を実Googleアカウントで接続し、Calendar APIから予定取得できることを確認。
- 2026-06-04: Mirror の crash を修正し、preview layer 常駐化、4秒 warm grace、`vga640x480` preset で軽量化。
- 2026-06-04: Built-in `Mirror` provider を追加し、Mac camera の鏡プレビューを実装。
- 2026-06-03: 二段階の neck / overshoot animation を撤回し、直前の軽い morphing に戻した。
- 2026-06-03: preview close animation を open animation の逆再生に調整。
- 2026-06-03: top pill を文字なしの左側 arrow handle 表示へ変更。
- 2026-06-03: top pill の黒ベースを実ノッチ幅に合わせ、ノッチ裏の隙間を解消。
- 2026-06-03: top pill 上端のスリット状の抜けを黒 overfill で解消。
- 2026-06-03: 左上 handle のラウンド形状変更を撤回し、元の形へ復帰。
- 2026-06-03: Provider/Registry/Store の基盤を追加し、デモ用 sessions / usage 表示を削除。
- 2026-06-03: 設定ウィンドウを追加し、表示先を `Auto / Main / Sub` から選べるように変更。
- 2026-06-03: preview morphing を上部ノッチ中央から出て、上部ノッチ中央へ戻る動きに調整。
- 2026-06-03: notch sizing / point-pixel compensation の設計メモを README に追記。
- 2026-06-03: pill の下端の隙間を抑えるため、pill height を 33pt に調整。
- 2026-06-03: pill の上左右を丸めず、画面上面に接する top-docked design に調整。
- 2026-06-03: preview panel が pill 下端に接した小さいカプセルから液体的に広がる opening animation を追加。
- 2026-06-03: 上部 pill の位置を画面上端へ合わせ、余白 0pt に調整。
- 2026-06-02: Prototype app を `/Users/shotaro/code/share/hover-menu-preview` に移行し、開発用 Git repository と `.gitignore` を用意。
- 2026-06-02: 共通進捗管理を初期化。
