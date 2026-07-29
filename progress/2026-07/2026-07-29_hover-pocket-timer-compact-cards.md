# HoverPocket macOS Timer Compact Cards

## 実装

- 実装前にローカル`main`の3コミットを`origin/main`へpushした。local / originは`bf954b028767db6d8b1559f8ee378ca095d4eff5`で一致し、ahead / behindは`0 / 0`。
- Timer / Pomodoroの横並び入力カードは、外側padding、カード内spacing、color picker、Pomodoroのwork / rest間隔、startボタンを詰めて縦幅を縮めた。
- 実行中セクションの大きな外枠を外し、各タイマーを高さ`44pt`の薄い横長カードへ変更した。
- 各実行中カードは進捗リング、タイトル、残り時間、Pomodoro phase、pin、pause / resume、stopを1行へまとめた。
- 実行中タイマーと終了アラートは追加されるごとに`5pt`間隔で縦に並ぶ。
- 時間の直接入力、調整バー、sound、start、pause / resume / stop、pin / unpin、アラーム停止の動作は維持した。

## 検証

- `TimerLayoutMetrics`へcompact section padding、実行中カード高さ、カード間隔を定義した。
- `--verify-timer`へcompact layout値の回帰検証を追加した。
- `swift build`: 成功。
- `--verify-timer`: `timer_verify=ok`、`timer_layout_side_by_side=true`、`timer_layout_compact=true`。
- `--verify-panel-layout`: 112ケース成功。
- `--verify-clipboard`: 成功。
- `./script/build_and_run.sh --verify`: 成功し、Apple Development署名の製品bundleを起動した。
- `codesign --verify --deep --strict`: 成功。
- 製品bundle内`--verify-timer`: `timer_verify=ok`、`timer_layout_compact=true`。
- 起動中processが`dist/HoverPocket.app/Contents/MacOS/HoverPocket`を指すことを別経路で確認した。
- `git diff --check`: 成功。

## 未確認

- 実際のホバーパネルでの目視readback。
- Windows版への同レイアウト反映。
- 公開release / feed更新。
