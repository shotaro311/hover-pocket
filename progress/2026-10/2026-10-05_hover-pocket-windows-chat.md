# Windowsの通常チャットと音声入力の接続検証

Mac親担当の依頼により、Windows refactor `3e7ba7c` から専用worktree/branch `codex/windows-chat-dictation-20261005` を作成した。前回の未コミット音声基盤は `de82c57` に分離してpush済み。元のDownloads作業コピーと通常checkoutのdirtyは保持し、共有assets UI・進捗入口は親担当に任せる。

## 実装した操作

パネル上部のチャットアイコンから通常チャットを開く。送信ボタンまたはCtrl+Enterで送信し、Enterは改行、日本語の変換確定は送信しない。入力中はCodexへの接続・依頼・マイク取得を開始しない。返答は逐次表示し、コピーできる。停止は進行中のturnと承認待ちを取り消す。会話窓を閉じると専用接続を終了する。

音声対話とは独立したcontroller/windowを使う。Codex app-serverの `thread/start`、`turn/start`、`turn/interrupt`、`thread/resume`を使用。会話本文の正本はapp-server、Hostは自分が作った会話ID・作成日時・操作一覧のdigestだけを保存する。履歴入口は直近40件。操作権限が変わった履歴は新しい会話を求める。無関係なrootや古いturnからの操作要求は拒否し、送信・操作の自動再試行はしない。

標準操作とLibrary11は音声対話と同じCapabilityBroker・内容確認・保存後のreadbackを使う。通常チャットの確認は開いているチャット窓を親にする。画像・動画・PDFの本体はモデルへ送らない。既存のHoverPocket専用ログインをそのまま使用するか、チャット窓から明示ログインする。新しいchat経路もRealtime起動も、hostの認証ファイルを自動コピーしない。

## 音声入力の制約

CLI 0.160.0の実schemaと接続で、専用のdictation endpointは見つからなかった。toolsなしのephemeral rootで `outputModality:text`、`clientManagedHandoffs:true`、`includeStartupContext:false`、WebSocket transportを試した。

- V3は `text realtime output modality requires realtime v2` と拒否された。
- V2は `realtime conversation requires API key auth` と拒否された。

このため、ChatGPTログインによる「録音→文字起こしだけを下書きへ入れる」の受入は未達。音声入力ボタンは理由を示す無効状態とし、マイクを開かない。APIキーや別の課金サービスへのfallbackは実装していない。V3の音声対話は別入口として残す。接続時に拒否されたので、文字起こし精度を検証できたという扱いにはしない。

## 検証

- Release/Debug build: 警告・エラー0。
- チャットのprotocol/native UI検証: 明示送信、stream/final、履歴、壊れた履歴、root/turnの分離、承認待ちの取消、停止後の操作拒否、権限変更、接続中の取消、未送信下書きとマイク未使用、窓の終了が通過。
- 実WebViewのチャットアイコン→bridge→native composer→編集→終了が通過。画面を描画して目視確認。
- CLI 0.160.0の実model routeに19ツールだけが存在することを、認証不要のローカルサーバーで確認。
- 実ChatGPT接続: 手入力→フォルダ作成要求→Hostの検証用承認→隔離AssetStoreへの保存/readback→assistant返答（20回の逐次更新）→履歴再開が通過。承認は固定された検証用フォルダだけを許可するfixtureで、本番素材の書き換えとマイク利用はない。認証は既存のアプリ専用profileをその場で使用し、コピーしていない。
- 既存音声foundation/native、保存コア99項目が通過。JS構文、差分の空白検査が通過。
- 親の共有UI `0d45739` を取り込み、Library11の最終検証がexit 0で通過。実PNGの撮影・保存・分類・readback・画像表示、実MP4の収録・停止保存・動画decode（自動再生なし）、対象窓を閉じた後の保存、重複start/stop、19ツールだけを渡す接続を確認した。検証用生成画面と隔離ライブラリを使用し、マイク・システム音声は取得していない。

最初の窓終了試験ではCloseを終了処理の途中で再呼出しする例外を検出した。dispatcherへ処理を戻してから閉じ、実Closed通知を待つよう修正。再検証ではプロセスexit 0を確認した。途中の失敗ログはworktreeのartifactsに保持する。

共有UI取込後の初回試験はexit 0でもログを生成せず、合格に数えなかった。再試験では検証用窓の前面化が間に合わず停止した。検証側で既存の前面化処理を使い、前面になったことを確認してから撮影対象を検証するように変更した。最終試験はログとexit 0の両方を確認した。

再実行は `--verify voice` に `HOVERPOCKET_CHAT_VERIFY_ONLY=1`、実接続は `HOVERPOCKET_CHAT_LIVE_VERIFY_ONLY=1`、パネル入口は `--verify ui` に `HOVERPOCKET_CHAT_PANEL_VERIFY_ONLY=1`。実接続検証には事前のアプリ専用ログインが必要。各ログは `HOVERPOCKET_VERIFY_LOG` で指定する。

[検証証拠](../evidence/2026-10-05-windows-chat/chat-final.log) / [実接続](../evidence/2026-10-05-windows-chat/chat-live.log) / [パネル入口](../evidence/2026-10-05-windows-chat/chat-panel.log) / [撮影・保存・共有プレビュー](../evidence/2026-10-05-windows-chat/library-final.log) / [画面](../evidence/2026-10-05-windows-chat/chat-composer.png) / [dictation V3](../evidence/2026-10-05-windows-chat/dictation-v3-result.json) / [dictation V2](../evidence/2026-10-05-windows-chat/dictation-v2-result.json)。

## 引き継ぎ

共有UIの `window.hpLibrary.showAsset(id) -> Promise<boolean>` は親担当の `0d45739d5d6bee75a600da1fdbc1d1e54ec17793` からassets.js/css/verifyとlibrary.htmlをそのまま取り込み、library_openを最終検証した。共有UIに含まれる整理・音声/カメラ等の追加ネイティブ操作はWindows library担当の変更と合わせて受け入れる。Windows library担当へbaseline `de82c57` とchat `75cd8f7`、共有UI・最終検証のコミットを渡し、一つの開発版へまとめる。mainへの統合、公開、本番アプリ・自動起動の差し替えは行っていない。既存の通常版プロセスを停止せず検証した。

初回ブラウザログインの人による操作、実マイク、OS間の操作感の比較は未検証。通常チャットのAPIキー方式は今回の対象に含めない。
