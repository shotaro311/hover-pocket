---
project_slug: hover-menu-preview
date: 2026-06-20
updated_by: codex
status: active
---

# 2026-06-20 hover-menu-preview

## 実施内容

- Sticky Notes の data/provider/settings 実装を追加。
- `StickyNoteItem` / `StickyNoteColor` と `StickyNotesStore.shared` を追加し、`Application Support/HoverPocket/StickyNotes/notes.json` へ JSON 永続化する構成にした。
- archive/delete の undo action、active notes の sortIndex 順、Settings の `Show undo after note actions` toggle、built-in provider registry 接続を追加。
- UI worker 側の `StickyNotesView.swift` 実装と store/provider API の接続を確認。
- `StickyNotesView.swift` に Pattern 1 Board Grid、hover archive、inline expanded editor、color swatches、context menu、drag reorder、外部 drag text payload、undo toast UI を追加。
- 親側レビューで inline editor をフル幅行へ展開する構造に変更し、選択付箋が拡大して周囲の付箋が行単位で避けるようにした。空タイトル時は本文1行目を見出し代わりにし、本文プレビューの重複表示を抑制。
- Sticky Notes の追加修正として、drag reorder 後にカードが薄い状態で残る問題を防ぐ drop reset、Ctrl+Enter の編集確定、付箋外クリックで一覧へ戻る挙動、別付箋クリック時の編集切替前保存、色スウォッチのダブルクリック新規作成、付箋グリッドサイズ `S/M/L` 切替を追加。
- Sticky Notes UI をリファクタリングし、`StickyNotesView.swift` の責務を root state / action / layout に絞った。カード、ヘッダー、色スウォッチ、サイズ切替、Undo toast、empty state は `StickyNoteComponents.swift`、drop delegate と grid metrics は `StickyNoteDropDelegates.swift` へ分離。
- Sticky Notes の drag UX を改善。drag reorder 中は JSON 保存を行わず、drop/reset 時にまとめて保存することでカクつきを抑えるようにした。
- 付箋ドラッグ中はホバーウィンドウ内にいる間は閉じず、マウスポインタがホバーウィンドウ外へ出た時点で既存の外部ドラッグ閉じ処理へ渡すようにした。
- 新規作成した付箋でタイトル/本文が空のまま確定された場合は、付箋を保存せず破棄するようにした。
- 付箋ドラッグ中に下部ゴミ箱エリアを表示し、ゴミ箱アイコンへドロップすると対象付箋をアーカイブできるようにした。
- top pill の handle icon を Settings から `B / C / None` で選べるようにした。ノッチに合わせた pill / preview の geometry は変更せず、`HoverPillView` の中央アイコン描画だけを切り替える構成にした。
- top pill のノッチ横 handle area を Settings から表示/非表示にできるようにした。実ノッチありのときだけ横 handle 幅を外せるようにし、ノッチ本体側の黒い領域と preview center は維持する構成にした。
- Apple Account のアプリ用パスワードを使い、`hover-pocket` notarytool Keychain profile を作成。
- 作成済み profile を `xcrun notarytool history --keychain-profile hover-pocket` で検証。
- `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh` を実行し、Apple notarization、staple、staple後ZIP再生成、SHA256 / appcast 再生成、ZIP展開後検証まで完了。
- アプリ用パスワードはチャットやファイルに出力せず、Keychain profile 保存後にクリップボードを空にした。
- 最新コミット `1744fe3` を build `45` として配布するため、`APP_VERSION=0.1.0 APP_BUILD=45 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh` を実行。
- publish 処理で Apple notarization、staple、staple後ZIP再生成、SHA256 / appcast 再生成、GitHub Release `v0.1.0-45` 作成まで完了。
- build `41` を一時展開して起動し、Settings > Updates > Check for Updates から Sparkle が build `45` を検出することを確認。`Install Update`、`Install and Relaunch` 後、一時展開 app の `CFBundleVersion` が `45` へ更新されたことを確認。
- README を現在の `ホバーポケット` / `HoverPocket`、Sticky Notes、AI command lane、handle icon / notch side handle 設定、notarized GitHub Release、Sparkle 更新済みの状態へ更新。
- `docs/report/20260610-hoverpocket-local-cloud-llm-architecture.md` に 2026-06-20 時点の AI native Phase 1 実装状況を追記。
- `script/publish_github_release.sh` の既定 release notes を、初回配布向け文言から一般 release 向け文言へ更新。
- GitHub Release の `Source code (zip)` をユーザーがアプリZIPと誤認しやすい問題に対応。README に `HoverPocket-macOS-app.zip` を一般ユーザー向け download として明記し、`Source code` は開発者向けであることを追記。
- `script/publish_github_release.sh` が今後の release で app-only の分かりやすい alias asset `HoverPocket-macOS-app.zip` も upload するように変更。Sparkle 用の versioned ZIP / SHA256 / appcast は維持。
- ZIP 作成を `ditto --norsrc --keepParent` へ変更し、解凍時に `__MACOSX` がトップレベルに出ないようにした。build `45` の公開 asset も同じ形式で差し替えた。
- Google OAuth credential を Data Protection Keychain へ保存するように変更。旧 file-based Keychain 項目は認証UIなしで読める場合だけ移行し、読めない場合はKeychainパスワードダイアログを出さずGoogle再ログインへ誘導する。
- macOS menu bar に HoverPocket の status item を追加。メニューから `Open HoverPocket`、`Settings...`、`Check for Updates`、`Quit HoverPocket` を実行できるようにした。
- Mirror の camera denied / restricted 表示に `Open Camera Settings` を追加。microphone permission が off の場合は mic row の右端ボタンから Microphone Privacy 設定へ進めるようにした。Calendar の未接続 / 再接続CTAは Google login を開く文言にした。
- コミット `8a4489d` を build `51` として配布。初回の publish script 実行では notarytool submit が詳細なしで失敗したため、ZIP / Keychain profile / Developer ID 署名を確認後、単体 `xcrun notarytool submit` を再実行して `Accepted` を取得。staple、ZIP / appcast 再生成、GitHub Release `v0.1.0-51` 公開まで完了。

## 成果物

- App: `dist/HoverPocket.app`
- ZIP: `dist/releases/HoverPocket-0.1.0-41.zip`
- SHA256: `dist/releases/HoverPocket-0.1.0-41.zip.sha256`
- Appcast: `dist/releases/appcast.xml`
- Notary submission ID: `dd941d6b-7078-4d6a-94a7-c5a0f8697637`
- Notary status: `Accepted`
- ZIP SHA256: `362a6fcea234f3faf8b19eb5df625b48594eb573fc3fb5f79a765ff8ffd0986e`
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-45`
- Latest ZIP: `dist/releases/HoverPocket-0.1.0-45.zip`
- Latest ZIP SHA256: `f2b33a63235f2bf7ca61490f1bebec4905bc462cc3af399aa3b0d6bc101eec82`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- Latest notary submission ID: `e536914a-b908-47e5-9389-8796658492ca`
- Latest notary status: `Accepted`
- Release 51: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-51`
- Release 51 ZIP: `dist/releases/HoverPocket-0.1.0-51.zip`
- Release 51 ZIP SHA256: `ca9c21fe9f8be9e4d7517227504e3d72b1a0c71c6285f372a40817cac00cd96b`
- Release 51 notary submission ID: `17e76b3f-36d5-4caf-b714-474ec42854aa`
- Release 51 notary status: `Accepted`

## 検証

- `swift build`: 成功。
- `swift build`: Sticky Notes UI 追加後に再実行し、警告なしで成功。
- `git diff --check -- Sources/HoverPocket/Models/StickyNoteModels.swift Sources/HoverPocket/State/StickyNotesStore.swift Sources/HoverPocket/Providers/StickyNotesProvider.swift Sources/HoverPocket/Providers/ProviderRegistry.swift Sources/HoverPocket/State/AppSettings.swift Sources/HoverPocket/Views/SettingsView.swift Sources/HoverPocket/Views/StickyNotesView.swift`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`dist/HoverPocket.app` を Apple Development 署名で再署名し、起動確認まで成功。
- `swift build`: Sticky Notes 追加修正後に成功。
- `git diff --check`: Sticky Notes 追加修正後に成功。
- `./script/build_and_run.sh --verify`: Sticky Notes 追加修正後に成功。
- `swift build`: Sticky Notes UI リファクタリング後に成功。
- `swift build`: Sticky Notes drag UX 改善後に成功。
- `git diff --check`: Sticky Notes drag UX 改善後に成功。
- `./script/build_and_run.sh --verify`: Sticky Notes drag UX 改善後に成功。`dist/HoverPocket.app` を Apple Development 署名で再署名し、起動確認まで成功。
- `swift build`: top pill handle icon 設定追加後に成功。
- `git diff --check`: top pill handle icon 設定追加後に成功。
- `./script/build_and_run.sh --verify`: top pill handle icon 設定追加後に成功。`dist/HoverPocket.app` を Apple Development 署名で再署名し、起動確認まで成功。
- `swift build`: top pill handle area 表示設定追加後に成功。
- `git diff --check`: top pill handle area 表示設定追加後に成功。
- `./script/build_and_run.sh --verify`: top pill handle area 表示設定追加後に成功。`dist/HoverPocket.app` を Apple Development 署名で再署名し、起動確認まで成功。
- `xcrun notarytool history --keychain-profile hover-pocket --output-format json --no-progress`: 成功。
- `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh`: 成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- `xcrun stapler validate dist/HoverPocket.app`: `The validate action worked!`
- `spctl --assess --type execute --verbose=2 dist/HoverPocket.app`: `accepted`, `source=Notarized Developer ID`
- `dist/releases/HoverPocket-0.1.0-41.zip` を一時ディレクトリへ展開し、展開後 `HoverPocket.app` でも `codesign`、`stapler validate`、`spctl` が成功。
- `APP_VERSION=0.1.0 APP_BUILD=45 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: 成功。
- GitHub Release `v0.1.0-45`: ZIP、SHA256、`appcast.xml` の3 asset が公開済み。
- `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: 200で取得でき、`sparkle:version` は `45`、enclosure は `v0.1.0-45/HoverPocket-0.1.0-45.zip`。
- remote ZIP / SHA256 readback: GitHub Releases から取得した `.sha256` と ZIP の `shasum -a 256` が一致。
- Sparkle EdDSA signature: remote appcast の `sparkle:edSignature` と remote ZIP を `sign_update --account hover-pocket --verify` で検証し成功。
- remote ZIP 展開後 app: `CFBundleVersion=45`、`codesign --verify --deep --strict`、`xcrun stapler validate`、`spctl --assess --type execute` 成功。
- Sparkle manual update: build `41` を一時展開して起動し、Settings > Updates > Check for Updates で build `45` の更新ダイアログを確認。Install/Relaunch 後に一時展開 app の `CFBundleVersion=45` を確認。
- README / docs / current progress で古い名称や未整備記述が消えていることを確認。旧名称は migration code と詳細履歴ログにのみ残す。
- `git diff --check`: README / docs / progress / release notes 更新後に成功。
- `bash -n script/publish_github_release.sh`: README / docs 更新後の release notes 文言変更に対して成功。
- `swift build`: README / docs 更新後にも成功。
- remote `HoverPocket-0.1.0-45.zip` の payload 確認: top-level は `HoverPocket.app` のみで、アプリ外ファイルなし。
- GitHub 自動生成の Source code ZIP 確認: `Package.swift`、`progress/`、`Sources/` などを含むため、ユーザー向け download としては不適切。
- `bash -n script/publish_github_release.sh`: `HoverPocket-macOS-app.zip` alias upload 対応後に成功。
- `git diff --check`: README / publish script / progress 更新後に成功。
- `ditto --norsrc --keepParent` の一時ZIP検証: top-level は `HoverPocket.app` のみ。展開後 app の `codesign`、`stapler validate`、`spctl` が成功。
- `APP_VERSION=0.1.0 APP_BUILD=45 PUBLISH_DRY_RUN=1 ./script/publish_github_release.sh`: top-level が `HoverPocket.app` のみの ZIP で成功。
- `APP_VERSION=0.1.0 APP_BUILD=45 PUBLISH_PREPARE_RELEASE=0 ./script/publish_github_release.sh`: GitHub Release `v0.1.0-45` に `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-45.zip`、SHA256、`appcast.xml` を upload 済み。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip` を再ダウンロードし、top-level が `HoverPocket.app` のみ、SHA256 が `f2b33a63235f2bf7ca61490f1bebec4905bc462cc3af399aa3b0d6bc101eec82` であることを確認。
- `swift build`: Keychain / menu bar / permission CTA 実装後に警告なしで成功。
- `git diff --check`: Keychain / menu bar / permission CTA 実装後に成功。
- `./script/build_and_run.sh --verify`: app bundle 再生成、Apple Development 署名、起動確認まで成功。
- `codesign -dvvv --entitlements :- dist/HoverPocket.app`: bundle ID `local.codex.hover-pocket`、Apple Development 署名を確認。
- `plutil -p dist/HoverPocket.app/Contents/Info.plist`: `CFBundleIconFile=AppIcon`、Camera / Microphone usage description、Google Sign-In client ID の注入を確認。
- `xcrun notarytool history --keychain-profile hover-pocket --output-format json --no-progress`: Keychain profile が有効で過去 submission を読めることを確認。
- `xcrun notarytool submit dist/releases/HoverPocket-0.1.0-51.zip --keychain-profile hover-pocket --wait --timeout 30m --output-format json`: submission `17e76b3f-36d5-4caf-b714-474ec42854aa` が `Accepted`。
- `xcrun stapler staple dist/HoverPocket.app`、`codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`xcrun stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=2 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `dist/releases/HoverPocket-0.1.0-51.zip` 展開後 app の `codesign`、`stapler validate`、`spctl`: 成功。
- `APP_VERSION=0.1.0 APP_BUILD=51 PUBLISH_PREPARE_RELEASE=0 ./script/publish_github_release.sh`: GitHub Release `v0.1.0-51` 作成成功。
- `gh release view v0.1.0-51 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-51.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip` を再ダウンロードし、top-level が `HoverPocket.app` のみ、SHA256 が `ca9c21fe9f8be9e4d7517227504e3d72b1a0c71c6285f372a40817cac00cd96b` であることを確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `51`、enclosure が `v0.1.0-51/HoverPocket-0.1.0-51.zip` であることを確認。

## 残り

- 別Macまたは quarantine 付きダウンロードで、初回起動時の Gatekeeper UX を確認する。
