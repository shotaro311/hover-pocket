# 個人用ツールの削除・macOS 634配信

## 状態

完了。macOS 0.1.0 build634を署名・Apple公証・本番公開し、公開ZIP/appcastを別経路で取得して照合済み。ユーザーが自然な操作と削除機能の受入通過後の本番配信を承認済み。

## 変更

- 追加依頼を受け、設定画面を7カテゴリの左サイドバーへ整理。表示・機能・自作ツール・音声・連携・履歴・一般へ分けた。設定値の保存先は既存のまま、選択カテゴリは画面内だけの状態。切替で依頼入力や各ページのスクロール位置を保持。標準ウィンドウは820×700、最小700×480で画面サイズへ制限。

- macOSの個人用ツール生成・編集・履歴復元・実パネル対応を本番へ統合。標準のMirror / Controls / Calculator / GoogleCalendar / TodayFocus / Clipboard / StickyNotes / Timerは維持。
- 削除確認から「アンインストール（記録を残す）」「記録・作成履歴も削除」を選択。完全削除はツール所有の定義・データ・履歴・内部バックアップをゴミ箱へ移動し、最後に削除済み管理情報を消す。途中失敗は再試行可能。
- symlink/hardlinkや不正なパッケージIDによる範囲外削除を拒否。標準TodayFocusを除外。別のツール、標準機能、生成された付箋・タイマー・予定、利用者が書き出したバックアップは保持。
- 未公開v2内部復元前データの保存先は匿名`BackupRestore/PriorData-UUID`から`BackupRestore/PriorData/packageID/UUID`へ変更。新しい内部保存分の所有者を追えるようにした。公開バックアップschema/APIは変更なし。旧v2はこの開発環境のテストのみで一般配布はなく、正体不明の旧匿名ディレクトリは自動削除しない。
- 公開633の最新アイコンPNG/ICOをソースタグから取り込み、配布済みアイコンを保持。Windowsは0.2.8の公開資産を変更しない。

## 検証

- Release634初回で削除関連13を含むplatform78、package/lifecycle/backup、WebKit16、実生成UI9と移行、Host操作、Broker、Personal Tools、Voice Foundation、Panel LayoutはPASS。
- 初回soakは`panel_soak_open_readback_failed`、同一バイナリで独立再実行は100開閉・100切り替え・5復旧・3アニメーションがPASS。原因は断定せず初回ログも保持。最終バイナリの結果は下記の配布物検証に記録する。
- 実際の設定画面で読書メモの削除をキャンセル→アンインストール→履歴から復元→再導入→同じ記録（ページ数42・読了true）→完全削除を確認。自作ツールのルート、データ、履歴が消え、別ツールの記録は残存。
- 再導入後に古い削除案内が残る表示を修正。
- Google Calendar Capabilityの実読取は`calendar_read_grant_required`で未検証。既存の権限設定を変更せず、実Google書き込みと物理カメラ・音声は今回の検証対象外。標準プロバイダー登録と既存関連検証で保持を確認。

根拠: `progress/evidence/2026-09-07-macos-release-634/`。先行実生成・実パネル検証: [本番UI受入](2026-09-07_hover-pocket-tools-production.md)。

- Debug実UIで7カテゴリ全て、日本語/英語、カレンダー接続済み表示、依頼入力の保持を確認。削除済み読書メモは再起動後も非表示、別の水やり記録は同一内容のまま。

## 連続開閉テストの隔離条件

初回の一括実行でパネルのフォーカス喪失通知を受け、`visible=false`、`selected=true`、`voice_off=true`、`voice_height=0`を記録した。単独Debugは通る場合があったが、起動時activateと待機追加だけでは安定しなかった。固定300msのアニメーション終了待ちでも一度停止した。各ログは証拠フォルダへ保持した。

最終版では、非操作soakの実行時だけOSからのフォーカス喪失による自動closeを無効にし、テスト自身がopen/closeを駆動する。通常起動の処理は有効のまま、UI受入でフォーカスを外した場合のcloseを確認する。アニメーションは最大2秒を上限として実際の完了状態を待つ。表示、選択、Voice OFF、ウィンドウ・監視timer・リソースのassertionは保持している。この条件でDebugの100開閉・100切替・5復旧・3アニメーションがPASS。

## 最終配布物のローカル受入

- Developer ID署名build634のplatform78、package/lifecycle/backup、HTML sandbox16、実生成UI9とmigration、実生成Host操作、Broker、Personal Tools、Voice Foundation、Panel LayoutがPASS。
- 配布時のSparkle feedをmacOS専用URLとして明示し、Google設定・location entitlementとともに別途readback。検証用build-onlyの既定ではfeedが空のため、配布用設定を付けて再署名し、同じ配布物で主要検証を再実行した。
- この再署名後の一括soakは最終thread数上限で一度停止。同一配布物の単独再実行は100開閉・100切替・5復旧・3アニメーションがPASS。window3→3、thread16→23（既存上限+8以内）、RSS115.2→121.3MiB、socket1→2（既存上限+1以内）、child0→0。初回の失敗ログを残し、`packaged-verification.json`にも両attemptを記録した。
- 最終配布物の実設定で水やりをアンインストール→履歴から再導入→記録をreadback→完全削除。2つの移行前バックアップも消え、別ツール・Timer/Stickyの4ファイルはSHA256が不変。再導入後の古い削除案内も消えることを確認。先に完全削除した読書メモは再起動後も復活しない。
- 実パネルから設定へ移動して7カテゴリを確認。自作ツールの入力保持と日本語/英語は同じSettings実装のDebug UIで確認済み。最終版の実画面ではフォーカスを外すとパネルが閉じることと、設定へ続けて移動できることを確認。標準サイズのスクリーンショットを保存。最小サイズへのGUIリサイズは操作が反映されず、最小寸法は既存layout検証で確認した。
- 標準Google Calendarは最終署名版で既存認証を使った実予定取得がPASS（再ログインなし）。Voice用Calendar Capabilityの追加権限は変更せず未検証。
- 公証前に全source digest、実行したバイナリのSHA256、build634、feed URLを読み戻し、実行後変更がないことを確認。検証用アプリだけを終了し、利用者の既存インストール633は起動を継続。

- Apple公証は`Accepted`。staple、Gatekeeper、最終ZIP展開後の署名・公証確認がPASS。公証前後でテスト済み実行ファイルのSHA256が一致。配布物の値は`notarization.json`へ保存。

## 本番公開

- macOS `v0.1.0-634`を公開し、`macos-latest`のappcastと手動ZIPを更新。source tag `71f96d5`をremoteからreadback。
- 対象sourceのGitHub「Verify Pocket Contracts」CIがsuccess（run 34114194978）。
- Windows `win-v0.2.8`の8資産は、公開前後でID・サイズ・digest・更新時刻がすべて不変。
- 公開物検証の既定はWindows正式署名基準のため、既存ベータmanifestに対して一度失敗。配布中のWindowsベータ仕様に合わせて`--windows-signing-gate beta`を明示し、両OSの公開物検証を実行し93項目がPASS。Windows正式版の署名条件を満たしたとは扱わない。

## 完了readback

- `release-readback.json`: macOS634 / Windows0.2.8、公開物93 checks PASS。
- `macos-gatekeeper-readback.json`: 公開先から再取得したZIP3種はローカルの公証済みZIPとbyte-identical。appcast2箇所も同一。Deep/strict codesign、staple、Gatekeeper、Sparkle公開鍵とfeed、Google/current-location配布設定を確認。公開メタデータも最後に再取得した。
- 公開ZIP SHA256: `d4257b95ab1009a9b733a7b8425c91b9cec2cb8db032fca13cf3c37afedf0839`。source tag: `71f96d5a662e35e1b60467641a8bae65b517e318`。
- インストール済みアプリは633。既存アプリの置換はせず、アプリ内の更新確認または[macOS配布ZIP](https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/HoverPocket-macOS-app.zip)から634へ更新できる。
- 依頼範囲のローカル実装・隔離データでの削除検証・ソース保存・本番配信を追加確認なしで実施。Windowsの新機能実装/再配信、物理カメラ/音声、Google書き込みは今回実施していない。
- [リリース](https://github.com/shotaro311/hover-pocket/releases/tag/v0.1.0-634)。
