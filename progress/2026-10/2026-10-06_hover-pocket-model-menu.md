# モデル・推論メニューの操作中にパネルが閉じる問題（2026-10-06）

両OSで、モデル／推論の選択肢へマウスを移すとパネルが閉じ、選択できないとの報告に対応した。元のdirty checkoutを保ち、継続中の独立worktreeで実装・検証・開発アプリの起動まで実施した。

## 原因と変更

- パネルの矩形外をホバー解除として扱っていた。従来の検証は選択値を直接変更しており、メニューの表示中を検査していなかった。
- Windows: モデル／推論をパネル内に収まる選択メニューへ変更。選択肢の長さ・件数に応じて内部で折り返し／スクロールし、表示中だけホバー収納を止める。選択、Esc、外側クリック、フォーカス解除、パネル終了、ページ離脱で保持を解除。矢印キー・Home・End・Enterでも選べる。取得前のモデルも一回のクリックで開く。
- Mac: AppKitの実際のメニュー開始・終了を監視し、表示中は収納を止める。選択と取消のどちらでも解除し、パネルを明示的に閉じる場合はメニューも終了する。[Appleの開始通知](https://developer.apple.com/documentation/appkit/nsmenu/didbegintrackingnotification)／[終了通知](https://developer.apple.com/documentation/appkit/nsmenu/didendtrackingnotification)の仕様を確認した。
- 入力・返答・音声会話だけではパネルを保持しない。会話と下書きを残してホバー解除で閉じる既存の要望を維持。

## 検証

- Windows: 実WebViewの選択メニューを開き、パネル外への移動中も表示を保持。モデル／推論の選択、Esc・外側クリック・フォーカス解除・明示終了後の収納と下書き保持を検査。モデルの取得前に最初の矢印キー操作で開くことも確認。最小／特大サイズの実表示でも選択肢が画面内へ収まることを確認し、画像を目視した。IME、入力、返信、停止、新規、履歴、自由サイズの既存検査も含む。[会話の検証](../../artifacts/menu-evidence/chat-release.log)／[最小サイズ](../../artifacts/menu-evidence/model-menu-small.png)。
- Windowsの全UIも成功。ライブラリの実クリック／編集／ドラッグ、設定、Controls等の既存機能、4サイズと30回の再入場を確認。[全UI](../../artifacts/menu-ui-no-dev/verify.log)。ビルドは警告0・エラー0。配備するUI5ファイルとソースのSHA-256も一致。
- Mac: 実際のAppKitメニューを開き、選択／取消の両方で追跡状態と収納の復帰が成功。Voice OFFで100回の開閉、100回の機能切替、5回の復旧、4サイズの入力中収納・下書き保持を検査。[実メニューと開閉](../../artifacts/mac-menu-evidence/hover-pocket-menu-soak.log)。
- Mac: 会話・IME・推論設定、既存配置128条件と手動配置160条件が成功。[会話](../../artifacts/mac-menu-evidence/hover-pocket-menu-chat.log)／[配置](../../artifacts/mac-menu-evidence/panel-layout.log)。
- Macへ反映したSwiftソースをSHA-256で照合し一致。両OSの差分空白検査も成功。

Windowsの再検査時に実キー入力が検証欄へ混ざったため、検証専用WebViewだけで実入力を防ぐようにして確認し直した。製品の入力処理にはこの制限を適用しない。全UI検査のControls判定も、全カードが同時に表示される旧条件から、内部スクロールで到達できる縦領域とカード内の操作が切れていないことを判定する形へ修正した。初回Macビルドは検証コードの参照記述で失敗し、修正後にビルドと上記検査が成功。

Windowsの全UI再実行では既存画像との保存先重複、ネイティブ更新クリック／フォーカス移動による中断、プロセスの異常終了も記録した。以前の証拠を残して保存先を分け、サイズ変更と更新ボタンの有効化を待つよう検査を調整。旧開発版の不在を確認した状態で、最終の全UIはexit=0となった。

## 起動とreadback

- Mac: 旧65973を通常終了し、開発版675／67480を起動。ビルド番号、プロセス、開発用ad-hoc署名を確認。[再起動](../../artifacts/mac-menu-evidence/restart.log)。
- Windows: 旧44216の不在を確認し、修正版90728を起動。実行先は`artifacts/menu-build/HoverPocket.Shell.exe`。応答あり、`process.start`／`shell.ready`、起動例外なし。[起動](../../artifacts/menu-evidence/windows-restart.log)。
- 変更は両OSの`codex/conversation-ux-20261006` worktreeへ未コミットで保持。

Windows作業先は`C:/Users/shotaro/code/shared/hover-pocket/artifacts/ux-20261006`、Mac作業先は`/Users/shotaro/.codex/worktrees/conversation-ux-20261006/hover-menu-preview`。Macの実装ソースの控えはWindows作業先の`artifacts/mac/Sources`にある。
