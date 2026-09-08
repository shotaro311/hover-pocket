# 音声バーの下端はみ出し修正

2026-09-08 / 本番640の公開とこのMacの更新まで完了。以下のローカル検証後、追加依頼により本番反映した。

ユーザーのスクリーンショットにある下端のはみ出しを修正した。会話表示が固定33ptだったため、実画面の上端領域30ptを3pt超えていた。各画面のsafe area、またはメニューバーの領域から高さを決め、下端に1物理ピクセルの余裕を残す。この画面は2倍表示で29.5ptとなる。上端が自動非表示の場合は標準メニューバー高を用いる。

WindowとSwiftUIの表示へ同じ高さを反映し、アイコンと波形を中央へ収めた。Voice OFFの寸法は保持する。ローカル修正と検証は依頼範囲のため再確認せず実施した。

- Swift build: PASS。
- 音声表示・終了37項目、panel layout112、Voice Foundation: PASS。上端22/24/28/32/38ptと1倍/2倍表示で下端を超えないことを確認。
- 隔離したbuild640のSwiftUI previewで、縮小した会話表示とミュートの斜線・状態を確認。検証用bundleの初回起動はSparkleの探索パス不足で失敗し、既存ビルド手順と同じFrameworks探索パスを加え再署名後に起動を確認した。
- 検証用アプリを終了。本番639のbinary hashは配信時の値と一致。実マイクの会話は未検証。

[検証ログ・画像](../evidence/2026-09-08-voice-height/)。

## 本番640への反映

ユーザーの「本番へ」を受け、署名・公証・公開とこのMacの更新を再確認せず実施した。

- source/tag: `58949ae2c2ac40b2b0e2fecdc83b25296107e2e8` / `v0.1.0-640`。Swiftソース192ファイルのhashが一致。
- Developer ID署名Release640で音声37項目、panel112、Voice FoundationがPASS。[3 OSの共通契約CI](https://github.com/shotaro311/hover-pocket/actions/runs/34178529209)の4ジョブもsuccess。
- Apple公証Accepted: `52229cac-4e05-446d-9276-5ff18bae2a99`。公開93 checksと独立したmacOS署名・公証readbackがPASS。Windows8資産は更新前後で一致。
- 公開ZIPを取り直してこのMacを639→640へ更新・再起動した。インストール済みbinary hashは公開版と一致し、起動数1。旧639はゴミ箱へ退避した。
- 保存データ6ファイルは更新直前と再起動・UI確認後で一致。ChatGPTログイン済み、通常確認OFF・削除確認OFFを実UIで確認し、設定は変更していない。確認用設定画面は閉じた。
- 実マイクの音声会話は未検証。

[本番640](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-640) / [配信検証根拠](../evidence/2026-09-08-voice-height-release/)。
