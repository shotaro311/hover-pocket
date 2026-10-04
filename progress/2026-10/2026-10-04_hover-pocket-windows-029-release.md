# 2026-10-04 Windows 0.2.9 本番配信

ユーザーがlocal.15の改善を確認し、「いったんこれで本番反映して」と依頼。確認済みのWindows機能とちらつき修正を0.2.9へまとめ、Windows専用のwin-v0.2.9とwin channelへ配信する。既存の0.2.x公開ベータ・未署名方針を維持する。

## 配信前の確認

- 作業ツリーはDownloads/hover-pocket-windows-liquid-20261002。元のdirty checkoutは保持。
- 公開中Windowsはwin-v0.2.8。GitHub LatestはmacOS v0.1.0-644で、macos-latest/appcast.xmlの内容を配信前に保存した。
- 通常起動中は確認済みlocal.15（PID33248）。自動起動はLocalAppData/HoverPocketWin/current/HoverPocket.Shell.exeを指すが、インストール済みは0.2.9-local.2。公開成果物の検証後にここを更新する。
- ユーザーによる操作確認に加え、local.15は初回を含む6回の拡大録画、縮小・途中取消、素材UI回帰、Release/Debug、JS17ファイルで検証済み。詳細は[ちらつき修正記録](2026-10-04_hover-pocket-claude-opening.md)。

成果物の作成・公開・インストールの結果は完了後に追記する。
