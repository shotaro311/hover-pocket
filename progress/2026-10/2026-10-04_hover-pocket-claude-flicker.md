# 2026-10-04 Windowsプレビューの残りのちらつき（Claude担当）

2026-10-04 / Claude Opus 5.5による修正・Codexによる検証と追加調整 / 開発版`0.2.9-local.14`（通常起動とreadback済み）

## 最終結果

先にlocal.13までの変更を`e49c69b`「Windowsの素材管理と撮影・プレビュー操作を改善」へコミットし、clean状態からClaudeへ依頼した。ClaudeはWindows端末の`claude-peer`経由、Opus 5.5・medium、セッション`fb4612c5-9bb3-45ea-8657-0c08eb466519`。CLIの実行権限によりClaude側では動作検証できなかったため、修正を読み戻したCodexが検証を引き継いだ。以下の未実施表記はClaudeから引き継いだ時点の記録で、最終結果は末尾に示す。

Codexは提供動画の10.0〜11.2秒を30fpsで確認し、拡大の終了時にパネル全体が黒くなる1フレームを確認した。修正後のネイティブクリック→Spaceによる3往復の録画では、この全面が黒くなるフレームは再現していない。素材UI回帰、Debug/Release、JS構文も通過し、12:47 JSTにlocal.14を通常起動した。設定ハッシュと素材6件・未完了操作0件・schema 1・quick_check=okの不変を確認した。

Claudeの追加修正とCodexの検証・調整は、先に作ったコミットに対する未コミット差分として残す。push・公開・自動起動登録の変更は行っていない。

## 依頼

ユーザーが local.13 で「良くはなった。でもまだ少しちらつきがある」と報告し、親Codexが e49c69b のコミット後に Claude へ原因調査・ローカル修正・検証を依頼した。再現動画は`AssetLibrary\outbox\c286f7dd-…\asset-画面収録 2026-10-04 10-02-15.mp4`（1920×810、30fps、15.80秒、読み取りのみ）。

## Claude実行時の制約

このClaudeセッションでは、`ffmpeg`、`dotnet`、`python <script>`、`powershell -File`の実行がすべて権限確認で止まり、非対話のため承認できなかった。動作したのはファイルの読み書き、`git status/diff`、`ls`などの読み取りだけである。

- 提供動画のフレームは**取り出せず、目視していない**。`artifacts/claude-flicker-20261004/extract.ps1`（フレーム抽出用）と`probe.py`を作成したが未実行。
- Debug/Releaseのビルド、`--verify ui`のプレビュー専用検査、実画面収録は**未実施**。
- したがって、以下の原因は動画からではなく、コードの読解と local.13 の検証資料（`artifacts/preview-smooth-20261003/motion-final-open.png`）から特定したものである。動画との対応づけは親Codexの確認待ち。

## Claudeがコードから判断した原因候補

### 1. グリッド再描画のたびにサムネイルが一瞬消える（assets.js）

`renderGrid()`は毎回`grid.replaceChildren()`で全カードと`<img>`を作り直し、data URLを`src`へ再設定していた。新しい`<img>`はデコードが終わるまで空で描画されるため、再描画のたびにサムネイルが1〜数フレーム消え、種類アイコン（▧/▶/PDF）が見える。

`renderGrid()`は次の操作で呼ばれる。

- カードのクリック（`select()`）。ダブルクリックでプレビューを開くと、1回目・2回目のクリックで2回点滅し、その直後に開始時の表示保持画像を取得する。点滅中の画面が保持画像に入ると、拡大中も消えたサムネイルのまま表示される。
- プレビューを閉じたとき（パネル縮小の`ResizeObserver`と`endPreview()`の明示呼び出しの2回）。縮小後の生画面でサムネイルが点滅する。
- パネルを開いたとき（`panel.opened`→`refresh`）とスクロール中。

local.13 の`PreviewMotionVerifier`は`dblclick`イベントだけを送り、クリックによる選択を経由しないため、この経路を検出できなかった。

### 2. 切替の終わりに前面の保持画像を先に消している（PanelWindow.cs）

`ResizeContentAsync`の終了処理は、本体の`Opacity = 1`を設定した直後に、表示保持用ウィンドウを`Hide()`していた。`Hide()`は即時に反映される一方、`Opacity`はWPFの次の描画フレームで反映される。そのため、本体がまだ`Opacity = 0`のフレームを表示している間に保持画像が消え、1フレーム空の面が見える可能性があった。

### 3. 閉じる操作で到着画像の取得と最終DOMが競合（assets.js）

`endPreview()`は`assets.endPreview`でパネル縮小を始めてから、ブリッジを数往復した後に`renderGrid()`等を呼んでいた。縮小先の画像取得（2回の`requestAnimationFrame`後）が先に終わると、保持画像と生画面の内容が異なり、切替の終わりに表示が変わる。

## 変更

- `windows/ui/providers/assets/assets.js`
  - `renderGrid()`で、作り直す前のカードからデコード済みの`<img>`を資産IDで回収し、新しいカードへ移す。クリック・ダブルクリック・ドラッグの処理、選択表示、名前、容量は従来どおり毎回設定する。
  - `endPreview()`で、表示状態とグリッド・選択・詳細の再描画を`assets.endPreview`より前へ移した。縮小後の`ResizeObserver`による再描画は到着画像の取得前に起きる。
- `windows/src/HoverPocket.Shell/Windows/PanelWindow.cs`
  - 切替の終了時に`Opacity = 1`を設定した後、WPFの描画を2フレーム待ってから保持画像と保持用ウィンドウを外す。待機中に次の切替・閉じる操作が来た場合は、新しい処理に後始末を任せる（既存のrevision判定）。外した後に`ApplyLiquidSurface()`を呼び、WebViewの操作可否を戻す。
  - 既存の2フレーム待機を`WaitForRenderedFramesAsync`へまとめた（開始時の挙動は従来どおり）。
- `windows/src/HoverPocket.Shell/HoverPocket.Shell.csproj`: `0.2.9-local.14`。

録画ショートカット、保存データ、注釈、全画面、Space長押し抑止、元に戻す操作のコードは変更していない。

## Claudeの引き継ぎ時点の確認

| 項目 | 結果 |
| --- | --- |
| 提供動画のフレーム目視 | 未実施（ffmpeg実行不可） |
| Debug / Release build | 未実施（dotnet実行不可） |
| JS構文検査 | 未実施（node/python実行不可）。差分を目視で確認 |
| プレビュー専用検査・実画面収録 | 未実施 |
| `git diff`の読み戻し | 実施。変更は上記3ファイルのみ |

## 親Codexへの引き継ぎ項目

1. 提供動画のフレーム抽出と、上記原因との対応確認（例: カードのクリック直後や閉じた直後にサムネイルが消えるか、切替の終わりに1フレーム空になるか）。`extract.ps1`はffmpegを呼ぶ補助スクリプト。
2. `dotnet build windows/HoverPocket.Windows.sln -c Debug -v:q`
3. `artifacts/capture-fix-20261003/build-preserving-metadata.ps1 -AssetOutput artifacts/asset-local-14-claude-flicker`
4. `HOVERPOCKET_PREVIEW_MOTION_VERIFY_ONLY=1`、`HOVERPOCKET_VERIFY_LOG`、`HOVERPOCKET_MOTION_RECORDING`を設定して`--verify ui`。加えて、実際にカードを1回クリックしてからダブルクリックで開き、閉じる操作を実画面収録し、サムネイルが消えないことを連続フレームで確認する（現行検査は`dblclick`だけを送るため経路1を通らない）。
5. 素材UIの既存回帰（選択、ドラッグとゴミ箱、Ctrl+Z、全画面）。

通常版（PID83468、local.13）の停止・切替と保存データのreadbackは親Codexの担当で、Claudeは実施していない。Claudeは検証プロセスを起動していない。

## Codexの追加調整と受入結果

`select()`でクリックされたカードを作り直していた処理も取り除き、選択状態だけを更新するようにした。`PreviewMotionVerifier`は実マウスでカードを選択し、Spaceキーで開く経路へ変更。クリック直後もデコード済みサムネイルが残ることと、実入力（trusted=true）であることを検査した。専用検査の最初にポインターをパネル内へ固定し、表示前のままマウス検査を行わないようにした。

| Codexの検査 | 最終結果 |
| --- | --- |
| 提供動画 | 30fpsの連続フレームを目視。10秒台の拡大終了で全面が黒くなる1フレームを確認 |
| 修正後の実画面収録 | 実クリック→Spaceによる3往復。拡大・縮小の連続フレームで全面が黒くなる現象とサムネイル消失は再現せず |
| プレビュー専用検査 | exit 0。実クリック3回、画像デコード保持、拡縮時のウィンドウ寸法変更各2回、30/120/300ms後の取消と操作領域復帰 |
| 拡大の測定 | 596.9〜602.9ms、最大フレーム間隔23.0〜30.4ms。画面収録を同時実行した3回の値 |
| 素材UI回帰 | exit 0。選択回帰15件、編集・原本保持、実ドラッグとゴミ箱・復元、PDF、H.264、全画面と背景動作 |
| Release / Debug | 警告0・エラー0。Releaseは既存の非公開ビルド設定を保持 |
| JavaScript / 差分 | JS17ファイルの構文検査、git diff --checkが成功 |
| 100回開閉 | 今回は実施せず |

途中の失敗も保持した。検証コードの生文字列の括弧不足、パネル表示を保たないまま実クリックした試行は検査側の問題として修正した。マウス注入でのダブルクリックはクリック数が1/3になる試行があり、成立を確定できなかったため合格扱いにしていない。最終の実入力検査はクリック→Spaceで行い、ダブルクリックのUIハンドラーは既存のDOMイベント検査で確認した。実機でのダブルクリックの追加確認は残る。

通常版の切替直前にPID83468のパス・生成時刻、表示中のウィンドウなし、撮影・取り込み・purgeの未完了なしを確認。設定と整合したSQLiteのバックアップ後にそのプロセスだけを停止し、local.14を起動した。依頼されたローカル改善の反映として追加確認なしで実施した。PID74228、実行パス一致、応答あり、設定ハッシュと素材6件・未完了取り込み0件・未完了purge0件・schema 1・quick_check=okは切替前後で一致。

追加の開く瞬間の修正（local.15）は[別の作業記録](2026-10-04_hover-pocket-claude-opening.md)を参照。

証拠は`artifacts/claude-flicker-20261004/`。`input-transition-10.png`、`motion-native-space.log/mp4`、`fixed-transition-open.png`、`fixed-transition-close.png`、`assets-final.log`、`debug-build-final.log`、`startup-readback.json`、`baseline.json`、Claudeの`response.json`。元の動画と別のdirty checkoutは保持。自動起動登録は既存local.2のまま。実複数モニター・異なるGPU・DPI全組合せ、長時間の連続使用は未検証。
