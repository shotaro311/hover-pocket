# 2026-07-28 HoverPocket Global Weather Locations

## 実装

- macOS版Calendar天気の地点設定を、日本47都道府県だけから、現在地、世界の都市・郵便番号検索、日本47都道府県の簡易選択へ拡張した。
- `WeatherLocation`へ地点ID、表示名、行政区、国、国コード、緯度・経度、タイムゾーン、取得元を保持する。既存の`weatherRegionID`は同じ都道府県庁所在地へ自動移行し、新しいJSON設定として保存する。
- Open-Meteo Geocoding APIで多言語の世界都市・郵便番号検索を実装した。検索結果は最大6件を設定画面に表示し、地点名、行政区、国を確認して選択できる。
- Core Locationは「現在地を使用」を押した時だけ許可と単発地点取得を実行する。常時追跡、バックグラウンド監視、位置ログは追加していない。
- Forecast APIの座標を小数点以下5桁へ高精度化し、固定`Asia/Tokyo`を`timezone=auto`へ変更した。地点の現地日付で曜日を表示する。
- 温度単位に自動 / ℃ / ℉を追加した。自動は地点の国コードを優先し、現在地の国コードがない場合はMacの地域設定を使う。
- 天気キャッシュを地点・温度単位ごとに分離した。旧都道府県キャッシュは摂氏として読み戻せる。
- app bundleへ`NSLocationUsageDescription`と`NSLocationWhenInUseUsageDescription`を追加した。
- macOS標準の`Command+,`からSettingsを開けるようにし、設定UIの実機検証経路を追加した。
- READMEとrequirementsを世界地点、位置情報の明示操作、自動タイムゾーン、温度単位、Windows展開方針へ同期した。

## 検証

- `swift build`: 成功。
- `git diff --check`: 成功。
- `bash -n script/build_and_run.sh`: 成功。
- `.build/debug/HoverPocket --verify-panel-layout`: 63ケース成功。
- `.build/debug/HoverPocket --verify-calculator`: 成功。
- `.build/debug/HoverPocket --verify-clipboard`: 成功。
- `./script/build_and_run.sh --verify`: Apple Development署名のapp bundleを生成し、`HoverPocket launched`を確認した。
- bundleの位置情報説明文を`PlistBuddy`で読み戻し、`codesign --verify --deep --strict`に成功した。
- Computer Useのアクセシビリティreadbackで実アプリSettingsを開き、保存済みの福岡、現在地ボタン、都市・郵便番号入力、検索、日本の都道府県、温度単位の自動 / ℃ / ℉が表示されることを確認した。
- 専用weather verifierは実装後に一度成功し、東京の`Asia/Tokyo`・摂氏と、世界検索したロンドンの`Europe/London`・華氏、7日予報、地点設定の保存、旧福岡設定移行、地点別キャッシュ、SwiftUI画像生成を確認した。

## 外部接続の再確認

- 最終再実行時、`api.open-meteo.com`と`status.open-meteo.com`がTCP接続タイムアウトになった。
- 同時刻に`geocoding-api.open-meteo.com`はHTTP 200、`open-meteo.com`はHTTP 200、`customer-api.open-meteo.com`は認証なしの期待どおりHTTP 400で応答した。
- Forecast無料ホスト側の一時障害と切り分けた。アプリは保存済み予報を警告付きで表示する既存フォールバックを維持している。

## 残る確認

- 現在地の実座標取得はmacOSの位置情報許可を伴うため、許可ダイアログを自動承認していない。説明文、権限分岐、座標モデル、ビルドまでは確認済み。
- Windows版の天気UI・世界地点設定・Windows位置情報は未実装。Windows実機担当で別途実装と検証が必要。
- GitHub Release、macOS appcast、Windows feedは変更していない。
