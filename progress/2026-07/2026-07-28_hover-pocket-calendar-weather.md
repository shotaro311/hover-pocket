# 2026-07-28 HoverPocket Calendar Weather

## Scope

- macOS版Calendarパネルの下段全幅に、左側の当日天気と右側の今後7日間予報を追加した。
- 追加要件に合わせ、Core Locationを使う現在地方式ではなく、日本47都道府県をSettingsで選択する方式にした。
- Windows版は変更せず、同じ地域IDと表示仕様を使う将来のparity対象として要件だけ残した。

## Implementation

- `WeatherRegion`に47都道府県を都道府県コード（JIS X 0401）で定義した。表示名と代表地点は別フィールドで持ち、保存値は地域名ではなく2桁コードにした。
- 初期地域は東京都（`13`）。Settingsの「天気 > 表示地域」で変更でき、`AppSettings.weatherRegion`から`weatherRegionID`としてUserDefaultsへ保存する。
- 予報地点は都道府県庁所在地付近の代表座標。Macの位置情報、Core Location、APIキー、秘密情報は使わない。
- Open-Meteo Forecast APIへ`Asia/Tokyo`、`forecast_days=8`で問い合わせ、現在気温と当日の最高/最低・降水確率、翌日から7日分の天気コード・最高/最低・降水確率を取得する。
- WMO weather codeをSF Symbolsと日英の天気状態へ変換した。
- Calendarの下段全幅へ、既存の暗色、白の低opacity border、角丸に合わせた天気カードを配置した。上段とは区切り線で分離し、カード内も当日天気と週間予報の間を縦線で分けた。Small / Medium / Largeで高さを`58 / 67 / 122pt`に切り替える。
- 週間予報へ見出しを追加し、曜日、アイコン、最高/最低気温、降水確率を拡大した。上段右側の予定詳細と予定編集は単一の縦ScrollViewで扱い、内容が上段の高さを超える場合だけスクロールできる。
- Calendar表示ごとに、本日のSF Symbolを先に、週間7個を70ms間隔で続けて挿入する一回限りの`symbolEffect(.appear)`を追加した。表示中の天気更新では再生せず、パネルを閉じた時だけ次回分をリセットする。Reduce Motion有効時と静止画検証時は全アイコンを即時表示する。
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
  - `weather_reduce_motion_render=immediate`
- 実際のOpen-Meteo応答を使ったSwiftUI描画を`dist/verification/calendar-weather-preview.png`へ保存し、当日気温、状態、最高/最低、降水確率、今後7日間が左右に分かれて欠けずに収まることを画像確認した。
- `.build/debug/HoverPocket --verify-panel-layout`: `panel_layout_verify=ok`、63ケース成功。
- `./script/build_and_run.sh --verify`: Apple Development署名付き`dist/HoverPocket.app`を生成し、起動成功。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-weather`: bundle内実行ファイルでも同じweather verifierが成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- 起動したLargeパネルを画面合成経路で`dist/verification/calendar-panel-layout.png`へ保存し、6週の月グリッド、右側の実予定3件、上下の区切り線、下段全幅の天気カードが重ならず収まることを確認した。
- 新規予定フォームを開いた実画面を`dist/verification/calendar-editor-layout.png`へ保存し、上段右側だけに縦スクロールバーが現れ、フォームが下段の天気エリアへ重ならないことを確認した。保存は実行せず、検証後にアプリを再起動して未保存draftを破棄した。
- 実アプリを120fps・3.0秒で`dist/verification/calendar-weather-motion.mov`へ録画した。1.2秒で本日のアイコン、1.4〜1.8秒で週間アイコンが左から順に表示され、2.0秒で8個が揃い、2.8秒でも全アイコンが維持されて再ループしないことをフレーム確認した。
- 生成Info.plistに位置情報permission keyがないこと、通常起動が期待したbundle pathの1 processであることをreadbackした。
- `bash -n script/build_and_run.sh`、`git diff --check`: 成功。

## Remaining constraints

- Open-Meteo無料APIは非商用条件。現行の無料配布前提から商用化する場合は配信前にAPI契約またはセルフホストへ切り替える。
- 都道府県全域の予報ではなく、都道府県庁所在地付近の代表予報。
- 予定詳細・編集のスクロールはSwiftUIの単一ScrollViewとビルド・63ケースのlayout verifierで確認した。実Google Calendarへ予定を追加・変更・削除する操作は行っていない。
- Windows版の天気表示とSettingsは未実装。Windows実機担当で同じ47地域コード、キャッシュ、当日＋7日表示を別途実装・検証する。
