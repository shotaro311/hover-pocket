---
project_slug: hover-menu-preview
date: 2026-07-13
updated_by: codex
status: released
---

# 2026-07-13 HoverPocket メディア操作・ライブプレビュー改善

## 依頼

- 再生ボタンなどが1回目のクリックで反応しないことがある問題を修正する。
- 前のトラック、次のトラックへ移動するボタンを追加する。
- 実際に再生中の動画を ScreenCaptureKit で低遅延表示する。
- 画面収録権限が未許可、または取得に失敗した場合はサムネイル表示へフォールバックする。

## 実施内容

- `MediaRemoteAdapterClient` が状態購読に使う常駐 loop process の stdin pipe を保持し、再生/停止、シーク、前/次のトラック操作を同じ process へ即時送信するようにした。
- stream が停止中または利用できない場合は、既存の one-shot process と直接 MediaRemote 呼び出しへフォールバックする。
- 再生/停止操作は stdin への書き込み成功だけで pending を解除せず、stream から期待した再生状態が返った時点で成功確定するようにした。
- stream 通知が欠けた場合は 1.5 秒後に現在状態を readback し、楽観表示や pending が残り続けないようにした。
- Controls に前のトラック `backward.end.fill`、次のトラック `forward.end.fill` を追加した。
- 冒頭へ戻る操作のアイコンを `arrow.counterclockwise` へ変更し、トラック移動と区別した。
- メディアボタンを 32pt、再生/停止の主ボタンを 34pt に広げ、透明部分を含む矩形全体をクリック領域として明示した。
- 日本語・英語のヘルプ文言と `docs/requirement/requirements.md` を同期した。
- media verify が UI と同じ adapter stream 経路で toggle を検証するようにし、使用 transport を readback へ追加した。

### ライブプレビュー

- 0.75秒ごとの `SCScreenshotManager` 静止画更新を廃止し、対象ブラウザウィンドウを `SCStream` で392×220・30fpsキャプチャするようにした。
- `CMSampleBuffer` が持つ IOSurface を `NSViewRepresentable` 内の CALayer へ直接描画し、毎フレームの `NSImage` 変換をなくした。
- MainActorへ積む描画待ちフレームは最新1枚へ集約し、UI負荷時も古いフレームが蓄積しないようにした。
- Controls thumbnail はアートワーク／プレースホルダーを常に背面表示する。画面収録未許可、window IDなし、window解決失敗、stream開始失敗、初回2秒以内のframe未到達、stream停止時はライブ層を透明に戻して自動フォールバックする。
- 画面収録権限はpreflightだけを確認し、受動表示から許可ダイアログを再要求しない既存方針を維持した。
- `--verify-live-preview` と `--verify-live-preview-fallback` を追加し、完全frame数とライブ／フォールバック経路をreadbackできるようにした。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名済み `dist/HoverPocket.app` を起動した。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-panel-layout`: `panel_layout_verify=ok`、63ケース成功。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-media --toggle-playback`: `media_toggle_transport=adapter_stream`、`media_toggle_verified=true`、`media_verify=ok`。検証後は元の再生状態へ戻った。
- 署名済みアプリのControls GUIで、再生中YouTubeのプレビュー表示を確認した。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-media --toggle-playback --verify-live-preview`: 0.7秒で完全frame 22枚、`media_live_preview_mode=live`、`media_live_preview_active=true`、`media_toggle_verified=true`、`media_verify=ok`。検証後は元の再生状態へ戻った。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-media --verify-live-preview-fallback`: `media_live_preview_mode=fallback_no_window`、`media_live_preview_fallback=true`、`media_live_preview_verified=true`、`media_verify=ok`。

## 配信

- 実装commit `01fb33d`を`origin/main`へpushし、macOS build `127`として配信した。
- Apple公証submission `453cc3ff-3033-4d43-b544-8d457c5d8508`は`Accepted`。Developer ID署名、staple、Gatekeeper評価に合格した。
- GitHub Release `v0.1.0-127`をGitHub Latestとして公開し、macOS専用`macos-latest`のZIPとappcastもbuild `127`へ更新した。
- 公開URLから再取得したZIPのSHA-256は`6dda40d9b9d2012b80f2e25398131b2fa1c265a43cc3f982ada58cb3f515056c`でローカル成果物と一致した。
- 公開ZIP展開後の`CFBundleVersion=127`、`CFBundleShortVersionString=0.1.0`、macOS専用`SUFeedURL`、`codesign`、`stapler validate`、`spctl`を確認した。
- macOS専用appcastとGitHub Latest経由のlegacy appcastは、どちらもbuild `127`とversioned ZIP URLを返した。tagとHEADはcommit `01fb33d`で一致し、`HEAD...origin/main`は`0/0`だった。

## 未実施

- 前/次ボタンによる実際の選曲変更はユーザーの再生キューを変更するため自動実行していない。コマンド経路とadapter対応はbuildとsource readbackで確認した。
