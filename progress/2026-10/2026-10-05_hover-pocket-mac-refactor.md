# 2026-10-05 Mac / Windowsリファクタリング — Mac側

ユーザーが両OSの責務整理とコミット・プッシュを依頼。Macはこのチャットで担当し、WindowsはWindows Codexの既存チャット「スクリーンショット時のクラッシュ修正」（`01a0ff46-72f0-7582-afea-1f910bf1abb6`、S311-win）へ依頼した。

作業先は `/Users/shotaro/.codex/worktrees/mac-asset-library/hover-menu-preview`、ブランチは `codex/macos-asset-library-0210`。元checkoutのdirty変更はそのまま保持。前回検証済みの素材実装と引き継いだ液体アニメーションを `7931f8e`「Mac版に素材管理と撮影・収録機能を追加」へ先に保存し、今回の整理と区別した。

## 変更

| 責務 | 整理後 | 目的 |
| --- | --- | --- |
| 表示先画面の選択 | `Windowing/PanelScreenSelection.swift` | メイン/セカンダリ/全画面の選択と画面識別を1か所へ。重複した画面の並べ替えを統一 |
| 反復検査のプロセス計測 | `App/PanelProcessMetrics.swift` | thread/RSS/socket/childの計測を表示制御から分離 |
| ネイティブWebViewとファイルドラッグ | `Assets/AssetWebView.swift` | 素材操作のモデルと、ネイティブ画面・マウスイベントの管理を分離 |
| DB行からの素材復元 | `Assets/LibraryAsset+DatabaseRow.swift` | 一覧読取り・通常スナップショット・破損DB復旧の3か所にあった変換を共有 |

`HoverWindowController` は1,654→1,505行、`AssetPaneModel` は409→317行。既存処理を移す際に外部依存や互換層を加えていない。WebView/ドラッグとプロセス計測は、アクセス修飾子を除いて土台コミットの処理本文と一致することをプログラムで照合した。

正常なDBの動作は保持。不正なサイズ値等は強制アンラップで終了せず、素材DBの読取りエラーとして返す。異常値を入れたSQLiteからの読取りが失敗しても原本SHAが変わらない検査を追加した。schema1、manifest、共有JS、設定形式、公開バージョンは今回の整理で変更していない。

## 検証

Macの開発ビルド662、Bundle ID `local.codex.hover-pocket.asset-dev`、Keychain識別子接尾辞 `asset-dev`。macOS 27.0 (26A428)、arm64。検証は一時データと検証用設定で行い、本番アプリを置換していない。

- `script/build_and_run.sh --build-only`: 成功。最初は移した `screenKey` を関数値として参照する1か所が残りビルドに失敗した。参照を修正して成功。
- `script/verify_mac_assets.sh --skip-build`: exit 0。保存40項目（不正DB行の追加1項目を含む）、UI58項目（共有JS45項目を含む）、再開2項目。実撮影と音声3モードの短い収録もpassed。
- 同スクリプトの既存検査: レイアウト128ケース、クリップボード、タイマー、パネル100回が通過。window 3→3、thread 15→8（最大16）、RSS 101.859→104.688MiB、socket/child 0→0。
- `--verify-liquid-motion`: exit 0。既存の形状/マスク検査、表示4サイズ、2種類の上端接続、モード切替10回、自動設定切替4回、途中反転30回、外部ドラッグ後の復帰、100回反復が通過。追加の反復ではwindow 4→4、thread 9→9（最大10）。
- `git diff --check` とアプリ署名の厳密検証が通過。

原本とSQLiteを別のPython経路で読み直し、library 5件・Mac復元先4件・Windows fixture 1件のquick_check、外部キー、サイズとSHAが一致。Windows fixtureのMac再出力は、バックアップ作成時刻を除いて整理前の出力と一致した。元checkout2,099ファイルも変更0・欠落0。

[検証結果と独立readback](../evidence/2026-10-05-mac-refactor/independent-readback.json)、[保存](../evidence/2026-10-05-mac-refactor/core-result.json)、[UI](../evidence/2026-10-05-mac-refactor/ui-result.json)、[再開](../evidence/2026-10-05-mac-refactor/reopen-result.json)、[反復](../evidence/2026-10-05-mac-refactor/panel-soak.log)、[アニメーション](../evidence/2026-10-05-mac-refactor/liquid-motion.log)。

実行時の詳細資料は `/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/HoverPocket-Assets-SfxMXo` と `/private/tmp/hp-refactor-motion-20261005`。リポジトリへ保存する根拠はJSONと検査ログに限定し、実マイクの録音は含めない。

## 残る条件

今回の整理で、前回未受入だった外部への実ドロップ、通知の全操作、長時間収録、権限拒否、複数画面、両OS実機往復を受入済みにしない。アニメーション検査の複数画面部分も単一画面のためskip。注入したノッチfixtureを実ノッチ端末の受入としない。

Windows側は独立してコード・検証・コミット・プッシュを担当する。各OSのブランチをレビューしてから統合する。mainの更新、公開リリース、更新feed、本番アプリの置換は今回行わない。

[実施計画](../../docs/plan/20261005_MAC_WINDOWS_REFACTOR.md) / [素材機能の実装記録](2026-10-05_hover-pocket-mac-assets.md)
