# 音声だけで完結する確認設定・天気の取得・macOS 638

状態: Release638の検証を完了し、Apple公証中。ユーザーが追加修正と本番反映を承認済み。

## 変更

- 既存の通常操作の確認設定を保持し、削除・取消の確認を独立した設定へ分離。両方オフなら追加の確認なし。オンの場合もnative dialogを出さず、同じ会話の後続の明示承認で同じBroker計画を再開する。
- 確認待ちは先にtool応答を返し、会話・他の読み取りを続けられる。確認IDは同じsession・対象revision・計画・5分の期限へ束縛し、取消・切断で失効する。
- 予定・付箋・タイマーの削除に加えて、追加ツールの導入・workflow・記録・取り外しも同じ設定を使用。削除設定の既定はオン。既存の通常操作の設定を無断で変更しない。
- 音声へ既存WeatherForecastStoreの読み取りを公開。設定地域、温度単位、8日分の日付・タイムゾーン、取得時刻とキャッシュ警告を共有し、座標をモデルへ返さない。
- build637の共通コントローラー実装（画面同期、背景生成、標準機能保護、声の選択、生成preview検証）を含む。

## 検証

- Debug: 音声だけの確認23項目、天気8項目、App OS50項目、既存personal-tools42、Voice Foundation、Codex app-serverがPASS。
- 実app-serverの天気tool経路と実ChatGPTモデルの天気取得がPASS。既存の設定地域を使い、新しい位置情報の許可は要求していない。
- Developer ID署名Release638で音声確認23、天気8、App OS50、personal-tools42、platform78、HTML20、panel128、Broker、Voice Foundation、Codex app-server、package/lifecycle/backupを検証しPASS。
- 最終bundleの実ChatGPTモデルで天気取得がPASS。Maple選択のWebRTC接続と子プロセス終了もPASS。
- 実Astra生成の読書管理・水やり記録を最終bundleで再検証しPASS。panel soakは100開閉・100切替・5復旧・3アニメーションとリソース上限を1回でPASS。
- 共有v1契約72/v2契約46/Voice静的42がPASS。配布先がmacOS専用feedであること、Google設定・位置情報entitlementをreadback。実行ファイルSHA256とソース207ファイルのdigestを固定。
- 根拠: [検証証拠](../evidence/2026-09-07-voice-only-weather-638/)。Apple公証・公開後readbackは進行中。

## 受入の範囲

物理マイクでの聞き取りと話し声の聞き比べは未検証。OS自身のマイク・位置情報等の権限画面と、設定画面からの管理操作は音声確認設定の対象外。Windowsの機能・配信は変更しない。
