# HoverPocket Mac Clipboard / Timer / Extra Large Integration

## 実装

### Clipboard

- タブを「すべて / お気に入り」の2つに整理した。
- 両タブでテキストを左、画像を右へ等分したsplit viewにした。
- コピー、星、個別削除、外部ドラッグ、全体プレビュー、favoriteを残す履歴clearを維持した。

### Timer

- 「タイマー / ポモドーロタイマー」の入力カードを横並びにした。
- 実行中セクションをtimer colorの枠・背景、大きな残り時間、進捗リングで強調した。
- 既存の直接入力、調整バー、start、pause / resume / stop、pin / unpin、アラーム停止を維持した。
- `--verify-timer`を追加し、既定値、時間表示、進捗計算、start / pause / resume / stop、pin / unpin、4段階の横並び幅を検証する。
- verifier用TimerStoreはwake監視と永続化を無効にした専用インスタンスを使う。本番の`TimerStore.shared`と`Application Support/HoverPocket/Timer/`へ触れない。

### Panel / Text

- `Small / Medium / Large / Extra Large`の4段階へ拡張した。
- Extra Largeパネルは`760x546`、Extra Large文字は基準フォント`+3pt`。
- 既存3段階の寸法とraw valueは維持した。

### Docs

- READMEのClipboard旧3タブ表記を2タブsplitへ更新した。
- READMEへTimer 2列、実行中強調、`--verify-timer`を追記した。
- requirementsへmacOSのExtra Large、Weather Extra Large、Timer 2列・実行中強調を追加した。
- Windows版のPanel / Textは現行3段階のまま変更しないことを明記した。

## 検証

- `swift build`: 成功。
- `.build/debug/HoverPocket --verify-timer`: 成功。
  - `timer_lifecycle=ok`
  - `timer_pin=ok`
  - `timer_storage_isolation=ok`
  - `timer_layout_side_by_side=true`
  - entry widths: `small=239 / medium=279 / large=319 / extraLarge=359`
- `git diff --check`: 成功。
- 先行laneでは`--verify-panel-layout` 112ケース、`--verify-calculator`、`--verify-clipboard`が成功済み。

## 未実施

- Clipboard、Timer、Settings、Extra Largeパネルの実画面readback。
- Windows版へのExtra Large反映。
- 公開配信。
- 並行作業中のメディア差分は、この統合作業では変更していない。
