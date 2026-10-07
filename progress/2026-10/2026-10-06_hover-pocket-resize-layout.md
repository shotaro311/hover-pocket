# 自由サイズの上下限と画面配置（2026-10-06）

## 変更

WindowsとMacの右下つまみに、旧Smallと同じ下限と、旧Extra Largeより縦横約15%大きい上限を設けた。基準値はWindowsが520×372〜900×650 DIPs、Macが520×372〜880×630 pt。会話などの追加領域を足してから、画面の作業領域へ収める。保存済みの自由サイズにも表示時にこの制限を適用する。[共通仕様](../../docs/requirement/conversation-ux-20261006.md)。

実際の表示幅・高さを各画面へ渡し、ドラッグ中に配置を更新する。カレンダーは左右の幅を配分し、日付マスを一定の縦横比で表示する。Windowsは左右の列幅と日付グリッド幅を分け、横長でも日付を引き伸ばさない。Macはウィンドウ外側の余白16ptを自由サイズへ追加し、本文が切れる問題も修正した。

Controlsは操作カードを縮めて内容が隠れないようにし、必要に応じてスクロールする。電卓・Controls・Timerは内容幅や高さを制限して中央へ配置する。Clipboard、Sticky、Assets、MacのMirrorも最小・最大・横長・縦長・中間で確認した。サイズ変更でProviderを作り直さず、入力や選択状態を保持する。

前回と同じ独立worktreeを使用した。元の両OSの未コミット作業は保持し、今回もcommit・push・公開は行っていない。

## 検証

- Windows Debugビルド: 警告0、エラー0。JS構文と差分検査が成功。
- Windows実パネル: 5サイズ×7画面×2文字サイズの70条件が成功。ネイティブつまみの最小520×507／最大900×785（会話126・入口9を含む）、保存と再表示、カレンダーの7列・比率・横方向の収まり、操作カード内のボタン位置を検査。[サイズ検査](../../artifacts/resize-accepted/verify.log)。
- Windows既存UI: ライブラリの実クリック・ドラッグ・Undo・編集、各Provider、文字サイズ、16通りの入口、8通りの接合、30回再入場、設定、Timer等が成功。[全UI](../../artifacts/resize-regression/accepted.log)。会話のIME・カーソル・送信・停止・履歴・ホバー収納・保存サイズ維持も成功。[会話](../../artifacts/chat-resize-accepted.log)。
- Mac Swift Debugビルド: 成功。従来の128条件と、5サイズ×8画面×4文字サイズの160条件が成功。カレンダーは認証案内に加えて日付・左右パネルの実Viewも表示し、比率と配置を検査。[配置ログ](../../artifacts/mac-resize-evidence/hover-pocket-resize-layout.log)。
- Mac実ウィンドウ: 100回開閉、100回Provider切替、回復5回、アニメーション反転3回が成功。自由サイズの実フレーム、本文幅、上下限、画面内への制限を検査。RSS107.094→109.234MiB、ソケット／子プロセス0→0。[開閉ログ](../../artifacts/mac-resize-evidence/hover-pocket-resize-soak.log)。
- 最小・最大・横長・縦長・中間の画像を両OSで保持。Macのオフスクリーン描画は半透明の色が正しく合成されないため、位置・寸法の参考画像として扱い、実画面の色の証拠にはしていない。

Windowsの最初のサイズ検査は検査側のStickyセレクター誤りでタイムアウトし、修正後に成功。画像確認で最小Controlsの操作がカード内に隠れている問題を見つけ、カードの最小高さとスクロールを直して70条件と既存UIを再検証した。全UIの最初の起動はコンソール出力を取得できなかったため、終了後に専用ファイルログを有効にして成功結果を取得した。

## 開発アプリとreadback

- Windows: 旧69504をトレイの「終了」で通常終了し、修正版71160を起動。`artifacts/resize-build/HoverPocket.Shell.exe`、応答あり、`shell.ready`、起動時例外なし。[起動記録](../../artifacts/resize-dev-start.log)。
- Mac: 旧53561をbundleパス指定の通常終了要求で閉じ、開発版673／PID62003を起動。`/Users/shotaro/.codex/worktrees/conversation-ux-20261006/hover-menu-preview/dist/HoverPocket.app`、15:57:25の新プロセスを読み戻した。開発用ad-hoc署名の整合検査が成功。配布用署名ではない。
- Windows作業先: `C:\Users\shotaro\code\shared\hover-pocket\artifacts\ux-20261006`。Mac作業先は上記bundleの親worktree。両OSの共通仕様・進捗を読み戻し、Macの変更Swift22ファイルは作業用コピーとSHA-256がすべて一致した。最後のWindows起動診断も`process.start`・`shell.ready`だけで例外なし。

実マウスによる全画面・混在DPIの連続ドラッグは未検証。前回のMac画面収録のOS許可待ちは継続しており、今回のサイズ変更検査とは別の未完了事項。
