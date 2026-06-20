---
project_slug: hover-menu-preview
date: 2026-06-09
updated_by: codex
status: active
---

# 2026-06-09 hover-menu-preview

## 実施内容

- 上部ヘッダー右端の電源アイコンを削除。
- provider アイコン群と設定ボタンの間に、薄い縦線の仕切りを追加。
- `ProviderSwitchingMode` を追加し、provider アイコンの切り替え方式を `Click` / `Hover` から選べるようにした。
- Settings の `Panels` セクションに `Icon switching` segmented picker を追加。
- `Click` では従来通りアイコンクリックで provider を切り替える。
- `Hover` では provider アイコンにポインタを重ねた時点で自動的に provider を切り替える。
- 切り替え方式は `UserDefaults` に保存し、次回起動後も維持する。
- リファクタリングとして、`HoverPanelShell.swift` からヘッダーUIを `ProviderHeaderView.swift` へ分離。
- provider アイコンのクリック / ホバー分岐を `ProviderIconButton` に閉じ込め、パネルシェル本体は外枠と provider host の合成だけに整理。
- `ProviderStore` の設定監視を `settings.objectWillChange` 全体購読から、provider の表示順 / 表示非表示だけの購読へ絞った。これにより、パネルサイズ変更や `Icon switching` 変更で provider store が不要に再通知されない。
- Google OAuth の Keychain 許可ダイアログが毎回出る問題を調査。生成済み `dist/NotchPocket.app` が ad-hoc 署名になっており、再ビルド後にキーチェーンから別アプリ扱いされやすい状態だった。
- `GoogleCalendarStore` の初期化時に Keychain を読まないように変更し、保存済みGoogle認証の確認を Calendar パネルを実際に開いた時、または Connect ボタンを押した時へ遅延。
- `script/build_and_run.sh` で `Apple Development` のコード署名IDを自動検出し、app bundle を安定署名するように変更。`CODESIGN_IDENTITY` が指定されている場合はそちらを優先する。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功、`NotchPocket launched` を確認。
- `rg -n "power|terminate\\(|providerSwitchingMode|Icon switching|HeaderIconDivider" Sources/HoverMenuPreview`: 上部ヘッダーの `power` / `terminate` 残存なし、追加設定と仕切りの参照のみ確認。
- `swift test`: `Tests` ターゲットがないため `error: no tests found`。現時点のパッケージ構成では未整備。
- `bash -n script/build_and_run.sh`: 成功。
- `codesign -dvvv --entitlements :- dist/NotchPocket.app`: `Signature=adhoc` ではなく `Authority=Apple Development: ...`、`TeamIdentifier=N7VVPW44ZA` を確認。
- `swift build`: `HoverPocket` target として成功。
- `bash -n script/build_and_run.sh && bash -n script/verify_google_calendar.sh`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功、`HoverPocket launched` を確認。
- `PlistBuddy` で `CFBundleExecutable=HoverPocket`、`CFBundleIdentifier=local.codex.hover-pocket`、`CFBundleDisplayName=ホバーポケット`、`CFBundleName=ホバーポケット` を確認。
- `codesign -dvvv dist/HoverPocket.app`: `Identifier=local.codex.hover-pocket`、`Authority=Apple Development: ...`、`TeamIdentifier=N7VVPW44ZA` を確認。
- `dist/NotchPocket.app` は旧生成物として残っていたため、`trash` でゴミ箱へ移動。現在の `dist` は `HoverPocket.app` のみ。
- MIT License 追加後に `git diff --check`: 成功。
- アプリ名を `ノッチポケット` / `NotchPocket` へ変更。SwiftPM package / executable / generated app bundle / README / progress / OAuth callback page / permission descriptions を更新。
- Keychain service を `local.codex.notch-pocket.google-oauth` へ変更し、旧 `local.codex.hover-menu-preview.google-oauth` から保存済みcredentialを読み込めた場合は新serviceへ移す移行処理を追加。
- Clipboard履歴の保存先を `Application Support/NotchPocket/Clipboard` へ変更し、旧 `Application Support/HoverMenuPreview/Clipboard` からコピー移行する処理を追加。
- アプリ名を `ホバーポケット` / `HoverPocket` へ変更。
- SwiftPM package / executable / generated app bundle を `HoverPocket` に変更し、bundle 表示名を `ホバーポケット` に設定。
- bundle ID を `local.codex.hover-pocket` に変更。
- README、OAuth callback page、camera / microphone permission descriptions を新名へ更新。
- source path を `Sources/HoverPocket` へ移動。
- provider protocol を `NotchProvider` から `PocketProvider` に改名。
- Keychain service を `local.codex.hover-pocket.google-oauth` に変更し、旧 `local.codex.notch-pocket.google-oauth` と旧 `local.codex.hover-menu-preview.google-oauth` から移行できるようにした。
- Clipboard履歴の保存先を `Application Support/HoverPocket/Clipboard` に変更し、旧 `Application Support/NotchPocket/Clipboard` と旧 `Application Support/HoverMenuPreview/Clipboard` から移行できるようにした。
- GitHub repository slug と local `origin` を `shotaro311/hover-pocket` へ変更。
- MIT License を `LICENSE` として追加。
- README に `License` セクションを追加し、ソースコードは MIT License、`ホバーポケット` / `HoverPocket` の名称・ロゴ・ブランド表示の商標的利用は別扱いであることを明記。

## 未完了 / 注意

- 実画面でのホバー切り替えの体感速度は、ユーザー側の操作感確認が必要。
- 自動テストターゲットは未整備。現状の検証は `swift build` と app bundle 起動確認が中心。
- Keychain 許可は既存の古い ad-hoc 署名由来の許可情報が残っているため、次に Calendar を開いた時だけ1回出る可能性がある。その場合は `常に許可` を押せば、以後は安定署名に対して保存される見込み。
- `HoverPocket` への rename で bundle ID も変えたため、camera / microphone / Keychain は初回だけ再確認が出る可能性がある。
- GitHub repository slug も `shotaro311/notch-pocket` へ変更済み。local `origin` も `https://github.com/shotaro311/notch-pocket.git` へ更新済み。
- GitHub repository slug は最終的に `shotaro311/hover-pocket` へ変更済み。local `origin` も `https://github.com/shotaro311/hover-pocket.git` へ更新済み。
