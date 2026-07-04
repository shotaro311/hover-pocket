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

## 配信（build 98）

- コミット `f02ab81` を build `98` として配信した。
- Release: `https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-98`
- Latest install ZIP: `https://github.com/shotaro311/hover-pocket/releases/latest/download/HoverPocket-macOS-app.zip`
- Notary submission ID: `1fa7ad28-14be-4234-b455-cbafbdcaf5d1`
- Notary status: `Accepted`
- 公開 ZIP SHA256: `33efbaf3e32d1f59b382b21b390c29376bf6a4ef35ab253f354e2c3166baeb0e`
- GitHub Release asset の digest がローカル ZIP SHA256 と一致することを確認した。
- latest appcast が `<sparkle:version>98</sparkle:version>` と `v0.1.0-98/HoverPocket-0.1.0-98.zip` を指すことを確認した。
- 公開 `HoverPocket-macOS-app.zip` を再取得し、top-level が `HoverPocket.app` のみであることを確認した。
- 再取得した ZIP の展開後 app で `codesign --verify --deep --strict`、`xcrun stapler validate`、`spctl --assess --type execute` はすべて成功し、Gatekeeper は `source=Notarized Developer ID` と判定した。
