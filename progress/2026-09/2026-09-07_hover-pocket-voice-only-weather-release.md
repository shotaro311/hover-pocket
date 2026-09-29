# 音声だけで完結する確認設定・天気の取得・macOS 638

状態: macOS 0.1.0 build638の本番公開、公開物の別経路readback、このMacの更新・設定画面の確認まで完了。ユーザーが追加修正と本番反映を承認済み。

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
- 根拠: [検証証拠](../evidence/2026-09-07-voice-only-weather-638/)。

## 本番公開とインストール後の確認

- Apple公証はAccepted。staple、Gatekeeper、deep/strict署名の検証がPASS。公証前後でテスト済み実行ファイルのSHA256が一致。
- ソースtag `v0.1.0-638` は `275f9ff9ce95bc4a2064e697aa37cc806efc9953`。GitHubの契約CI（run 34131078779）はUbuntu/Windows/macOSと比較jobがすべてsuccess。
- [macOS 638](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-638)を公開し、macos-latestのappcastと手動ZIPを更新。公開物93 checks PASS。3種類の公開ZIPと2か所のappcastの同一性、公開ZIPの署名・公証・Gatekeeper・配布設定を別経路で確認した。
- Windows0.2.8の8資産はID・size・digest・更新時刻が公開前後で不変。
- 公開ZIP SHA256: `ca6905cad98995b756fc99df046cf3b5c13206e5f86a9365230cc3fcc46cc2a9`。配布実行ファイルSHA256: `8b14cf994c59cb363f24ff9a6f1f3742260c2f24d6162f70ea1840265191b0c4`。
- このMacの/Applications/HoverPocket.appを634から638へ更新し、新しいプロセスが1つ起動していることを確認。旧appは名前を変えてゴミ箱へ退避し、恒久削除していない。公開ZIPと一致するアーカイブを展開して適用し、インストール後のバイナリhashを再照合した。
- 既存の付箋・タイマー・追加ツールの保存JSON 6ファイルはSHA256がすべて不変。ChatGPTへのログインと既存の通常操作確認OFFを実設定画面からreadback。新しい削除・取消確認は既定ONで、音声確認を使う。設定値の切り替えは検証で行っていない。
- 実際の音声設定画面で2項目が読みやすく表示されることを画像でも確認。音声・AIページを開いた状態にしている。
- ユーザーが承認した修正・検証・ソース保存・本番公開・このMacへの更新を追加確認なしで実施した。

## 受入の範囲

物理マイクでの聞き取りと話し声の聞き比べは未検証。OS自身のマイク・位置情報等の権限画面と、設定画面からの管理操作は音声確認設定の対象外。Windowsの機能・配信は変更しない。
