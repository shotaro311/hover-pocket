# Windows 設定画面の整理とコードによる端末連携

## 依頼と作業場所

- フォルダ選択を通常の同期導線から外し、コード入力＋元端末の承認で接続する。Windows/Macの設定画面を見やすく短くする依頼。
- Windows: `codex/windows-library-extensions-20261005`、隔離worktree `C:/Users/shotaro/.codex/worktrees/windows-refactor-20261005/hover-pocket`。元checkoutの作業は維持。
- Mac: 既存の担当CodexへAstra/xhighで依頼。設定UI `455c6fe` と専用共有API `6a29de2` は担当側でcommit/push/readback済みとの報告。共通helperの取得・Mac UIへの接続・両OSのコード接続試験は未完。

## 実装

- 設定を一般・表示・素材と同期・撮影・AI・詳細へ分割。サイドバー、設定検索、短い見出し、カード、トグル、詳細折りたたみを追加。一般の起動・更新を上方へ移動し、音声をAIカテゴリの先頭に配置。狭いウィンドウと日本語・英語に対応。
- 同期は「端末を追加」「コードで接続」が通常の操作。既存の同期パスとグループは保持。新規接続だけアプリ管理の専用転送先を自動作成。手動フォルダ設定は接続の詳細に残す。
- 共通Rust helperはmagic-wormhole 0.8.1のSPAKE2を使用。TLS仲介、5分の期限、1回のPAKE接続、相手/グループに結び付けた承認ID、双方の設定完了確認。画像・動画・APIキーは仲介へ送らない。
- ネイティブだけがloopbackのSyncthing API資格情報を読む。承認前に共有/ライブラリ設定を書かない。失敗時は新しく追加した専用共有の相手を外す。解除もそのフォルダ内の所属だけで、Eagleとglobal deviceを維持。受信済みのコピーは消さない。
- ヘルパーをWindowsビルドに同梱。Rust 1.87以降、固定依存、EUPLおよび依存ライセンスを添付。Mac用arm64/x64のライセンスも生成済み。

## 検証

- 素材保存120、同期102、共有API/パス/状態機械33、Rust入力検証5が成功。
- 実TLS仲介へ架空の識別情報だけを使い、成功・誤コード・拒否・古い承認・異なるグループの5ケースを検証。
- ネイティブ2端末の模擬API試験で、承認前の書き込み0、明示承認、双方の完了、相手設定失敗時の取り消しが成功。
- さらに隔離Syncthing 2プロセスで、承認前共有0、実REST設定/readback、生成したテキストの原本とmetadataの転送、専用共有の解除/global device保持を確認。実設定には接続しない検証。証拠は `%TEMP%/HoverPocketPairingActual-alic3pv7` に保持。
- 実WebView2で6カテゴリ・検索・検索解除・狭い幅・日英・同期の停止/再開/競合解決、コード表示・元端末の承認・参加側待機・取消、相手名をHTMLとして解釈しないことを確認。パネルから同期変更/連携開始/承認は拒否。
- SettingsVerifierで設定保存、既定値、起動登録dry-run、更新、音声の接続済み/未接続/ログイン中の表示と確認境界が成功。
- Releaseビルドは警告0・エラー0。検証ログは `artifacts/pairing-settings-final-ui.log` と `artifacts/pairing-settings-regression.log`。開発候補は `artifacts/pairing-settings-build/`。

## 実データのreadback

- 実ライブラリ19件（有効14、ゴミ箱5）、原本19件がすべてDBのSHAと一致。既存原本を維持。保留0、未送信0、競合0、SQLite quick_check=ok。
- metadata digest `c1627f9a06bf2a66b52f0c780d786bac897a552750c362be2d29be3c08794b92` は変更前と一致。
- 既存Syncthing共有と端末設定は一致、専用共有39ファイル・転送待ち0・エラー0。設定は以前からの選択中ツール以外に差分なし。インストール済み本番EXEのSHAも維持。

## 残る作業と承認

- Windows共通helperはローカル `f2e410b` に保存。GitHubの既存リポジトリ `shotaro311/hover-pocket` へのpushを自動承認レビューが拒否したため、ユーザーへ送信先を明示して確認中。許可待ちを別経路のコード転送で回避していない。
- 許可後にpushし、Mac担当がhelperの組込みとMac実機ビルド、両OSのコード接続を完了する。全体進捗入口の統合はMac担当が所有。
- 両端末でSyncthingが起動していることが現在の前提。iPhoneの転送は未実装。既存の実接続を解除/再参加させる検証は行っていない。
- 今回のWindows候補への常駐アプリ切替、main統合、本番アプデ配信は未実施。
