# Windows ライブラリ同期

## 実装

- 共通契約 sync-v1（bf1c99e / fixture 635bc9c）を使い、各端末のSQLiteを独立して維持する。Syncthingは専用transportのSHA原本と不変イベントだけを送る。イベントはDB outboxから再送でき、受信は同じwriter区間でローカル変更を保存してから適用する。
- 初期オフ。設定画面から専用フォルダへの新規作成/参加、一時停止/再開、競合時のこの端末/受信版の選択ができる。3秒ごとの非重複バックグラウンド処理で、受信後に素材一覧を更新する。操作中の定期読戻しが選択やエラー表示を上書きしない。
- 原本、名前、親子フォルダ、タグ、所属、お気に入り、ゴミ箱/復元を同期。SHA重複は既存IDを保持する。同名分類と同時変更は競合として保持し、解決イベントで両枝を参照する。過去の競合枝は履歴に残し、最新の競合だけを選択肢にする。
- 逆順到着・原本の遅延は保留する。削除済み分類の古い参照は所属から外し、親削除済みならルートに戻す。分類削除の副作用をローカル変更として再送しない。
- 別グループ、未知形式、改変イベント、原本のサイズ/ハッシュ不一致、リンク/ジャンクションを拒否。Internet由来の保護属性は弱めない。ゴミ箱を空にする前に原本をtransportへ確定し、端末間では物理削除を行わない。
- DB復元は同期を止めてから行い、現在の同期履歴を保持して一時停止状態を維持する。同期使用歴があるDB自体が壊れた場合は、同期履歴を確認できない巻き戻しを拒否する。同期未使用の従来のDB復旧は維持する。完全バックアップによる同期済みライブラリの置換は拒否し、別の空ライブラリへの復元を案内する。

## 検証

証跡: [windows/verification/library-sync-20261005](../../windows/verification/library-sync-20261005/)。

- 共通fixture 15件を含む同期検査102判定がPASS。追加/分類/階層/名称/お気に入り/ゴミ箱/復元/重複SHA、両方の競合解決、同名分類の修正再試行、失敗した解決の非公開、配送逆転/原本最後/新端末の全履歴再生、切断/復帰/停止/再開、送信失敗後の再起動、改変拒否、リンク拒否、DB復元時の履歴維持を確認。
- 既存の素材保存/復旧120検査がPASS。初回に同期未使用の破損DB復旧を止める退行が見つかり、同期使用歴の保護印と現DBの状態を区別して修正した。
- Debug/Releaseビルドは警告0・エラー0。Releaseは稼働中アプリの出力を避け、artifacts/sync-release-20261005へ生成。
- 実WebView2で新規作成/有効化/一時停止/再開/競合版表示/受信版採用/英語表示/設定画面に限定したbridge権限を確認。DebugとReleaseでPASS。UI-model、既存voice-foundation/BYOK/native回帰もPASS。
- JavaScript構文とgit diff --checkがPASS。

## 実Syncthing往復

- 専用共有ID hoverpocket-library-sync-verify-20261005。Windows transportは E:\HoverPocketSyncTransport-verify-20261005、検証DBは E:\HoverPocketSyncVerify-Windows-20261005\library。Mac transportは /private/tmp/HoverPocketSyncVerify-transport-20261005。
- 既存SyncthingのShotaro Mac接続を利用し、この共有だけ追加。操作前後でEagleの既存2共有とdevice設定の完全一致を確認した。Eagleライブラリ・transport・stateへ直接のファイル操作なし。
- Mac由来「Mac-日本語.txt」をWindowsへ受信し、SHA 35a59c0e…とDBの一致を確認。
- Windows由来「Windowsからの同期テスト.txt」、親子フォルダ、タグをMacへ送信。SHA b949c16ff62b4bf707a5100d71bf89f22094db92221052141f92c38d1b1ae4ac、57bytes。
- Macから「Macから更新.txt」・favorite=true・trashed=trueを受信し、WindowsのDBと原本SHAで照合。Windowsで復元して「Windowsで復元.txt」に変更。Mac担当がfavorite=true/trashed=false/同じSHA、active2/pending0/conflict0を読み戻した。
- Windows側も最終のpending/outgoing/conflictsが0。共有は検証専用のまま証跡を保持。SyncthingのneedFiles=0だけを成功条件にはしていない。

## 実行範囲と引継ぎ

- Windowsソース/UI/検証/この日別記録を本branchでcommit/pushする。共通契約・Mac実装・共通progress入口はMac担当が統合する。
- 実装時点では実ライブラリを同期オフで保持した。その後の明示承認による開発版切り替え・実ライブラリ接続は下記に記録。本番アプリの更新配信・正規インストール先・自動起動先は変更していない。
- 再検証: powershell -File windows/script/verify_asset_sync.ps1 -IncludeUi
- 実転送用CLI: dotnet run --project windows/tests/Assets.Sync -- --root E:\HoverPocketSyncVerify-Windows-20261005 --action once
- CLIは末尾名がHoverPocketSyncVerify-で始まる隔離rootのみ受け付け、readback.jsonへmanifest/status/SHAを保存する。create/joinには --transport、rename/trash/restore/favoriteには --sha（renameは --name）を指定する。

## 2026-10-05 実ライブラリへの接続

- ユーザーが旧開発版をトレイから終了し、PID75932のtray.quit / application.exit / process.exitを確認した。同期対応候補c66c0a8を通常起動し、PID69388のshell.readyを確認。正規インストール先・配布・自動起動先は変更していない。
- 切り替え前に実DB、原本16件、設定をLocalAppDataのSyncSetupBackupsへ保全。切り替え後の全既存テーブル、原本SHA、設定ファイル、正規インストールEXEの一致とquick_check=okを確認した。
- Windows側でも本人から専用共有追加と実ライブラリ同期の明示承認を受けた。Syncthingへhoverpocket-library-sync-v1 / E:\HoverPocketSyncTransportを追加し、既存Eagle共有・端末設定の完全一致を確認。Macで作成したmarkerと素材3件分の転送データが到着した。
- 常駐パネルと設定画面がComputer Useのtargetable windowに現れず、ユーザーが設定の「既存グループに参加」から専用フォルダを選択した。参加操作はユーザー回答とDBのconfigured=true / enabled=trueで確認し、設定画面を自動操作で検証したとは扱わない。
- WindowsのDBは16件から19件（通常14件・ゴミ箱5件）へ反映。全19原本のSHA一致、元16件の原本・素材名・お気に入り・ゴミ箱状態の保持、quick_check=ok、保留/送信待ち/競合0を確認。分類・所属は元から0件。
- 専用共有は39ファイルでidle、needFiles/needBytes/errors/pullErrors=0。Macと同じ形式で素材・分類の比較用ダイジェストを取得した。元設定との差分は手動操作に伴う最終選択パネルのみで、それ以外の設定と正規インストールEXEは保持。
- Mac担当の実DB読戻しでも19件（通常14件・ゴミ箱5件）、全19原本検証、保留/送信待ち/競合0を確認。指定の共通JSON形式でWindows/Macの比較ダイジェストが完全一致し、転送先到着だけでなく両端末DBへの反映を確認した。
- 実素材名・原本・設定値はGitへ保存せず、保全と比較証跡は非公開のローカルに保持する。
