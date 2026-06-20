---
project_slug: hover-menu-preview
date: 2026-06-21
updated_by: codex
status: active
---

# 2026-06-21 hover-menu-preview

## 実施内容

- Settings / Calendar 追加・編集 UI を日本語前提の文言へ最適化し、Settings の `言語` から `日本語` / `English` を切り替えられるようにした。
- `AppLocalization.swift` を追加し、`AppSettings.appLanguage` を `UserDefaults` に永続化する構成にした。既定言語は日本語。
- Settings、Google Calendar、status bar menu、provider header、empty provider view、Calendar 日時入力ヘルプを `AppText` 経由の表示に変更。
- Mirror、Clipboard、Sticky Notes、AI command lane の固定表示文言も主要箇所を `AppLanguage` に接続し、言語切り替え時に表層 UI が追従するようにした。
- Provider header の機能切り替えアイコンを drag & drop で並べ替えできるようにした。drag 中は対象アイコンを薄く表示し、drop target には subtle ring を出す。順序は既存の provider order 設定へ保存する。
- 既存の左右移動 context menu と Settings の provider toggle は維持し、ノッチ形状や top pill geometry は変更していない。

## 成果物

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-59`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-59.zip`
- ZIP SHA256: `46c65fa9d120df68fe76e237d3bd0951f024242e64477a9a32ccffecab85f652`
- Notary submission ID: `34f55cc8-e245-4b1e-aacb-9248526ad47a`
- Notary status: `Accepted`

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `59` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-59 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-59.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `59`、enclosure が `v0.1.0-59/HoverPocket-0.1.0-59.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-59.zip`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-59.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
- `codesign -d --entitlements :- dist/HoverPocket.app`: camera / audio-input entitlements 入りを確認。

## 残り

- 実機操作で Settings の言語切り替え後、Settings / Calendar / Mirror / Clipboard / Sticky Notes / AI lane の表層文言が意図通り即時反映されるかを見る。
- Provider header の drag & drop reorder を、trackpad / mouse の両方で手動確認する。

## 追加実施内容: サブディスプレイミニバー / 更新導線

- 表示先に `すべて` を追加し、各ディスプレイ上部にホバーポケットの起点を出せるようにした。
- ノッチあり画面は既存のノッチ形状を維持し、ノッチなし画面だけ控えめなミニバー起点へ分岐するようにした。
- ミニバーは通常時 150 x 2pt、上部近接時に 168 x 7pt へ 5pt 下がって拡張し、バー自体の hover / tap でホバーウィンドウを開く。
- Settings に `サブディスプレイでもミラーを表示` を追加。既定はオフで、サブディスプレイから開いたホバーポケットでは Mirror provider を非表示にする。
- Sparkle の probing update check を使い、更新が見つかったときだけホバーウィンドウ上部に青い更新アイコンを表示するようにした。クリック時は標準の Sparkle 更新 UI を開く。
- Settings の更新状態文言を日本語 / English 切り替えに対応させた。

## 追加成果物

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-61`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-61.zip`
- ZIP SHA256: `800d8c23c5983d33d53fa59654b110a08bf3ef7a16b8c76c53f284a3bfe3baa2`
- Notary submission ID: `d1083b9f-be49-4ef8-bf68-cdad9e330b40`
- Notary status: `Accepted`

## 追加検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `61` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-61 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-61.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `61`、enclosure が `v0.1.0-61/HoverPocket-0.1.0-61.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-61.zip`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-61.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。

## 追加実施内容: 表示先自動モード廃止 / hover 反応改善

- 表示先の `自動` モードを廃止し、Settings は `メイン / サブ / すべて` の3択にした。
- 既存保存値が `automatic` の場合は `メイン` にフォールバックするようにした。
- `すべて` 選択時は、各ディスプレイの起点ウィンドウを同期時に即前面化するようにした。
- ノッチなし画面のミニバー反応領域を 260 x 32pt から 520 x 64pt へ拡大した。
- 透明ヒット領域全体でホバーウィンドウを開くようにし、上端や横方向からの高速 hover 取りこぼしを減らした。
- README の表示先と最新公開版の記述を build `63` に更新した。

## 追加成果物: build 63

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-63`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-63.zip`
- ZIP SHA256: `e99899a499ffce4d5fa5608706a10cecc23493fe14eaf5fa8c4fd466f64be15c`
- Notary submission ID: `7666e0d6-50d8-4985-bbdb-fed62bc140e0`
- Notary status: `Accepted`

## 追加検証: build 63

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `63` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-63 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-63.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `63`、enclosure が `v0.1.0-63/HoverPocket-0.1.0-63.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-63.zip`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-63.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。

## 追加実施内容: ミニバー 8pt ヒット / Settings 整理

- ノッチなし画面のミニバーは表示用ウィンドウを 12pt のまま残し、実際に hover で開く縦ヒット領域を上端 8pt に縮小した。
- 上部の青い更新アイコンを押した後、Sparkle 更新 UI が見やすいようにホバーウィンドウを閉じるようにした。
- Settings の構成を `表示 / 起点表示 / パネル / 機能 / 付箋 / ミラー / Google カレンダー / アップデート` へ整理し、パネル設定に混在していた起点表示と機能管理を分離した。
- メインノッチ左のアイコンエリア設定を明確化し、オフの場合はアイコンだけでなく横の黒いエリア自体を描画しないようにした。
- README の最新公開版、appcast、表示先ディスプレイ説明を build `65` に更新した。

## 追加成果物: build 65

- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-65`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Latest appcast: `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`
- ZIP: `dist/releases/HoverPocket-0.1.0-65.zip`
- ZIP SHA256: `0e511b4932c8da18bc224238683574b25c44c673dfc48efd57f44524097a787c`
- Notary submission ID: `c92c3e8c-d555-4daf-8055-c7629fc9d29d`
- Notary status: `Accepted`

## 追加検証: build 65

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
- `APP_VERSION=0.1.0 NOTARYTOOL_PROFILE=hover-pocket ./script/publish_github_release.sh`: build `65` の notarization / staple / GitHub Release 公開まで成功。
- `gh release view v0.1.0-65 --json assets,body,url,name,tagName`: `HoverPocket-macOS-app.zip`、`HoverPocket-0.1.0-65.zip`、SHA256、`appcast.xml` の4 asset を確認。
- 公開URL `https://github.com/shotaro311/hover-pocket/releases/latest/download/appcast.xml`: `sparkle:version` が `65`、enclosure が `v0.1.0-65/HoverPocket-0.1.0-65.zip` であることを確認。
- `zipinfo -1 dist/releases/HoverPocket-0.1.0-65.zip`: top-level が `HoverPocket.app` のみであることを確認。
- `shasum -a 256 dist/releases/HoverPocket-0.1.0-65.zip`: SHA256 が `.sha256` と一致。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`、`stapler validate dist/HoverPocket.app`、`spctl --assess --type execute --verbose=4 dist/HoverPocket.app`: 成功、`source=Notarized Developer ID`。
