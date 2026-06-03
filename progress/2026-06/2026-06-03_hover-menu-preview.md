---
project_slug: hover-menu-preview
date: 2026-06-03
updated_by: codex
---

# 2026-06-03 Progress Log: hover-menu-preview

## 作業

- 上部 pill の配置を `screen.frame.maxY - pillSize.height - 5` から `screen.frame.maxY - pillSize.height` に変更。
- 画面上端から 5pt 下げていた余白をなくし、上端にぴったり付く配置にした。
- preview panel を pill 下端に接した小さいカプセル状の `collapsedPreview` から最終 frame へ広げる opening animation に変更。
- preview 内部コンテンツは panel の変形後に少し遅れて fade / scale / blur で出すようにした。
- `accessibilityDisplayShouldReduceMotion` が有効な場合はアニメーションを省略する分岐を追加。
- 上面に接する pill の top corners を丸めず、bottom corners だけ丸い `TopDockedPillShape` に変更。
- pill height を 32pt から 33pt に伸ばし、下端の細い隙間を抑えるように変更。
- notch sizing / point-pixel compensation の設計メモを `README.md` に追記。
- preview close の待ち時間を `0.36s` から `0.06s`、close animation を `0.18s` から `0.10s` に短縮。
- morphing collapsed frame を pill / notch 中央の小さい source frame に変更し、上部ノッチ中央から下へ伸び、閉じる時は同じノッチ中央へ戻るように調整。
- preview close の待ち時間を `0.04s` にし、close animation は `0.30s + 0.12s` の二段階に変更。
- preview morphing に `neckPreview` と `elasticPreview` を追加し、上部ノッチ中央の source から細い首を経由して、少し大きく広がってから final frame に戻る動きに変更。
- 二段階の `neckPreview` / `elasticPreview` はもっさり見えたため撤回し、直前の `source -> final` のシンプルな morphing に戻した。
- preview close の待ち時間を `0.06s`、close animation を `0.10s` に戻した。
- preview close animation を open と同じ `0.32s` に変更し、timing curve を open の逆カーブ `controlPoints: 0.72, 0.0, 0.82, 0.04` に変更。
- preview 内部コンテンツの非表示開始を close 終盤へ遅らせ、open の content reveal に近い逆順に調整。
- top pill の text / session count を削除し、ノッチ左側に小さい `arrow.right` handle だけを描画するように変更。
- pill window は `284x33` の透明 hit area にし、表示要素は左端の `54x33` handle だけにした。
- `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea` から実ノッチ範囲を取得し、pill window を `left handle 54pt + notch width` に変更。
- top pill の黒い base をノッチ裏まで描画し、handle 右端とノッチ左端が接するように配置。
- pill window の shadow を無効化し、top pill の上端に `3pt` の黒 overfill を追加して、上部の細いスリット状の抜けを埋めた。
- 左側 handle のラウンド形状変更を試したが、意図と違ったため撤回し、元の `TopDockedPillShape` ベースの形へ戻した。
- 今後の追加機能を plugin 的に扱えるよう、単一 `main.swift` から App / Windowing / State / Models / Providers / Views / Support へ分割。
- `NotchProvider` / `ProviderRegistry` / `ProviderStore` を追加し、追加機能は provider として登録する構成に変更。
- 既存の `sessions` / `usage` はデモ表示だったため削除し、provider 未登録時の空状態だけを表示するように変更。
- `README.md` に provider-hosted content 構成と、外部化する場合は XPC / helper / JSON-RPC を優先する方針を追記。
- 表示先を `Auto / Main / Sub` から選べる `DisplayPlacementMode` と `AppSettings` を追加。
- preview header の gear button から開ける `SettingsWindowController` / `SettingsView` を追加。
- `Auto` はマウスがある画面、`Main` は primary macOS display、`Sub` は接続中の secondary display を使うようにした。
- ノッチが検出できない外部/サブディスプレイでは fake notch を出さず、上部中央の小さい handle として表示するように変更。

## 検証

- `./script/build_and_run.sh --verify` 成功。
- `CGWindowListCopyWindowInfo` で `HoverMenuPreview` の pill window が `Y = 0` になっていることを確認。
- `optionOnScreenOnly` の window frame sampling で、hover 前は pill のみ、hover 後は preview が `h=199 -> 267 -> 297 -> 308 -> 312` と伸びることを確認。
- `screencapture -l` で pill window を切り出し、上辺がフラットで下左右だけ丸い形になっていることを確認。
- pill `h=33`、preview が pill 下端直下から始まることを window frame で確認。
- マウスアウトから preview 非表示までの実測が約 `0.166s` になったことを確認。
- pill から preview へ移動しても `stillOpenAfterPillToPreview=true` で誤閉じしないことを確認。
- opening frame sampling で、pill 中央 `mid=756,16` から preview が `midY=94 -> 142 -> 169 -> 180 -> 189` と下へ伸びることを確認。
- close frame sampling で、preview が `midY=189 -> 155 -> 85 -> hidden` とノッチ中央方向へ戻ることを確認。
- close animation 後に tiny source frame が残らないよう、`orderOut` fallback を追加し、約 `0.161s` で hidden になることを確認。
- 再調整後の opening frame sampling で、preview が `w=114 h=49 -> w=128 h=56 -> w=500 h=324 -> w=472 h=312` と neck / overshoot / settle を通ることを確認。
- 再調整後の close frame sampling で、preview が `w=472 h=312 -> w=448 h=294 -> w=324 h=202 -> w=203 h=112 -> w=128 h=56 -> hidden` と開く時に近い速度でノッチ中央へ戻ることを確認。
- 撤回後の opening frame sampling で、preview が `w=361 h=228 -> w=441 h=289 -> w=467 h=307 -> w=472 h=312` と overshoot なしで広がることを確認。
- 撤回後の close frame sampling で、preview が `w=472 h=312 -> w=183 h=96 -> hidden` と素早くノッチ中央へ戻ることを確認。
- reverse close 調整後の opening frame sampling で、preview が `w=360 h=228 -> w=440 h=288 -> w=467 h=309 -> w=472 h=312` と広がることを確認。
- reverse close 調整後の close frame sampling で、preview が `w=472 h=312 -> w=472 h=312 -> w=467 h=308 -> w=447 h=293 -> w=345 h=217 -> hidden` と、open と同じ尺の逆カーブで戻ることを確認。
- `screencapture -l` で top pill を切り出し、文字表示がなく `arrow.right` handle だけになっていることを確認。
- `CGWindowListCopyWindowInfo` で pill window が `x=614 y=0 w=284 h=33`、hover 後 preview が `w=472 h=312` で表示され、hover out 後に閉じることを確認。
- `NSScreen` で内蔵 display の notch 範囲が `x=663..848 w=185` であることを確認。
- 再配置後の `CGWindowListCopyWindowInfo` で pill window が `x=609 y=0 w=239 h=33`、handle 右端が `x=663` になり、ノッチ左端と一致することを確認。
- `screencapture -l` で top pill を切り出し、黒い base がノッチ幅まで伸びていることを確認。
- 左 handle hover 後 preview が `w=472 h=312 mid=756,189` で表示され、hover out 後に閉じることを確認。
- shadow 無効化後の `screencapture -l` で top pill 切り出しが `478x66px` になり、影由来の余白が消えたことを確認。
- top pill 切り出しのピクセル検査で、上端 `y=0..7` が全幅 `478px` 黒で埋まっていることを確認。
- 上端 overfill 後も left handle hover で preview が `w=472 h=312 mid=756,189` で開き、hover out 後に閉じることを確認。
- ラウンド形状変更の撤回後、`screencapture -l` で元の連続した黒ベース形状に戻ったことを確認。
- 撤回後も `CGWindowListCopyWindowInfo` で pill が `x=609 y=0 w=239 h=33`、hover 後 preview が `w=472 h=312 mid=756,189`、hover out 後に閉じることを確認。
- `swift build` 成功。
- `./script/build_and_run.sh --verify` 成功。`HoverMenuPreview launched` を確認。
- display placement 設定追加後に `swift build` 成功。
- display placement 設定追加後に `./script/build_and_run.sh --verify` 成功。`HoverMenuPreview launched` を確認。

## 変更ファイル

- `Sources/HoverMenuPreview/main.swift`
- `Sources/HoverMenuPreview/App/AppDelegate.swift`
- `Sources/HoverMenuPreview/Windowing/HoverWindowController.swift`
- `Sources/HoverMenuPreview/Windowing/PanelAnimationTiming.swift`
- `Sources/HoverMenuPreview/Windowing/PanelGeometry.swift`
- `Sources/HoverMenuPreview/Windowing/SettingsWindowController.swift`
- `Sources/HoverMenuPreview/State/AppSettings.swift`
- `Sources/HoverMenuPreview/State/HoverMenuStore.swift`
- `Sources/HoverMenuPreview/State/ProviderStore.swift`
- `Sources/HoverMenuPreview/Models/DisplayPlacementMode.swift`
- `Sources/HoverMenuPreview/Models/HoverState.swift`
- `Sources/HoverMenuPreview/Models/ProviderModels.swift`
- `Sources/HoverMenuPreview/Providers/NotchProvider.swift`
- `Sources/HoverMenuPreview/Providers/ProviderRegistry.swift`
- `Sources/HoverMenuPreview/Support/NSScreen+DisplayIdentity.swift`
- `Sources/HoverMenuPreview/Support/TopDockedPillShape.swift`
- `Sources/HoverMenuPreview/Views/HoverPanelShell.swift`
- `Sources/HoverMenuPreview/Views/HoverPillView.swift`
- `Sources/HoverMenuPreview/Views/IconButtonStyle.swift`
- `Sources/HoverMenuPreview/Views/PluginHostView.swift`
- `Sources/HoverMenuPreview/Views/SettingsView.swift`
- `README.md`
- `progress/progress.md`
- `progress/2026-06/2026-06-03_hover-menu-preview.md`

## 次アクション

- 最初に実装する実データ provider を決める。
- provider permission / settings UI / auto launch の設計を詰める。
