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
- Apple Account のアプリ用パスワードを使い、`hover-pocket` notarytool Keychain profile を作成。
- 作成済み profile を `xcrun notarytool history --keychain-profile hover-pocket` で検証。
- `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh` を実行し、Apple notarization、staple、staple後ZIP再生成、SHA256 / appcast 再生成、ZIP展開後検証まで完了。
- アプリ用パスワードはチャットやファイルに出力せず、Keychain profile 保存後にクリップボードを空にした。

## 成果物

- App: `dist/HoverPocket.app`
- ZIP: `dist/releases/HoverPocket-0.1.0-41.zip`
- SHA256: `dist/releases/HoverPocket-0.1.0-41.zip.sha256`
- Appcast: `dist/releases/appcast.xml`
- Notary submission ID: `dd941d6b-7078-4d6a-94a7-c5a0f8697637`
- Notary status: `Accepted`
- ZIP SHA256: `362a6fcea234f3faf8b19eb5df625b48594eb573fc3fb5f79a765ff8ffd0986e`

## 検証

- `swift build`: 成功。
- `swift build`: Sticky Notes UI 追加後に再実行し、警告なしで成功。
- `git diff --check -- Sources/HoverPocket/Models/StickyNoteModels.swift Sources/HoverPocket/State/StickyNotesStore.swift Sources/HoverPocket/Providers/StickyNotesProvider.swift Sources/HoverPocket/Providers/ProviderRegistry.swift Sources/HoverPocket/State/AppSettings.swift Sources/HoverPocket/Views/SettingsView.swift Sources/HoverPocket/Views/StickyNotesView.swift`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`dist/HoverPocket.app` を Apple Development 署名で再署名し、起動確認まで成功。
- `xcrun notarytool history --keychain-profile hover-pocket --output-format json --no-progress`: 成功。
- `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh`: 成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- `xcrun stapler validate dist/HoverPocket.app`: `The validate action worked!`
- `spctl --assess --type execute --verbose=2 dist/HoverPocket.app`: `accepted`, `source=Notarized Developer ID`
- `dist/releases/HoverPocket-0.1.0-41.zip` を一時ディレクトリへ展開し、展開後 `HoverPocket.app` でも `codesign`、`stapler validate`、`spctl` が成功。

## 残り

- notarized ZIP、`.sha256`、`appcast.xml` を GitHub Releases へ公開する。
- 公開URL経由でダウンロードしたZIPを別環境または quarantine 付きで開き、Gatekeeper の最終挙動を確認する。
- GitHub Releases 公開後、Sparkle の手動更新確認を実機で確認する。
