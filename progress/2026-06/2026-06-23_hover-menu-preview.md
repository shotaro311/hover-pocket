# 2026-06-23 HoverPocket

## 実施内容: ハンドルなし時のノッチ横背景非表示

- Settings の `ハンドルアイコン` で `なし` を選んだ場合、ノッチ横の黒いハンドル背景も描画しないようにした。
- 表示だけでなく `PanelGeometry` に渡す有効な横ハンドル表示状態も `showNotchSideHandleArea && pillHandleIconStyle != .none` に揃え、`なし` 選択時はアクセスウィンドウ幅もノッチ本体側へ詰めるようにした。
- `pillHandleIconStyle` の変更を `HoverWindowController` で購読し、設定変更直後に access window / preview frame / pill 表示が再同期されるようにした。
- Settings の説明文と README のノッチサイズメモを、`なし` 選択時の挙動に合わせて更新した。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `./script/build_and_run.sh --verify`: 成功。Apple Development 署名で `dist/HoverPocket.app` を起動確認。
