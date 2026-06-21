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

## 追加実施内容: YouTube 認識 fallback / 倍速ボタン配置

- YouTube が Controls で認識されない報告に対応し、MediaRemote が空を返した場合だけブラウザのアクティブタブ title / URL を Apple Events で確認する fallback を追加した。
- fallback は Chrome / Safari / Microsoft Edge / Arc を対象にし、YouTube / YouTube Music / Netflix / Twitch / Vimeo の active tab をメディアとして扱う。Chrome の `Apple Events からの JavaScript を許可` には依存しない。
- `NSAppleEventsUsageDescription` を generated app bundle の Info.plist に追加した。
- MediaRemote の seek / playback rate 操作は、既存の private setter に加えて `MRMediaRemoteSendCommand` の `SeekToPlaybackPosition` / `ChangePlaybackRateCommand` option も併用するようにした。
- 倍速 `-0.1 / +0.1` ボタンを独立カプセルから撤去し、10秒戻し / 再生停止 / 10秒送りの横へ同じ丸アイコンボタンとして配置した。

## 追加検証: YouTube / build 71

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- YouTube probe: `MRMediaRemoteGetNowPlayingInfo` が YouTube の title / duration / elapsed / playbackRate / artwork を返すことを確認。
- Chrome active tab probe: title `UE6はソードアートオンラインを目指す ep661 - YouTube` と YouTube URL を取得できることを確認。
- Chrome JS probe: ユーザー環境では `AppleScript からの JavaScript の実行がオフ`。今回の fallback は JS を使わない title / URL 取得に限定した。
- DDC change probe: `LG ULTRAGEAR` の VCP `0x10` を `28 -> 29 -> 28` へ変更/復元できることを確認。
- Generated Info.plist: `CFBundleVersion=71` と `NSAppleEventsUsageDescription` 追加を確認。

## 追加成果物: build 71

- Commit: `f242649288d458c8612f3b71478a3367207b2a52`
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-71`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-71.zip`
- ZIP SHA256: `dba04b13588187b600f83b8ee93eb789d2b3e3ef6037e4181b8d424795a7c9fd`
- Notary submission ID: `056c9b90-d400-457b-a5f8-3f27ef0d0cda`
- Notary status: `Accepted`

## 追加配信検証: build 71

- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `71` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-71 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-71.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `71`、enclosure が `v0.1.0-71/HoverPocket-0.1.0-71.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-71.zip | awk -F/ '{print $1}' | sort -u`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-71.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`xcrun stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `git ls-remote --tags origin v0.1.0-71`: release tag が commit `f242649288d458c8612f3b71478a3367207b2a52` を指すことを確認。

## 追加実施内容: 外部ディスプレイ輝度制御経路修正 / build 73

- 外部ディスプレイでも `DisplayServicesSetBrightness` が成功扱いを返す場合に DDC/CI へ進まない問題を修正した。
- 内蔵ディスプレイは従来どおり `DisplayServices` を使い、外部ディスプレイは DDC/CI を先に試す。DDC が使えない場合だけ `DisplayServices`、最後にソフト輝度 fallback へ落とす順序にした。

## 追加検証: 外部輝度 / build 73

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- DDC change probe: `LG ULTRAGEAR` の VCP `0x10` を `28 -> 29 -> 28` へ変更/復元できることを確認済み。

## 追加成果物: build 73

- Commit: `ea144fc6ec8ef48690b2e928274703dff5ef63fd`
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-73`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-73.zip`
- ZIP SHA256: `3f2c4adca44b284b961186172b4aa465263da8a79b22221d939894d96a21c44d`
- Notary submission ID: `a427e7d0-c245-45f0-b398-c55b7517debf`
- Notary status: `Accepted`

## 追加配信検証: build 73

- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `73` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-73 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-73.zip`、SHA256、`appcast.xml` の4 asset を確認。
- `dist/releases/appcast.xml`: `sparkle:version` が `73`、enclosure が `v0.1.0-73/HoverPocket-0.1.0-73.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-73.zip | awk -F/ '{print $1}' | sort -u`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 -c dist/releases/HoverPocket-0.1.0-73.zip.sha256`: 成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`xcrun stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `git ls-remote --tags origin v0.1.0-73`: release tag が commit `ea144fc6ec8ef48690b2e928274703dff5ef63fd` を指すことを確認。
