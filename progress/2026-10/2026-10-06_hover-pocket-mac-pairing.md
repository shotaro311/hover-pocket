# Macのコード接続を設定画面へ統合

## 実装

- 開発ブランチ `codex/macos-asset-library-0210` にWindows担当の共通helperと実装（`0fbb8ce`、停止状態の復旧修正 `2d39e34`）を取り込んだ。元checkoutの未コミット変更を保持。
- 「素材と同期」にコード表示・入力、相手の端末名/確認番号、明示承認、接続一覧と解除確認を追加。日本語/英語に対応。共有範囲がゴミ箱を含む全ライブラリであることを操作前に表示する。
- 1接続1プロセス・5分期限・3秒の再試行間隔。ウィンドウを閉じる/アプリ終了/取消でhelperを停止。標準入出力のコードと端末情報は記録しない。通常起動では試験用relay環境変数を継承しない。
- 認証済みpeerと承認IDを照合してから専用共有を設定・readbackする。失敗時は追加したmembershipだけを戻し、元が一時停止ならpeerの新規追加の有無に関係なく停止へ戻す。両方の復旧処理を独立して実行する。別処理の変更を検出して書込み前に中止した場合は、その変更をrollbackしない。
- Rust 1.92以降でhelperをビルドし、Mac bundleへ別実行ファイルとして署名・同梱。EUPL本体、NOTICE、依存ライセンスを同梱。macOS CIにRust build/testを追加した。

## 検証

- Swift warnings-as-errors、開発版671のbuildとcodesign検査が成功。
- Rust単体5項目、実TLS仲介を使う架空IDの正常接続/誤コード/拒否/古い承認/別groupの5ケースが成功。
- Macの模擬API24項目と64項目の接続状態検査が成功。承認前の無変更、二重承認、先行/古い/異なる承認、EOF、期限、取消、終了、peer設定失敗、既存peer+pausedからの復旧、symlink/別marker拒否を確認。
- Mac側stdioは最初の実両OS試験で短い入力を待ち続けた。`read(upToCount:)` から `availableData` に修正し、stdinを開いたままのfixture→imported即応と実helperのコード発行→取消→正常終了を確認。stdinを開いたまま短いメッセージを受信する回帰ケースを通常のMac検査にも追加。初回の失敗を成功に含めない。
- 外部仲介 `mailbox.mw.leastauthority.com` への検証用ID/名前/groupの暗号化送信、IP/時刻の可視性をユーザーへ説明し、本人の「許可して接続試験を続ける」を受けて実機試験を再開。素材を仲介へ送らない。
- Windows親controllerと固定SSHホスト鍵を使い、Windows invite→Mac join→明示承認→双方complete、Mac invite→Windows join→既存group保持を実機で確認。公開TLS仲介でコード接続し、素材転送は隔離SyncthingのSSHポート転送を使用した。LAN直接接続/素材用の外部relay経路の新たな受入とは区別する。
- 双方の空ライブラリへ生成したtext素材を1件ずつ入れ、両端末が2件になり、原本SHA・group・同期有効状態が一致。双方の専用membership解除、global device保持と受信素材保持を確認。Mac側も独立したSQLite/ファイル/API readbackで2件・全SHA・quick_check=ok・membership1（自分のみ）を確認。
- Mac・Windowsの検証専用Syncthingとverifierは終了。隔離証跡は保持。コード/approvalIdはGitや検査ログへ記録していない。
- 既存回帰：素材保存54・UI70・再起動2・同期47・AI素材53、voice foundation42、voice-only確認23、chat/IME/4サイズ、設定カテゴリ/隔離/レイアウト128、既存capabilities/broker/clipboard/timer、パネル100回開閉が成功。
- 実設定画面で日本語/英語の接続欄・接続済み端末とオンライン表示、無効コードの案内、解除確認文と取消を確認。日本語へ戻した。実ライブラリの接続コード発行や解除はしていない。
- 実19素材（通常14/ゴミ箱5）の全原本SHAとDB内容不変、Eagle共有と既存global device不変。Syncthing39ファイル、need0、errors0を前後でreadback。

## 境界と引き継ぎ

- 対象は開発版・開発ブランチ。mainへの統合、公開版644/Windows0.2.10への配信は含めない。
- 両PCでSyncthingの導入・起動が必要。iPhone単体の同期は未対応。
- 大量素材の速度測定、長期運用、スリープ/回線切替と公開配布は別受入。
- Windows側の詳細と両OS親スクリプトは `2026-10-06_hover-pocket-windows-settings-pairing.md` と `windows/tests/Pairing/verify_cross_platform.py`。Mac検証入口は `--verify-library-pairing-cross --pairing-config ...`。専用の一時root・marker・config内の端末ID一致を要求し、production discoveryは使わない。
