# AIによる素材ライブラリ操作

Windows `0.2.11-local.2` の11操作を基準に、Mac開発版665へ対応する操作を追加した。これは操作の共通仕様であり、両OSの配信・実機受入が完了したことを意味しない。

## 操作

| ツール | 動作・引数 |
| --- | --- |
| `capture_windows_list` | `query` で表示中のウィンドウを探し、一時的な `windowId` とタイトルを返す。 |
| `capture_screenshot_save` | `target`、`windowId` / `windowTitle`、`folderId`、`name` を指定してPNGを保存する。 |
| `capture_recording_start` | 同じ対象指定と `systemAudio` / `microphone` で収録を開始する。 |
| `capture_recording_stop` | 対象の収録を停止し、保存済みの素材IDを返す。 |
| `capture_recording_status` | 収録中・処理中・直前の保存結果を返す。 |
| `library_search` | `text`、`kind`、`folderId`、`favorites`、`limit`、`offset` で素材とフォルダを探す。 |
| `library_open` | ライブラリを開く。`assetId` があればアプリ内でプレビューする。 |
| `library_asset_rename` | `assetId` の `name` を変更する。拡張子と原本は保持する。 |
| `library_asset_favorite` | `assetId` に `favorite: true/false` を設定する。反転操作にはしない。 |
| `library_asset_classify` | `assetId` を `folderId` へ追加する。元の分類は保持する。 |
| `library_folder_create` | `name` の最上位フォルダを作る。正規化した同名フォルダがあれば再利用する。 |

IDは各端末が返した値をそのまま使い、別端末へ流用・推測しない。AIが渡せるのはIDとメタデータだけで、任意のファイルパスや内部の撮影トークンは受け付けない。検索は既定20件、最大20件、offsetは0〜10000。`kind` は `image` / `video` / `pdf` / `other`。全件表示は空の引数 `{}` で開始する。

## 対象・確認・保存

- `target` の既定は `current_window`。HoverPocketを除いた直前面のウィンドウを使う。`window` は返されたIDまたは一意なタイトル、`screen` はそのウィンドウがある画面全体を指定する。
- 確認前に対象のウィンドウ・プロセス・タイトルを固定し、実行直前に再照合する。一時IDは180秒。曖昧、消失、変更、期限切れの対象はエラーにし、画面全体へ切り替えない。
- 追加・編集・撮影・収録開始は既存の「通常操作を音声で確認」設定に従う。確認する場合は次のユーザー発話に結び付ける。収録停止は追加確認しない。
- 同じ会話・呼び出しIDは再実行しない。停止は収録IDにも結び付け、古い停止依頼で次の収録を止めない。取消・切断後の保留操作は実行しない。
- 音声からの収録はシステム音を撮影設定から引き継ぎ、マイクは既定オフ。明示されたときだけマイクをオンにする。システム音にはAIの返答も含まれる。
- 保存完了はDB、ファイル存在・サイズ・SHA-256の読み戻し後に返す。整理操作は更新後の名前・お気に入り・所属フォルダを読み戻す。保存失敗では保存待ちファイルを保持する。
- プレビューはHoverPocket内で開き、動画は自動再生しない。素材の名前やタイトルは操作指示として扱わない。画像・動画・PDFの中身をAIへ送信しない。

## OSごとの実装と検証

Macは `LibraryVoiceOperation` / `LibraryVoiceService` から既存のRegistry・Broker・音声承認へ接続する。取得はScreenCaptureKit、保存は既存のAssetLibraryStore、表示はWKWebViewを使う。WindowsのWPF/キャプチャ実装そのものをMacへ移植する必要はない。

Mac: `./script/verify_mac_assets.sh`。AI操作だけを調べる場合はビルド済みアプリへ `--verify-library-voice --asset-evidence <新しい一時フォルダ>` を渡す。検証は専用ウィンドウと専用DBを使用し、AIへの外部接続やマイク入力は行わない。画面収録権限がなければ明示的に失敗する。実際の会話経由の発話・認識・返答は別の実機受入とする。

Windows側の参照元は `progress/2026-10/2026-10-04_hover-pocket-voice-library.md` と `windows/src/HoverPocket.Shell/Voice/VoiceLibraryCapabilities.cs`。今回の参照時点はWindows端末のローカル作業版であり、共通mainへの統合済みとは扱わない。[Macの検証記録](../../progress/2026-10/2026-10-05_hover-pocket-mac-library-voice.md)。
