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
- 週間予報へ見出しを追加し、曜日、アイコン、最高/最低気温、降水確率を拡大した。7列を上揃えにし、各SF Symbolを同じ高さの枠へ収めたため、晴れ・曇り・雨など固有寸法が異なっても曜日・アイコン・数値の各Y位置が揃う。上段右側の予定詳細と予定編集は単一の縦ScrollViewで扱い、内容が上段の高さを超える場合だけスクロールできる。
- Calendar表示ごとに、本日のSF Symbolを先に、週間7個を70ms間隔で続けて挿入する一回限りの`symbolEffect(.appear)`を追加した。macOS 15以上では、晴れを`rotate.clockwise`、晴れ時々曇りを雲固定・太陽のみ`rotate.clockwise`、曇り・霧を`breathe.pulse`、雨を`variableColor.iterative.reversing`、雪を`wiggle.down`、雷を`pulse.byLayer`で約5秒再生する。macOS 14ではPulse / Variable Colorへフォールバックする。5秒後はエフェクト付きView自体を静止Viewへ置き換え、OS側の反復状態に依存せず停止する。表示中の天気更新では再生せず、パネルを閉じた時だけ次回分をリセットする。Reduce Motion有効時と静止画検証時は全アイコンを即時表示する。
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
  - `weather_weekday_alignment=fixed`
  - `weather_symbol_motion_presets=6`
  - `weather_symbol_motion_modern=rotate,breathe,variable-color,wiggle,pulse`
  - `weather_symbol_motion_fallback=pulse,variable-color`
  - `weather_condition_motion_duration_seconds=5.0`
  - `weather_reduce_motion_render=immediate`
- 実際のOpen-Meteo応答を使ったSwiftUI描画を`dist/verification/calendar-weather-preview.png`へ保存し、当日気温、状態、最高/最低、降水確率、今後7日間が左右に分かれて欠けずに収まり、週間7列の曜日・アイコン・気温・降水確率がそれぞれ同じY位置へ揃うことを画像確認した。
- `.build/debug/HoverPocket --verify-panel-layout`: `panel_layout_verify=ok`、63ケース成功。
- `./script/build_and_run.sh --verify`: Apple Development署名付き`dist/HoverPocket.app`を生成し、起動成功。
- `dist/HoverPocket.app/Contents/MacOS/HoverPocket --verify-weather`: bundle内実行ファイルでも同じweather verifierが成功。
- `codesign --verify --deep --strict --verbose=2 dist/HoverPocket.app`: 成功。
- 起動したLargeパネルを画面合成経路で`dist/verification/calendar-panel-layout.png`へ保存し、6週の月グリッド、右側の実予定3件、上下の区切り線、下段全幅の天気カードが重ならず収まることを確認した。
- 新規予定フォームを開いた実画面を`dist/verification/calendar-editor-layout.png`へ保存し、上段右側だけに縦スクロールバーが現れ、フォームが下段の天気エリアへ重ならないことを確認した。保存は実行せず、検証後にアプリを再起動して未保存draftを破棄した。
- 実アプリを120fps・3.0秒で`dist/verification/calendar-weather-motion.mov`へ録画した。1.2秒で本日のアイコン、1.4〜1.8秒で週間アイコンが左から順に表示され、2.0秒で8個が揃い、2.8秒でも全アイコンが維持されて再ループしないことをフレーム確認した。
- 実アプリを約43fps・8.9秒で`dist/verification/calendar-weather-modern-motion.mov`へ録画した。本日の「晴れ時々くもり」は純正`sun.max.fill`と`cloud.fill`を重ね、雲を固定したまま太陽の光線だけが回転することを確認した。回転中の2.1秒・2.3秒フレームで光線角度が変化し、停止後の7.5秒・8.0秒・8.5秒フレームは画像ハッシュが完全一致した。モーション中も週間7列の曜日位置は固定されていた。
- `swift test`はPackageにtest targetがないため`no tests found`。代わりに実API weather verifier、63ケースのlayout verifier、静止画、実アプリ録画で今回の変更を検証した。
- 生成Info.plistに位置情報permission keyがないこと、通常起動が期待したbundle pathの1 processであることをreadbackした。
- `bash -n script/build_and_run.sh`、`git diff --check`: 成功。

## Build 150 release

- 天気機能とモーションを含む機能commit `96d11ce`までの5 commitを`origin/main`へpushし、push直後のlocal / origin SHAは`96d11cedfd5d4571b3fa35735b55ef24d1caf408`で一致した。
- `APP_VERSION=0.1.0`、`APP_BUILD=150`でDeveloper ID Application署名・hardened runtime付きの配布ZIPを作成した。アプリ内feedはmacOS専用`https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml`、最小OSは14.0。
- Apple公証submission `e0430c08-b7da-457f-ab3f-94afd8011358`は`Accepted`。staple後のアプリ本体とZIP展開後アプリは`codesign --verify --deep --strict`、`stapler validate`、`spctl --assess`に合格した。
- GitHub Release [`v0.1.0-150`](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-150)をdraft / prereleaseではないGitHub Latestとして公開した。4 assetは`appcast.xml`、versioned ZIP、SHA256、手動インストールZIP。`macos-latest`は手動インストールZIPとappcastを同じbuildへ同期した。
- GitHub APIのversioned ZIP digest、匿名公開URLから再取得したZIP、ローカルZIPのSHA-256はすべて`507fe20a598794588f845d29170c904f4db82f4b1f301924b0ddb08caf2364e0`で一致した。
- versioned / stable appcastはSHA-256 `0618463faabe19d7abf945e1963afd0475d5ae504848d3d61089b88ededa4ff1`で一致し、`sparkle:version=150`、`v0.1.0-150/HoverPocket-0.1.0-150.zip`、88文字のEdDSA署名を返した。
- 公開ZIP展開後の`HoverPocket --verify-weather`は47地域、当日＋7日、地域保存、オフラインcache、週間行固定、6モーションプリセット、5秒設定を再確認して成功した。
- Windows release `win-v0.2.3`は8 asset、target commit `7bfbee4ed54ed989b1ad470fd4420b0d8efeda13`で公開前から不変。macOS Latest更新によってWindows feedやassetは変更していない。

## Remaining constraints

- Open-Meteo無料APIは非商用条件。現行の無料配布前提から商用化する場合は配信前にAPI契約またはセルフホストへ切り替える。
- 都道府県全域の予報ではなく、都道府県庁所在地付近の代表予報。
- 予定詳細・編集のスクロールはSwiftUIの単一ScrollViewとビルド・63ケースのlayout verifierで確認した。実Google Calendarへ予定を追加・変更・削除する操作は行っていない。
- Windows版の天気表示とSettingsは未実装。Windows実機担当で同じ47地域コード、キャッシュ、当日＋7日表示を別途実装・検証する。
