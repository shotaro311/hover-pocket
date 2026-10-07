# 2026-10-05 Mac・Windowsの素材ライブラリ同期

## 依頼と方式

現在のEagle同期と同じ仕組みでHoverPocketの同期を実装する依頼。各OSのローカルDBを維持し、Syncthingで専用フォルダの原本と変更記録を交換する。既存Eagleのライブラリ・共有フォルダは変更しない。

共通仕様は `shared/asset-library/sync-v1/`。原本のSHA-256、変更の親履歴、固定グループIDを使う。DBは既存のversion 1へ同期用3テーブルを追加する。共通仕様を `bf1c99e`、15件の形式fixtureを `635bc9c` に保存した。MacとWindowsで同じfixtureを検証する。

## 実装

- Mac: actor内でローカル編集の記録、原本の確認・送信、受信の適用を直列処理。3秒間隔の確認は重複実行せず、停止で中断を要求する。設定から専用フォルダへの新規接続・参加・停止・再開・確認・競合選択を行える。
- 同期対象は原本、名前、お気に入り、フォルダ/タグと所属、ゴミ箱/復元。設定・検索・キャッシュ・チャット履歴は対象外。
- 同時編集は自動上書きせず内容を比較して選ぶ。同じ受信系列では最新の競合だけ表示する。送信前の変更記録はDBに保持し、原本の到着や親履歴が遅れた場合は待つ。同じSHAの素材は既存ローカルIDを保持する。
- 物理削除は相手に伝播しない。転送フォルダの原本と記録は自動削除しない。DB巻き戻しは同期停止を要求し、現行同期履歴は保持する。DB破損時はDB外の利用済み印も確認し、同期開始前のバックアップから復元しても履歴不明のまま再接続できない。同期未使用の通常DB復旧は維持。
- 配送順が逆転した検査で、削除済みの分類を古い素材が待ち続ける問題を検出し修正。削除履歴が確定している所属を解除して反映する。

## 検証

- Mac同期47項目: 共通形式15件、原本/親子分類/タグ、日本語名、SHA一致、名前/お気に入り、ゴミ箱/フォルダ復元、同時編集と両選択、受信系列の最新競合、再送時の重複防止、停止と再開、物理削除の非伝播と再復元、分類削除の反響防止、順序逆転/原本後着、異グループ/破損原本/リンク拒否、DB復元と同期履歴保護。成功。
- 既存検査: 保存54、UI70、別プロセス再開2、chat22、AI素材操作53、個人ツール42、音声確認23、capabilities/broker、panel layout、clipboard/timer、4サイズのパネル内チャット、100回開閉。成功。復旧の最終修正後も保存54項目を再実行し成功した。
- 最終ビルド668を署名確認後に起動し直し、設定の実画面で「データと履歴」に同期欄を表示し、初期オフ・新規/参加ボタン・説明が収まることを確認。
- 利用中Macライブラリは3素材、分類/所属/検索0。主要DB内容と原本SHAの前後一致を別経路で確認。実素材は検証用転送先へ送信していない。

## Mac・Windows間の実転送

テスト共有 `hoverpocket-library-sync-verify-20261005` を既存の両端末接続へ追加。既存のEagle共有の設定は前後一致。Macの `/private/tmp/HoverPocketSyncVerify-transport-20261005` とWindowsの `E:\HoverPocketSyncTransport-verify-20261005`、隔離ライブラリのみを使用した。

1. Macの日本語検証素材とフォルダがWindowsへ到着。
2. Windowsの日本語素材・親子フォルダ・タグがMacへ到着。
3. MacでWindows素材の名前変更、お気に入り、ゴミ箱移動を行いWindowsで受信。
4. Windowsで復元・再度名前変更し、Macで「Windowsで復元.txt」、お気に入り、所属を再受信。
5. 最終Macは通常素材2・ゴミ箱0・保留0・競合0。両原本SHAを全体計算して照合。

原本SHA: Mac `35a59c0efc895c6684a577c8324e50be7bb1d90979230aef6cc2beadc9189931`、Windows `b949c16ff62b4bf707a5100d71bf89f22094db92221052141f92c38d1b1ae4ac`。これは実転送の受入であり、転送速度の比較測定ではない。

## 本番接続と未実施事項

本番専用共有 `hoverpocket-library-sync-v1`、Mac `/Users/shotaro/hoverpocket-sync-transport` の作成を試みたが、自動承認レビューが「実装依頼だけでは、既存接続の端末を流用する永続的な外部共有設定まで承認されていない」と拒否した。実行前の拒否で共有・同期情報は未作成。Windows側にも本番追加・有効化を行わないよう連絡した。設定を他経路で迂回しない。

実装とテスト用の往復確認まで完了させ、本番共有の追加・実ライブラリ接続は対象を示してユーザー承認を求める。初期同期はオフ。テスト共有と隔離データは検証根拠として保持。大量素材の転送速度、長期間の運用、公開配布は未検証/未実施。main・公開macOS644・Windows0.2.10の配信は変更しない。

## 根拠と追記

- [Mac同期ログ](../evidence/2026-10-05-library-sync/mac-sync.log)
- [既存機能の検査ログ](../evidence/2026-10-05-library-sync/mac-regression.log)
- [往復受信の検証用マニフェスト](../evidence/2026-10-05-library-sync/cross-platform-readback.json)
- [利用中ライブラリ不変の照合](../evidence/2026-10-05-library-sync/user-library-preserved.json)

- Mac実装 `d8f97c8`、Windows実装 `c66c0a8` を統合コミット `28a3120` に集約。Windows差分、102項目の同期ログ、120項目の既存保存/復旧、実WebView2の設定操作、往復マニフェストをMac側でも読み戻した。[Windows担当の記録](2026-10-05_hover-pocket-windows-sync.md)。
- Mac最終開発版668の起動パスを確認（PID40767）。実行ファイルSHA-256は `4a228e340d5e83f771df423ecfbd66a7dd55330a6c406c8c8699b90ab67b4abd`。設定の同期欄はオフ。
- Macの既存CIへ同期47項目、Windows CIへ同期102項目と保存検査を追加。統合コード `7a148b5d59574c39b31d0cb866d4328995c0d534` のCIは全成功。 [Mac](https://github.com/shotaro311/hover-pocket/actions/runs/37308736387) / [Windows](https://github.com/shotaro311/hover-pocket/actions/runs/37308736393) / [3 OS契約比較](https://github.com/shotaro311/hover-pocket/actions/runs/37308736392)。
- 最終起動後もMacの素材件数3、原本SHA一致、DB quick_check=ok、同期enabled=falseを読み戻した。Windowsの開発版切り替えは担当スレッドで承認待ち表示となり、起動切り替え完了は未確認。同期対応ビルドの隔離実UI検証は成功済み。
- ユーザーへ、本番の専用共有追加と両端末の実ライブラリ同期有効化の承認を依頼した。回答前には実行しない。今回の追記は検証結果だけで、上記CI対象から実装を変更していない。

## 22:06 JST 本番同期への接続

- このMacチャットで専用共有の追加と両端末の実ライブラリ同期有効化を確認し、ユーザーの「いいよ」を受けて実行。Windows側も別途表示された確認へユーザーが同意した。
- Mac: 変更前のDBと原本3件を `~/Library/Application Support/HoverPocket/SyncSetupBackups/20261005-220659` に保全し、全原本SHA一致を確認。Windows: DB・原本16件・設定を同端末の `HoverPocket/SyncSetupBackups/20261005-220930` に保全済み。
- 専用共有ID `hoverpocket-library-sync-v1`。Macは `/Users/shotaro/hoverpocket-sync-transport`、Windowsは `E:\HoverPocketSyncTransport`。既存の2台だけを指定し、両端末でEagleを含む既存共有と端末設定が前後一致、Syncthing再起動不要を確認。
- Macアプリの新規初期化操作は一度自動承認レビューに止められた。対象フォルダが空でmarkerなし、アプリ未設定、バックアップ済み、ユーザーが新規共有追加を承認したことを確認し、同じ操作の再試行が認可されて完了した。
- Macの設定からグループを初期化して有効化。素材3件の原本・変更を送信し、送信待ち/保留/競合0を確認。Windows開発版c66c0a8も起動し、Macのmarkerと3件の転送データ到着を確認。
- Windowsはユーザーの設定画面操作で既存グループへ参加した。両端末とも同期enabled=true、素材19件（通常14、ゴミ箱5）、分類0件へ収束。送信待ち・保留・競合0、原本19件すべてのSHA一致を各OSで検証した。元のMac3件・Windows16件の原本とメタデータは保持。
- 同期対象の名前・容量・お気に入り・ゴミ箱・Internet由来属性・所属・分類を正規化したJSONのSHA-256が両端末で `c1627f9a06bf2a66b52f0c780d786bac897a552750c362be2d29be3c08794b92` に一致。個別素材の名前・原本・完全な比較データは非公開ローカルバックアップ内に保持し、Gitへ公開しない。[件数と検証結果](../evidence/2026-10-05-library-sync/production-readback.json)。
- 両端末Syncthingはglobal/local 39ファイル、need 0、errors 0。既存Eagle共有・端末設定は前後一致。Windows設定の変更は表示中の機能を記録する `lastSelectedProviderId` だけで、ユーザーの画面操作を保持した。
- Mac開発版668とWindows開発版c66c0a8で実ライブラリ同期を有効化済み。Windowsの起動切り替えと本番接続の保留は解消した。正規配布アプリ・自動起動先・main・公開版の変更は行っていない。
