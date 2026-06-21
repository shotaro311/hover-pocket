# 2026-06-22 HoverPocket

## 実施内容: Controls provider 修正

- Controls の表示品質を調整し、ディスプレイ / サウンド / メディアのスライダー幅と右端アクション位置を揃えた。
- 見出しアイコンを削除し、見出しは日本語で `ディスプレイ` / `サウンド` / `メディア` にした。英語設定では `Displays` / `Sound` / `Media`。
- ディスプレイ名は行内テキストから外し、ディスプレイアイコン hover 時に小さなフェード表示の tooltip として出すようにした。
- 内蔵ディスプレイの明るさ最小値を 5% にクランプし、moon toggle も 5% / 100% の切り替えにした。
- 外部ディスプレイは `DisplayServices` が非対応の場合、Apple Silicon の `DCPAVServiceProxy` + private `IOAVServiceReadI2C/WriteI2C` による DDC/CI VCP `0x10` を試すようにした。DDC が使えない外部画面は CoreGraphics gamma table のソフト輝度 fallback を使う。
- MediaRemote の取得を utility queue に変更し、タイトル/長さ/アートワークだけでなく content identifier、elapsed time、timestamp、playback rate でもメディアあり判定をするようにした。
- メディア操作に `-0.1 / +0.1` の再生速度ボタンを追加した。現在速度は `1.0x` 形式で表示する。
- メディア進捗バー右端に冒頭へ戻るボタンを追加し、10秒戻し / 再生停止 / 10秒送りのボタン間隔を広げた。
- サブエージェントを `DDC外部輝度調査`、`Controls UI整列`、`MediaRemote修正調査` に分けて実施し、親側で統合した。run は `20260622-063452-hoverpocket-controls-uimediaremote`。

## 実機確認

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- DDC probe: `DCPAVServiceProxy` の外部 `LG ULTRAGEAR` から EDID 256 bytes を取得し、VCP `0x10` read が `current=28 / max=100` で成功。同じ値の write back も成功。
- Display identity: `LG ULTRAGEAR` は `vendor=1e6d`、`model=5bb3`、`serial=0004b7c5` で EDID と一致。
- MediaRemote probe: utility queue で `MRMediaRemoteGetNowPlayingInfo` が title / duration / elapsed / playbackRate / artwork を返すことを確認。
- `otool -L dist/HoverPocket.app/Contents/MacOS/HoverPocket | rg 'PrivateFrameworks|MediaRemote|DisplayServices' || true`: 直接リンクなし。

## 成果物: build 69

- Commit: `e8230f2c77a1d1895aa2d7c9bdcf8c2efffc4ab1`
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-69`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-69.zip`
- ZIP SHA256: `7413f372530d8b37869daf2479e36a4853b6749f13ccd04ff21b61f27f9c123b`
- Notary submission ID: `e9b40622-8dc9-4179-9b97-abdafcb4804f`
- Notary status: `Accepted`

## 配信検証

- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `69` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-69 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-69.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `69`、enclosure が `v0.1.0-69/HoverPocket-0.1.0-69.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-69.zip | awk -F/ '{print $1}' | sort -u`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-69.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`xcrun stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `git ls-remote --tags origin v0.1.0-69`: release tag が commit `e8230f2c77a1d1895aa2d7c9bdcf8c2efffc4ab1` を指すことを確認。

## 注意

- DDC/CI は private `IOAVService*` symbol に依存するため、macOS 更新や接続経路によって使えない可能性がある。その場合は外部ディスプレイのみソフト輝度 fallback に落ちる。
- 再生速度変更は MediaRemote 側の private symbol と再生アプリ側対応に依存する。非対応アプリでは UI 更新後に実プレイヤー側が追従しない可能性がある。
