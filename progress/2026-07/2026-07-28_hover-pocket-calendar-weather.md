# 2026-07-28 HoverPocket Calendar Weather

## Scope

- macOS版Calendarパネルの月グリッド下部に、当日の天気と今後7日間の予報を追加した。
- 追加要件に合わせ、Core Locationを使う現在地方式ではなく、日本47都道府県をSettingsで選択する方式にした。
- Windows版は変更せず、同じ地域IDと表示仕様を使う将来のparity対象として要件だけ残した。

## Implementation

- `WeatherRegion`に47都道府県を都道府県コード（JIS X 0401）で定義した。表示名と代表地点は別フィールドで持ち、保存値は地域名ではなく2桁コードにした。
- 初期地域は東京都（`13`）。Settingsの「天気 > 表示地域」で変更でき、`AppSettings.weatherRegion`から`weatherRegionID`としてUserDefaultsへ保存する。
- 予報地点は都道府県庁所在地付近の代表座標。Macの位置情報、Core Location、APIキー、秘密情報は使わない。
- Open-Meteo Forecast APIへ`Asia/Tokyo`、`forecast_days=8`で問い合わせ、現在気温と当日の最高/最低・降水確率、翌日から7日分の天気コード・最高/最低・降水確率を取得する。
- WMO weather codeをSF Symbolsと日英の天気状態へ変換した。
- Calendarの左ペイン下部へ、既存の暗色、白の低opacity border、角丸に合わせた天気カードを追加した。Small / Medium / Largeで高さを`50 / 64 / 116pt`に切り替える。
- 取得結果は地域単位でUserDefaultsへ保存する。通信失敗時は保存済み予報を黄色の警告付きで維持し、保存済み予報がない場合は再試行表示にする。
- 画面内へOpen-Meteoの帰属リンクを表示する。

## API / policy readback

- Open-Meteo公式Forecast APIは座標、daily weather variables、`timezone`、最大16日の`forecast_days`をサポートする。
- APIキーは無料のopen-access経路では不要。
- 無料APIは非商用利用、日次10,000 call等の条件があるため、商用配布へ切り替える場合は有料APIまたはセルフホストへの移行をREADME / requirementsへ明記した。

## Verification

- `swift build`: 成功。
- `.build/debug/HoverPocket --verify-weather --render-weather-preview`: 成功。
  - `weather_api=open-meteo`
  - `weather_region_id=13`
  - `weather_region_name=東京都`
  - `weather_region_count=47`
  - `weather_upcoming_days=7`
  - `weather_timezone=Asia/Tokyo`
  - `weather_region_persistence=ok`
  - `weather_offline_cache=ok`
- 実際のOpen-Meteo応答を使ったSwiftUI描画を`dist/verification/calendar-weather-preview.png`へ保存し、当日気温、状態、最高/最低、降水確率、今後7日間が欠けずに収まることを画像確認した。
- `.build/debug/HoverPocket --verify-panel-layout`: `panel_layout_verify=ok`、63ケース成功。
- `./script/build_and_run.sh --verify`: Apple Development署名付き`dist/HoverPocket.app`を生成し、起動成功。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-weather`: bundle内実行ファイルでも同じweather verifierが成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- 生成Info.plistに位置情報permission keyがないこと、通常起動が期待したbundle pathの1 processであることをreadbackした。
- `bash -n script/build_and_run.sh`、`git diff --check`: 成功。

## Remaining constraints

- Open-Meteo無料APIは非商用条件。現行の無料配布前提から商用化する場合は配信前にAPI契約またはセルフホストへ切り替える。
- 都道府県全域の予報ではなく、都道府県庁所在地付近の代表予報。
- Computer UseのAccessibility経路ではLSUIElementのhover panelを対象windowとして取得できなかった。実行中app bundleの起動と正確なSwiftUI component画像は確認済みだが、hover panel全体のスクリーンショットは未取得。
- Windows版の天気表示とSettingsは未実装。Windows実機担当で同じ47地域コード、キャッシュ、当日＋7日表示を別途実装・検証する。
