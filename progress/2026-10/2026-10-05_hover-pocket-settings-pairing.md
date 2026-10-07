# 設定画面の整理とコードによる端末連携

## 依頼と担当

Windows側のユーザー依頼を確認し、Macは設定UI・ネイティブ連携・同OS検証を担当。Windowsは共通PAKE helper・Windows側を担当する。既存19件の同期とEagle共有を保持する。

## Mac設定UI（開発版669）

- 「一般・表示・素材と同期・撮影・AI・詳細」の6カテゴリに整理。説明段落を減らし、操作ごとのカードと詳細の折りたたみを採用。カレンダー/天気は一般、音声/自作ツールはAI、操作履歴は詳細へ配置。
- 音声の確認スイッチ、カレンダーアクセス確認、キーの保存/削除、履歴削除確認を保持。各ページを保持する既存構成も維持。
- 同期のオン/オフ、受信待ち、競合、エラーを表示。フォルダ指定は接続の詳細へ移動。実行中に停止が競合しないよう操作を直列化。
- 音声E2Eの隔離起動では素材同期と撮影カテゴリを除外し、同期ループの起動にも外部連携のガードを追加。
- 英語切替時の設定ウィンドウ名が一つ前の言語になる問題を修正。

## 検証

- Swiftビルド669成功。音声契約42ケース、パネル配置128ケース/設定保持、音声確認23項目、同期47項目が通過。設定カテゴリの外部連携隔離も追加検査。
- 実UIで6カテゴリ、音声詳細の展開、既存の確認設定、カレンダー/天気、同期オン表示を確認。日本語と英語の表示設定を確認し、日本語へ戻した。
- 変更前に実DBを別経路で読み戻し：素材19件（通常14/ゴミ箱5）、原本全SHA、保留/競合0、Eagle共有と端末設定保持を確認。変更後も同じ19件と全原本SHA、保留/競合0、Eagle共有/device保持を再確認。
- 公開配信、main統合、実端末の追加/解除は未実施。

## コード連携（実装中）

共有helperはWindows担当。Mac側の暗号実装は追加しない。

- UIを `455c6fe` にcommit/pushし、remoteとlocalのSHA一致を確認。開発版669を再起動し、日英切替でウィンドウ名も即時反映されることを確認して日本語へ復帰。
- MacのローカルSyncthing API clientを実装。loopback限定/リダイレクト拒否、既存共有のpath一致、Eagleとglobal deviceの保持、専用共有だけの端末追加/解除、失敗時の追加所属の取消とreadbackを用意。新規deviceのintroducer/autoAcceptFoldersはfalse。
- `--verify-library-pairing` の模擬API検査23項目が成功。誤接続先、無効GUI、既存情報保持、二重追加、既存所属の保護、失敗/readback不一致、新規共有の安全設定を含む。`swift build -Xswiftc -warnings-as-errors` 成功。CIと既存Mac検証スクリプトに追加。
- clientは共通helper受領後の接続用の準備で、実アプリから端末追加/解除はまだ呼び出していない。実Syncthingの変更は0。Windows側で共通コードのGitHub送信に対する自動承認レビューの確認待ち。別経路で転送せず、ユーザー回答後の共通helper受領・Mac梱包・コードUI・暗号化の両OS往復検証が残る。
- Macの通常PATHはcargo/rustc 1.87だが、`~/.cargo/bin` にstable 1.94.1、toolchain 1.95.0も存在。共通helperのlockfileに合わせて既存toolchainを使用可能。
ローカルSyncthing APIの公式仕様を確認し、専用共有の端末追加/解除とreadbackを準備する。

- https://docs.syncthing.net/rest/config.html
- https://docs.syncthing.net/rest/system-status-get.html
- https://docs.syncthing.net/rest/system-connections-get.html

端末承認前に素材を共有しない。ローカルAPIキーはネイティブ内部だけで扱う。解除しても既存の受信ファイルとEagle共有を保持する。

## 最終UI確認（開発版670）

- エラー時は赤、同時編集の重複時は橙の状態表示へ修正。670をビルド・署名し、梱包後も模擬API23項目が成功。
- 開発アプリを670へ起動し直し、6カテゴリと「素材と同期」の同期オン/操作欄を実UIで確認。共有コードの受け取りとコードUIの接続は引き続き未完。
- 接続準備 `6a29de2` もpushし、remote SHA一致とclean状態を確認済み。元のdirty checkoutは変更しない。

## Windows担当からの検証結果（2026-10-05）

- 担当チャット「スクリーンショット時のクラッシュ修正」（`01a0ff46-72f0-7582-afea-1f910bf1abb6`）の報告と実行ログを読み戻した。Windowsの6カテゴリ/検索/折りたたみ、コードUIとネイティブ連携処理は実装済み。
- 素材保存120・同期102、共有API/状態33、Rust入力検査5、PAKEの正常/誤コード/拒否/古い承認/グループ不一致5ケース、実WebView UIと設定回帰が成功との報告。共有API/状態33の成功出力を確認。
- Windows内に隔離したSyncthingを2プロセス起動し、承認前の共有0、実RESTでの登録/readback、生成ファイルの原本とmetadataの転送、専用共有だけの解除/global device保持まで成功した実行ログ（exit 0）を確認。これはWindows内の隔離試験で、Mac/Windows間のコード接続受入ではない。
- 実データの独立readback出力：素材19件（通常14/ゴミ箱5）、原本19件がDBのSHAと一致、以前の原本を保持、保留/未送信/競合0、quick_check=ok。Eagleを含む既存共有とglobal deviceは一致。同期対象metadataのdigestは既存の `c1627f9a06bf2a66b52f0c780d786bac897a552750c362be2d29be3c08794b92` と一致。
- 共通helperは `f2e410b` に集約済み。Rust 1.87互換の固定依存、Windows/Mac向け依存ライセンスを含む。GitHub送信は自動承認レビューによる明示確認待ちで、Macにはまだ取り込んでいない。別経路のコード転送を行わない。
- Windows側の詳細記録は、担当端末の `progress/2026-10/2026-10-05_hover-pocket-windows-settings-pairing.md`。送信待ちのためMacのcheckoutにはまだ存在しない。
- 残り：共通helperのpush許可→Macでhelper/ライセンスの同梱とコードUIへの接続→Mac/Windows間の隔離接続試験。既存の実接続を解除して再接続する受入、Windows候補の常駐切替、公開配信、main統合は未実施。
