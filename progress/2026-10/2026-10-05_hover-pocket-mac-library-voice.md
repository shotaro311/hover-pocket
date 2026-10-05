# MacへAIの素材ライブラリ操作を追加

日付: 2026-10-05 / Mac開発版665 / branch `codex/macos-asset-library-0210` / draft PR #44

## 実装

Windowsの作業版 `0.2.11-local.2` を読み取り、同じ11操作をMacへ追加した。`LibraryVoiceOperation` が操作・検証・ツール定義を持ち、`LibraryVoiceService` を既存のCapability Registry / Broker / Codex bridge / 音声承認に接続する。撮影対象は承認前に固定し、実行直前に確認する。お気に入りは明示状態、分類は追加、停止は収録IDに束縛。取得はScreenCaptureKit、保存とプレビューは既存実装を再利用する。

共通の素材UIへ `openAsset` を追加し、プレビューが成功した場合だけ成功を返す。Windowsネイティブ実装には変更していない。共有ソースの変更はこの3行と共通仕様の文書のみ。原本の中身をAIへ送信しない。

## 検証とreadback

- `--verify-library-voice`: 52項目。11操作の公開とCodex dynamic tool実行、実PNG・MP4、画素による対象確認、承認中の前面切替・タイトル変更・曖昧対象、再送、古い停止ID、保存先・SHA、明示お気に入り、分類保持、プレビューの実デコードと動画自動再生なし、実ランタイムの音声確認・取消。
- `verify_mac_assets.sh --skip-build`: 音声契約42、素材保存40、UI58、別プロセス再開2、個人ツール42、音声確認23、レイアウト128、Clipboard/Timer、100回パネル開閉が成功。初回はAI検証45項目、その後の追加7項目を含む最終52項目を個別に再実行した。
- `--verify-voice-foundation` / `--verify-capabilities` / `--verify-broker`: 成功。Brokerは操作追加前の件数比較で一度失敗し、53件への期待値更新後に再実行して成功した。
- build 665 / Bundle ID `local.codex.hover-pocket.asset-dev` / Keychain suffix `asset-dev`。署名の厳密検証成功。
- バイナリSHA-256: `986d0b52b314a7df11c584473280a225ca53fa0030820ef143250f114338781a`。
- 旧開発版PID73277だけを停止し、新しい同一開発アプリをPID85634で起動し、実行パスを別のprocess一覧で読み戻した。設定画面の表示とVoice既定オフを確認した。公開アプリ・自動更新feedは変更していない。
- 別プロセスのPython/SQLiteで `integrity_check=ok`、PNG 23,805 bytes・MP4 11,293 bytesのSHAがDBとそれぞれ1件一致することを再確認した。
- 最終AI検証: `/private/tmp/hp-ai-665-final/voice/report.json`。既存回帰: `/var/folders/mv/0d7m444d25d_q88sj2wfntj80000gn/T/HoverPocket-Assets-gRA7Nt`。補助ログ: `/private/tmp/hp-ai-665`。

実マイクからの発話、外部Realtime接続、長時間収録、複数モニター、Windowsの今回変更後の実機受入は未検証。ローカル実装・自動検証を公開・main統合や両OS実機受入と同一視しない。

## 参照と引き継ぎ

Windows `C:/Users/shotaro/Downloads/hover-pocket-windows-liquid-20261002` の実ファイルをPC Operator経由で読み取った。`VoiceLibraryCapabilities.cs` の取得後SHA-256は `6c4dccf45984c978fd524b209efdb2189bad8239763e3b8317fa2cd05f10324a`、`CaptureVoiceOperations.cs` は `d12978ae9e30a200cca0b9daf06d83a17fd73b3b80a7fd417246b25f5f522e28`。Windowsのローカル変更を共通Gitへ統合済みとは扱わない。

[操作仕様](../../docs/requirement/asset-library-voice.md) / [使い方](../../docs/usage/macos-asset-library.md)。Windowsとの継続開発には、依頼窓口を一つにし、機能ごとの共通仕様・受入条件を先に共有してOS別ブランチで実装する進め方を提案した。共通UI・契約ファイルの編集者を一人に決め、PRとcommit SHAで受け渡し、各OSの実機結果を別々に確認する。新たな自動化や他タスクへの依頼はこの作業では設定していない。

## コミット・CIの確認

実装を `a9a6bb786d0f748f59b35d3f57716d00887b889b` へコミットし、既存ブランチへpushした。`git ls-remote` とPR #44のheadRefOidが一致。Mac CI [37261639188](https://github.com/shotaro311/hover-pocket/actions/runs/37261639188) とWindows CI [37261639108](https://github.com/shotaro311/hover-pocket/actions/runs/37261639108) はいずれもsuccess。共通契約のMac/Windows/Linux検証も成功。PRはDraftを維持している。この追記は検証結果だけを記録し、ビルド665のソースを変えない。
