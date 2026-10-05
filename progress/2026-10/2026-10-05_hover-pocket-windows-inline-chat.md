# Windows パネル内チャット

## 実装

- 下部のVoice Laneへ常設の入力欄を置き、返信と履歴を同じパネル内で展開する。音声OFFでもテキストを送れる。従来の別ウィンドウとその生成経路を削除し、既存のCodexChatCoordinator、専用ログイン、履歴、権限・承認処理を再利用した。
- Enterで送信、Shift+Enterで改行。IME確定と直後のEnter、キーリピートでは送らない。送信は返答中に停止へ切り替わる。返信を選択してコピーでき、チャット内のDelete/Undo/Space等がライブラリ操作へ伝播しない。
- 入力フォーカス中・返答中は自動収納を止める。収納ボタン/Escでは下書き・会話・実行中の返答を保持して閉じ、上端ホバーで再表示できる。新規会話とアプリが所有する履歴の切替、会話別の下書き復元、接続失敗時の未送信文の復元を実装した。
- 返信領域は内部スクロール。小/特大でも入力と停止ボタンが画面内に収まり、パネルの高さをモニター作業領域で制限する。音声の波形も既存の開始・終了処理へ接続した。文字起こし専用の音声入力が現在のChatGPTログインで使えない理由は、無効ボタンの説明に保持した。

## 検証と readback

記録と生成素材だけの画像は [Windows検証記録](../../windows/verification/inline-chat-20261005/) に保存した。

- Release / Debugビルドは警告0・エラー0。JS構文と `git diff --check` が通過。
- `HOVERPOCKET_CHAT_PANEL_VERIFY_ONLY=1 --verify ui` はexit 0。実WebViewとネイティブ入力フォーカスで、音声OFF・送信までruntime起動なし・IME・1回だけの送信/停止・ストリーム中の入力DOM/カーソル保持・小/特大・スクロール・収納中の継続・ホバー復帰・履歴と下書き・コピー選択・キーの分離・Esc収納を確認。
- `HOVERPOCKET_CHAT_VERIFY_ONLY=1 --verify voice` はexit 0。所有する履歴、root/turn境界、承認取消、停止後の遅延tool拒否、接続失敗時の下書き保持を確認。
- `HOVERPOCKET_INLINE_CHAT_LIVE_VERIFY_ONLY=1 --verify ui` はexit 0。既存のアプリ専用ログインをその場所で利用し、パネルから送った「3+4」に実Codexが「7」と返答。音声OFF・同じパネルのDOMと画像を確認。資格情報のコピー、マイク利用、本番素材庫への書込みなし。実アプリ設定のCalendar権限がOFFなので17 toolsで、モデルへ渡る名前・schemaがその定義と完全一致することを既存probeで検査した。初回の「常に19 tools」という検査前提は誤りで、現在の権限定義との一致へ修正した。
- `--verify voice`、`--verify ui-model` はexit 0。既存の音声開始/終了・権限・隔離・音量等のnative機能を確認。
- `--verify ui` 全体は最終PASSを確認。素材の編集/保存失敗からの再試行・ドラッグ・Delete/Undo、既存プロバイダー、音声UI/ローカライズ/WebRTC fixture、4サイズ×2配置の開閉、30回の再入場、非表示タイマー通知、設定画面まで通過した。初回はネイティブヘッダークリックのタイムアウト、切り分け実行は外部へのフォーカス移動を伴うタイムアウトで、失敗証跡をartifactsへ保持し診断情報を追加した。再実行で対象の操作とUI全体が通過。長い検査のプロセスexit code自体は再取得できなかったため、完了ログのPASSとプロセス終了を確認している。最終のホバー復帰・ショートカット分離・下書き修正は専用パネル検査で再確認した。

## 統合と範囲

- `codex/windows-library-extensions-20261005` / PR #47へコミット・プッシュし、Mac担当がPR #44へ取り込む。共有の `progress/progress.md`、assets UI、contracts、MacソースはMac担当の所有とし、ここでは変更していない。
- 共通 `script/verify_voice_foundation.py:888` は旧 `voiceLaneEl.hidden` の文字列を要求して失敗する。現在は常設チャットを含む外側と音声だけの `voiceContentEl` を分けている。Mac担当へ引継ぎ済みで、共通スクリプトの修正と両OS CIは統合側で確認する。
- Windows本番PID72424・正規インストール先・自動起動は変更していない。実マイク/スピーカーでの音声会話は今回再検証していない。同期機能は実装していない。
