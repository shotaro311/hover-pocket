# 2026-10-05 ライブラリ操作・撮影・チャットの拡張

## 採用した方針

ユーザーが提案を承認。内部drag移動、外部drag取り込み、通常chat、App Server dictationの小検証、Libraryを入口としたcamera photo/video/audio収録を実装する。Macは共有assets UIとSwift、Windows担当はnative保存/drag/captureとchatの専用worktreeを担当する。公開・main統合は含めない。

## 共通UIの最初の引き渡し

- フォルダ/ゴミ箱/お気に入り/未分類のdrop targets、移動中のsidebar表示・強調・スクロール追従、source folderを限定する移動、undoTokenを追加。
- カメラ写真・動画・録音メニューを追加。native device選択/実収録はこの時点では実装中。
- [bridge契約](../../shared/asset-library/interactions.md)を両OSの基準にする。DB schemaは変更なし。
- Mac保存49項目、共有UIを含む既存UI59項目、既存AI52項目・100回開閉等が通過。追加したfolder/trash→folder/capture menuの検査は引き渡し直前の実WKWebView検査で確認する。
- native外部dragの追加・Macカメラ・通常chatは進行中。実機の外部アプリからのドラッグ、物理camera/mic録音は未受入。

## Windows担当

- Library: thread 01a0ff46-72f0-7582-afea-1f910bf1abb6、branch codex/windows-library-extensions-20261005。
- Chat: thread 01a10712-359c-7560-89da-e89d14751fdc、branch codex/windows-chat-dictation-20261005。
- Windows CLI 0.160.0のChatGPTログインで、Realtime text v3はv2必須、v2はAPI key auth必須として拒否されたとの実検証報告。課金APIへ切り替えず、音声入力は制限表示、通常chatを進める。Macでの同等検証は未実施。
