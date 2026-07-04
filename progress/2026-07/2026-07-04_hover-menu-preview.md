# 2026-07-04: Calculator UI polish

## 目的

- 電卓の見た目を整える。
- 表示エリア右上と下部に重複していたコピー導線を1つにする。

## 実施内容

- `CalculatorView` の横幅を最大 430pt に制限し、大きいパネルでもキーが横に伸びすぎないようにした。
- 表示エリア内の重複タイトルを削除し、結果表示と操作アイコンを主役にした。
- コピー操作は表示エリア右上の `doc.on.doc` アイコンに統一し、下部のコピーボタンを削除した。
- バックスペースは表示エリア右上の `delete.left` アイコンへ移動した。
- キーパッドを `VStack` / `HStack` から `Grid` に変更し、`0` の2列幅、演算子、`=` の配置が崩れないようにした。
- 演算子表示を `/` / `*` / `-` から `÷` / `×` / `−` に変更し、電卓らしい見た目に寄せた。
- キーの高さと余白を調整し、押せる面積と密度を揃えた。

## 検証

- `swift build` 成功。
- `.build/debug/HoverPocket --verify-calculator` 成功（`calculator_verify=ok`, `calculator_display=25`）。
- `.build/debug/HoverPocket --verify-calculator --calculator-sequence '7/0='` 成功（`calculator_verify=ok`, `calculator_display=Error`）。
- `git diff --check` 成功。
- `./script/build_and_run.sh --verify` 成功（`HoverPocket launched`）。
