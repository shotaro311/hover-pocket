# HoverPocket Mac Extra Large Panel and Text Sizes

## 実装

- パネルサイズと文字サイズを `Small / Medium / Large / Extra Large` の4段階へ拡張した。
- 既存パネル寸法 `520x372 / 600x430 / 680x488` と保存値 `small / medium / large` は変更していない。
- Extra Largeパネルは、既存の段階差を延長した `760x546` とした。Extra Large文字は基準フォントへ `+3pt` を適用する。
- 上部サイズ切り替えは `小 → 中 → 大 → 特大 → 小` / `S → M → L → XL → S` で循環する。
- Settingsの既存`allCases` pickerとAppSettingsのraw value永続化をそのまま利用し、日英ラベル・説明文を追加した。
- Calendarと天気はExtra LargeでLarge向けメトリクスを引き継ぎ、拡張されたパネル領域へ収めた。
- panel layout verifierへ、4段階の寸法、旧raw value、新raw value、UserDefaults保存・再読込の互換確認を追加した。

## 検証

- `swift build`: 成功。
- `.build/debug/HoverPocket --verify-panel-layout`: 成功。112ケース、互換性3項目、4段階の寸法、Calculator全サイズが`ok`。
- `.build/debug/HoverPocket --verify-calculator`: 成功。
- `.build/debug/HoverPocket --verify-clipboard`: 成功。
- `git diff --check`: 成功。

## 未実施

- 実アプリ画面でのSettings 4分割pickerとExtra Largeパネルの目視readbackは、この並行実装laneでは未実施。
- Windows版は変更していない。
