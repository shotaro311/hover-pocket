---
project_slug: hover-menu-preview
date: 2026-06-19
updated_by: codex
status: active
---

# 2026-06-19 hover-menu-preview

## 実施内容

- 決定したアプリアイコン画像を `Resources/AppIcon.png` として追加。
- `script/build_and_run.sh` に `Resources/AppIcon.png` から `AppIcon.icns` を生成して `dist/HoverPocket.app/Contents/Resources/` へ入れる処理を追加。
- generated `Info.plist` に `CFBundleIconFile=AppIcon` を追加。
- Mirror camera の起動/停止競合を修正。4秒遅延停止が再ホバー後に古い停止命令として完了しても、世代番号で stale stop を検出し、active intent が残っている場合は再起動する。
- `isSessionRunning` のキャッシュだけを見て start を省略しないようにし、実セッションが止まっている可能性がある場合でも start command を通すようにした。
- 一般配布向けに `script/notarize_release.sh` を追加。ZIP作成、`notarytool submit --wait`、`stapler staple` / `validate`、`spctl` 検証、staple後の再ZIP、SHA256 / appcast 再生成までを1コマンド化した。
- `script/publish_github_release.sh` が未notarized ZIPを再生成して公開しないよう、既定では `script/notarize_release.sh` を呼ぶ構成へ変更。既存artifactを使う場合もZIP展開後に `codesign`、`stapler validate`、`spctl` で検証する。
- README の ZIP アプリ作成セクションに、`notarytool store-credentials` で Keychain profile を作る手順と `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh` を追記。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched` を確認。
- `plutil -p dist/HoverPocket.app/Contents/Info.plist`: `CFBundleIconFile => AppIcon` を確認。
- `file dist/HoverPocket.app/Contents/Resources/AppIcon.icns`: `Mac OS X icon` を確認。
- 一時的に起動時 provider を `mirror` にして、実マウス移動で hover open / close を5サイクル実行。各 cycle で preview window が開き、最後の再openも成功。
- 検証後、`lastSelectedProvider=clipboard-history`、`preferredProvider=google-calendar` へ戻した。
- `log show --last 3m` で `exception` / `crash` / `fatal` / `stale camera stop` に該当する HoverPocket ログなし。
- 検証後 process は生存し、`ps` で CPU `0.0%` を確認。
- `bash -n script/notarize_release.sh`: 成功。
- `NOTARIZE_BUILD=0 ./script/notarize_release.sh`: notarization credentials 未設定時に秘密情報なしの説明つきエラーで停止することを確認。
- `NOTARYTOOL_PROFILE=hover-pocket ./script/notarize_release.sh`: `hover-pocket` profile 未作成時に package / ZIP 再生成前の credential validation で停止することを確認。
- `PUBLISH_DRY_RUN=1 PUBLISH_REQUIRE_NOTARIZED=0 ./script/publish_github_release.sh`: 成功。既存artifactを確認するだけで publish しないことを確認。
- `PUBLISH_DRY_RUN=1 ./script/publish_github_release.sh`: 既存ZIPを展開し、`stapler validate` で ticket 未添付を検出して停止することを確認。
- `xcrun notarytool history --keychain-profile hover-pocket`: `No Keychain password item found for profile: hover-pocket`。この環境では実notarization送信に必要な認証 profile が未作成のため、Apple notarization の実送信と staple 成功確認は未実行。

## 変更ファイル

- `Resources/AppIcon.png`
- `script/build_and_run.sh`
- `script/notarize_release.sh`
- `script/publish_github_release.sh`
- `README.md`
- `Sources/HoverPocket/Views/MirrorPreviewView.swift`
- `progress/progress.md`
- `progress/2026-06/2026-06-19_hover-menu-preview.md`
