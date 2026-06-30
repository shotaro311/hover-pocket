# 2026-07-01 HoverPocket 修正・配信ログ

## 依頼

- 画面サイズを小にした際の Calendar UI 崩れを修正する。
- 画面収録とシステムオーディオの権限を有効にしても何度も求められる問題を修正する。
- メディア操作の不安定さを修正する。再生停止ボタンのラグ、倍率調整が反応しないこと、倍率数値が変わらないことを改善する。
- サブエージェントを使い、PDCA で実装から配信まで進める。

## 実施内容

- `GoogleCalendarPreviewView` に panel size 別の `CalendarPreviewMetrics` を追加した。
- 小サイズでは Calendar grid の幅、セルサイズ、余白、spacing、font を縮小し、月タイトルに `minimumScaleFactor` を追加した。
- `ControlsWindowPreviewStore` の画面収録確認を preflight-only に変更し、受動的なサムネイル表示では `CGRequestScreenCaptureAccess()` を呼ばないようにした。
- ScreenCaptureKit の screenshot 設定で `capturesAudio = false`、macOS 15 以降は `captureMicrophone = false` を明示した。
- live thumbnail の更新間隔を `0.25s` から `0.75s` に落とし、メディア操作中の AppleScript / ScreenCaptureKit 競合を軽減した。
- `ControlsStore` に play/pause と playback rate の pending state と command task を追加し、操作を直列化した。
- 操作直後の全量 refresh で stale な media state が戻る経路を避け、再生情報だけを遅延 readback するようにした。
- Dia の `focus browserTab` 経路では JavaScript readback を待たず、YouTube shortcut の 0.25 刻みを想定値として扱うようにした。
- 倍速表示は 0.25 刻みの場合に `1.25x` のような2桁表示へ切り替えるようにした。
- `--verify-media --set-playback-rate` の delta を現在速度基準に修正し、requested rate と一致した場合だけ exact verified にした。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。`HoverPocket launched` を確認。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- `codesign -d --entitlements :- dist/HoverPocket.app`: camera / audio-input / apple-events entitlements を確認。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-media`: `media_verify=ok`。
- `--verify-media --set-playback-rate 1.25`: `media_playback_rate=1.25`、`media_verify=ok`。
- `--verify-media --set-playback-rate 1.0`: `media_playback_rate=1.0`、`media_verify=ok`。
- Dia / YouTube では `--set-playback-rate 1.1` が 0.25 刻みの fallback により `1.25` へ変化し、exact requested rate ではないため `media_verify=failed` になることを確認。未確認の exact 反映を成功扱いしない。

## 配信

- Code commit: `72d8ff9` (`Controlsの小サイズ表示とメディア操作を安定化`)。
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-83`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-83.zip`
- SHA256: `cb7062eb9a8ce00b65fba56de8e9eb08a1a2c735ec47205310ff7db781ae4dae`
- Notary submission ID: `5bd53681-39cb-4821-8167-ca7bc4e74241`
- Notary status: `Accepted`

## 配信後 readback

- `gh release view v0.1.0-83 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-83.zip`、SHA256、`appcast.xml` の4 asset を確認。
- `curl -fsSL https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `83`、enclosure が `v0.1.0-83/HoverPocket-0.1.0-83.zip` を指すことを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-83.zip | awk -F/ '{print $1}' | sort -u`: top-level が `HoverPocket.app` のみ。
- `shasum -a 256 -c dist/releases/HoverPocket-0.1.0-83.zip.sha256`: 成功。
- `git ls-remote --tags origin v0.1.0-83`: tag が commit `72d8ff9` を指すことを確認。

## 残リスク

- Dia は AppleScript JavaScript 実行が無効な通常起動では exact `1.1x` のような 0.1 刻み反映を外部から確認できない。YouTube shortcut fallback では 0.25 刻みになる。
- macOS 側の直接 ScreenCaptureKit access に対する定期的な OS 再確認まで完全に避けたい場合は、第二段階で `SCContentSharingPicker` への移行を検討する。
- Calendar 小サイズ UI は固定幅起因の崩れを修正済みだが、実画面での最終目視はユーザー実機で確認が必要。
