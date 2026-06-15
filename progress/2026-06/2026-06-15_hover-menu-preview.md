---
project_slug: hover-menu-preview
date: 2026-06-15
updated_by: codex
status: active
---

# 2026-06-15 HoverPocket progress

## 実装

- AI command palette を preview 表示時に自動フォーカスするよう修正。
- Apple Foundation Models 対応環境では `@Generable` 型で structured output を受ける経路を追加し、非対応環境では既存 fallback を維持。
- Calendar write 承認プレビューに、予定名・日時・カレンダーを一瞬で読める summary を追加。構造化フィールド一覧は省略せず維持。
- Calendar event editor の日付/時刻入力を `DatePicker` から手入力可能な数値セグメント UI へ変更。
- 日付/時刻セグメントはフォーカス時に調整バーを表示し、左右ドラッグで値を変更できるようにした。
- Calendar の日付セルをダブルクリックすると、その日の新規予定 editor を直接開くようにした。
- Product Compass レポートを `product-compass-reports/2026-06-15-hoverpocket-ai-pocket.html` に生成し、6/22 の伊勢田さん向け検証方針を整理。
- AI command の deterministic shortcut をモデル実行より優先し、`今日の予定`、`明日14時 打ち合わせ`、`金曜 デザイン納期`、`来週月曜10時 撮影 場所: 天神` の検証入力に寄せて強化。
- Calendar write 承認 summary に場所とメモも表示し、構造化フィールドの順序をタイトル、日時、場所、メモ、カレンダーへ調整。
- 6/22 の観察チェックリストを `progress/2026-06/2026-06-22_calendar-pocket-validation.md` に追加。
- 配布検証用に `script/package_zip.sh` を追加。Developer ID Application 証明書があれば hardened runtime / timestamp 付きで署名し、`ditto -c -k --sequesterRsrc --keepParent` で ZIP を作成する。
- `script/build_and_run.sh` に `CFBundleShortVersionString` / `CFBundleVersion` を追加し、配布用 app bundle に Google OAuth client secret を埋め込まない方針へ変更。
- Sparkle 2.9.3 を SwiftPM で追加し、起動時に `AppUpdater` を初期化。Settings に `Check for Updates` を追加。
- `script/build_and_run.sh` で `Sparkle.framework` を `Contents/Frameworks` へ同梱し、実行ファイルへ `@executable_path/../Frameworks` rpath を追加。
- Sparkle EdDSA 公開鍵を `SUPublicEDKey`、GitHub Releases の latest appcast URL を `SUFeedURL` として app bundle へ注入するようにした。秘密鍵は macOS Keychain の `hover-pocket` アカウントに保存。
- `script/generate_appcast.sh` と `script/publish_github_release.sh` を追加し、GitHub Releases へ ZIP / SHA256 / appcast を公開できる土台を追加。
- 初期配布では差分更新ファイルの公開漏れを避けるため、Sparkle appcast は delta update を生成せずフルZIP更新だけにした。
- Sparkle 更新確認の公開前エラー対策として、ローカル開発ビルドでは `SPARKLE_FEED_URL` を明示した場合だけ `SUFeedURL` を入れるよう変更。配布ビルドでは appcast 取得を事前確認し、404 などの場合は Sparkle の汎用エラーダイアログではなく Settings の状態表示に留めるようにした。
- Sparkle updater は起動時に自動開始せず、手動更新確認で appcast 取得確認が通った後だけ開始するようにした。
- Calendar 日時セグメントの数値調整UIは、A案のインライン目盛りバーを採用。フォーカス中の数値に黄色枠を出し、直下に目盛り付きルーラーと黄色ノブを表示して、バー自体も左右ドラッグで調整できるようにした。
- Calendar 日時セグメントの調整バーが小さく操作しづらかったため、目盛り幅、バー高さ、ノブサイズ、ドラッグ判定領域を拡大した。
- Calendar 調整バー表示時に日時フィールドの横位置が崩れないよう、バーの横幅を通常レイアウト計算から外してオーバーレイ表示へ変更。ドラッグ中のノブは連続移動にし、バー上のマウススクロールでも日時を調整できるようにした。
- Calendar 調整バーは選択数字の直下へ移動させず、日時入力レーン内の固定位置に1つだけ表示する仕様へ変更。対象数字は黄色枠で示す。
- Google Calendar OAuth を配布前提で安全側へ調整。配布バンドルでは OS 既定ブラウザで Google ログインを開く。Chrome profile / remote debugging 指定は明示的な開発オプションに限定。
- Google sign out 時にローカルKeychain削除だけでなく Google revoke endpoint へ refresh token の取り消しを送るようにした。Keychain の refresh token 保存属性はこのMac限定へ変更。
- Google Cloud に HoverPocket 専用 project / OAuth consent app を作成し、Google Calendar API を有効化。OAuth 同意画面のアプリ名は `HoverPocket`、support/contact email は `shotaro.matsu0311@gmail.com` に設定。
- OAuth consent app は Testing のため、`shotaro.matsu0311@gmail.com` を test user に追加。未追加時に出ていた `403: access_denied` はこの設定不足が原因。
- Google Calendar OAuth を、iOS OAuth client + custom URL scheme + PKCE + `ASWebAuthenticationSession` のネイティブ認証フローへ変更。refresh token は既存の自前 Keychain store に保存する。
- Desktop OAuth fallback は `GOOGLE_OAUTH_ENABLE_LEGACY_FALLBACK=1` のときだけ `Info.plist` に注入するようにし、通常の配布 app bundle には client secret を入れない構成にした。

## 検証

- `swift build` 成功。
- `git diff --check` 成功。
- `./script/build_and_run.sh --verify` 成功。
- Computer Use / System Events で handle クリックを試したが、この環境では hover panel を開くイベントを再現できず、実画面での崩れ確認は未完了。
- Product Compass レポート追加後、`docs: Product Compassレポートを追加` をコミット済み。
- 一時 Swift 検証で、上記4入力がそれぞれ `2026-06-15 read`、`2026-06-16 14:00 打ち合わせ`、`2026-06-19 all-day デザイン納期`、`2026-06-22 10:00 撮影 / 場所: 天神` に解釈されることを確認。
- `./script/package_zip.sh` 成功。`dist/releases/HoverPocket-0.1.0-30.zip` を作成し、ZIPから `dist/releases/extract-test/HoverPocket.app` へ展開して `codesign --verify --deep --strict` と起動確認に成功。
- 作成した app は Developer ID Application 署名と hardened runtime 付きだが、notarization 未実施のため `spctl` は `Unnotarized Developer ID` と判定する。
- Sparkle.framework 同梱後に `./script/build_and_run.sh --verify` 成功。`dist/releases/appcast.xml` は最新ビルド1件だけを含み、Sparkle EdDSA signature 付き enclosure を生成できることを確認。
- `dist/releases/appcast.xml` が未アップロードの delta file を参照しないことを確認。
- GitHub Releases latest の `appcast.xml` は現時点で HTTP 404。これが更新確認時の Sparkle 汎用エラーの直接原因であることを確認。
- Sparkle 修正後に `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。ローカル開発ビルドの `Info.plist` に `SUFeedURL` が入らないことを確認。
- Sparkle 修正後に `./script/package_zip.sh` 成功。配布ZIP生成では `SUFeedURL` を明示的に入れた app bundle と `appcast.xml` を生成できることを確認。
- Calendar 日時セグメントのA案UI修正後に `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Calendar 調整バー拡大後に `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Calendar 調整バーのオーバーレイ化、スムーズ化、スクロール対応後に `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Calendar 調整バー固定位置化後に `swift build`、`git diff --check`、`./script/build_and_run.sh --verify` 成功。
- Google OAuth client secret はGit管理ファイルに含めず、生成 app bundle の `Info.plist` にだけ入ることを確認済み。Chrome profile 指定は標準では `Info.plist` に入らないことを確認済み。
- `./script/verify_google_calendar.sh` 成功。実Googleログインフローが開き、Calendar API取得まで `google_calendar_verify=ok`、`used_login_flow=true` で確認。
- 生成 app bundle の `Info.plist` に `GIDClientID` / `CFBundleURLTypes` が入り、`GoogleOAuthClientID` / `GoogleOAuthClientSecret` は入らないことを確認。
- `./script/verify_google_calendar.sh --force-google-sign-in` 成功。`google_calendar_verify=ok`、`used_login_flow=true`、`calendar_sources=5`、`events_in_visible_grid=68`。
- 保存済み credential で `./script/verify_google_calendar.sh` 成功。`used_login_flow=false`、`calendar_sources=5`、`events_in_visible_grid=68`。
- `./script/check_google_calendar_setup.sh` 成功。`google_ios_oauth_client_id=set`、`.env.local` gitignore OK。

## 残課題

- 実機操作で、AI command palette の自動フォーカス、Calendar 日付ダブルクリック、日時セグメントの手入力/ドラッグ調整、承認プレビュー表示を確認する。
- Apple Foundation Models の `@Generable` 経路は macOS 26 / Apple Intelligence 対応SDKと実機で追加確認が必要。
- 一般配布前に Apple notarization と Sparkle 更新フィードのホスティング先を決める。
- GitHub Releases への実公開は未実行。notarization 完了後に `script/publish_github_release.sh` で公開する。
- GitHub Releases へ appcast を公開した後、実際の Sparkle 更新成功フローを手動確認する。
