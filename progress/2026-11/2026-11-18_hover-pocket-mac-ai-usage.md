# 2026-11-18 macOS版 AI Usage

Windows 0.2.19と同じ6サービスのAI使用状況を、macOSのパネルと設定の「AI」に実装した。作業ブランチは `codex/mac-ai-usage-20261118`、起点は `origin/main` の `e8d8659`。差分はMacのクローン `/Users/shotaro/code/share/hover-menu-preview` に未コミットで保存した。

## 実装

- AI Usageを組み込みツールの末尾に追加した。使用率のバー、経過目盛りとリセット時刻、残高と期限、Colabの時間あたりの消費、前回値・未サインイン・エラーを表示する。
- 設定の「AI」からサービスごとの表示とサインイン状態を管理できる。パネルの「設定でサインイン」から同じカテゴリへ移動できる。Codexはチャット・音声のChatGPTログインを使い、GeminiとColabはGoogleのログインを共有する。
- ウィンドウに載せないWKWebViewで、各サービスの `robots.txt` を起点として同一オリジンの応答を読む。応答をバイト数で制限し、Swiftで解析する。サインインには専用の永続WebKitデータストアを使う。サインイン用のウィンドウとポップアップに接続先のホスト・ポートを表示する。CodexBarのMITライセンスはMacバンドルの `Contents/Resources/ThirdParty/` へ同梱する構成にした。
- 取得は画面表示と明示操作に連動する。2分以内の結果と30分以内の未サインイン状態を再利用する。サインアウト中は共有サービスの読み取りを止め、世代が変わる前の結果を破棄する。GeminiとColabの初期化は同じ通知にまとめた。
- Macのチャットでも、モデル一覧の読み込みが失敗するとログイン案内が残る経路があった。共通のChatGPTログインが成功した時点で案内を消し、古い要求の失敗が案内を戻さないよう、比較と更新をメインアクター上で続けて行う。

## 変更ファイル

- AI Usage本体は [Providers/AiUsage](../../Sources/HoverPocket/Providers/AiUsage/) の `AiUsageProvider.swift`、`AiUsageStore.swift`、`AiUsageParsers.swift`、`AiUsageReaders.swift`、`AiUsageWebSession.swift`、`AiUsageSignInWindow.swift`、`AiUsageViews.swift`、`AiUsageCopy.swift`。
- パネル・設定への組み込みは `Providers/PocketProvider.swift`、`Providers/ProviderRegistry.swift`、`State/AppSettings.swift`、`Views/HoverPanelShell.swift`、`Views/PluginHostView.swift`、`Views/SettingsView.swift`、`Windowing/HoverWindowController.swift`、`Windowing/SettingsWindowController.swift`。
- ChatGPTログインは `Voice/CodexChatController.swift`、`Voice/CodexVoiceAccountLoginController.swift`。
- 検証は [AiUsageVerificationCommand.swift](../../Sources/HoverPocket/App/AiUsageVerificationCommand.swift)、`Sources/HoverPocket/main.swift`、[build_and_run.sh](../../script/build_and_run.sh)。
- ライセンスは [CodexBar-LICENSE.txt](../../script/ThirdParty/CodexBar-LICENSE.txt)。共通仕様と進捗は [requirements.md](../../docs/requirement/requirements.md) と [progress.md](../progress.md)。

## 検証

- `./script/build_and_run.sh --verify-ai-usage` は終了コード0。内部の `swift build -c debug -Xswiftc -warnings-as-errors` は警告0。
- `HoverPocket --verify-ai-usage <出力先>` は123項目とチャットのログイン表示の回帰検査に合格。6サービスの解析、誤ったゼロの抑止、キャッシュ期限、失敗時の前回値、世代の切替、GeminiとColabのアカウント変更通知、WebKit内の連続評価とストリームの上限を架空データで検証した。
- 同じスクリプトで実行した既存の `HoverPocket --verify-panel-layout` は144条件＋手動サイズ180条件と設定の保存・ウィンドウ寸法に合格。`HoverPocket --verify-chat` も合格。
- `bash -n script/build_and_run.sh`、`git diff --check`、WindowsのCodexBarライセンス原本とMac用コピーの `cmp` に合格。Windows差分は0件。起動中の本番アプリを終了する通常の `--verify` の代わりに、ビルドしたバイナリの検証コマンドを直接呼ぶモードを使った。
- `.build/ai-usage-verification/panel.png`（1040 × 1480）と `.build/ai-usage-verification/settings.png`（1280 × 1140）を保存し、両方を読み直した。青・黄・赤のバー、残高、Gemini行のサインアウト、Colabの共有表示を確認した。ログは `.build/mac-ai-usage-final-verify.log`。

## レビュー後の修正と匿名確認

- 隠しWebKitビューが、最上位でURLが指定の `robots.txt` と完全一致する文書を、HTTPステータスやMIMEに関係なく読み込めるようにした。リダイレクトは拒否し、ページ自身のJavaScriptは無効のまま、隔離された実行環境から同一オリジンの取得を行う。隠しビューでサブフレームを取り消した場合も、最上位の取得は続ける。
- サインイン窓ではメインフレームとポップアップの最上位にHTTPS制限を適用する。iframeが使う `about:blank`、`about:srcdoc`、`data:`、`blob:` などはこの制限から外し、接続先欄はメインフレームの接続先を表示する。
- 追加の変更は `AiUsageWebSession.swift`、`AiUsageSignInWindow.swift`、`AiUsageReaders.swift`、`AiUsageVerificationCommand.swift`、`main.swift`、`script/build_and_run.sh` と、この作業記録および `progress/progress.md` の計8ファイル。
- `./script/build_and_run.sh --verify-ai-usage` は警告0・終了コード0。AI Usageは11項目増えて134項目が合格し、既存の設定・パネル・チャット検証にも合格した。追加の検証ではローカルの403 HTMLから同じビューで2回取得し、ページ内JavaScriptの停止、リダイレクトの拒否、匿名モードでのPOSTの拒否、サインイン窓のフレーム別ポリシーを確認した。
- `./script/build_and_run.sh --verify-ai-usage-anonymous` は2026-11-18 19:09 JSTの確認で終了コード0。各サービスを使い捨ての非永続ストアで開き、本番と同じナビゲーション・取得・分類を通した。5サービスとも初回で `signedOut` となり、再試行は0回。Museは `/settings` の取得で判定が終わり、POSTは実行されなかった。Codexは対象外。
- `bash -n script/build_and_run.sh` と `git diff --check` に合格。ログは `.build/ai-usage-verification/review-fixes-offline.log` と `.build/ai-usage-verification/review-fixes-anonymous.log`。更新した全差分は同じフォルダの `changes.diff`。

| サービス | robots.txt | 取得先の応答 | 結果 |
|---|---|---|---|
| Claude | 200 text/plain | 403 JSON error | `signedOut` |
| Claude API | 200 text/plain | 403 JSON error | `signedOut` |
| Gemini | 200 text/plain | 200 JSON、`viewer: null` | `signedOut` |
| Colab | 403 text/html | 401 HTML | `signedOut` |
| Muse | 200 text/plain | `/settings` が401 JSON error | `signedOut` |

## 未確認

実アカウントのサインイン完了と使用状況の取得、実サイトのサインイン画面でのiframe・ポップアップ操作、Geminiの非ゼロ値の割合、署名済み配布物への同梱、本番アプリでの操作は未確認。今回の実サイト確認は匿名の読み取りまで。

## Windowsから差分を読む

```powershell
ssh mac "git -C /Users/shotaro/code/share/hover-menu-preview status --short --branch"
ssh mac "cat /Users/shotaro/code/share/hover-menu-preview/.build/ai-usage-verification/changes.diff"
```

差分ファイルには追跡済みの変更と `??` の新規ファイルを含めた。

共通仕様と参照実装の経緯は [Windowsパネル](2026-11-18_hover-pocket-ai-usage-panel.md) と [Windows残高](2026-11-18_hover-pocket-ai-usage-balances.md) に記載されている。

## macOS 0.2.18（771）の公開とこのMacの更新

- `65ede677eb8556207a5441ae0342841bd0d758ed` からDeveloper IDとHardened Runtimeで署名した。Apple Developerの契約同意が画面に反映され、`notarytool history` が成功した後に提出した。公証 `2854aea0-fa37-481f-ae2b-3c6708271dab` は `Accepted`。stapleとGatekeeper評価に合格した。
- [macOS 0.2.18（771）](https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.18-771)を公開し、タグが上記コミットを指すことを確認した。GitHubのLatestと[macOS更新フィード](https://github.com/shotaro311/hover-pocket/releases/download/macos-latest/appcast.xml)を771へ更新した。配信スクリプトの終了コード2はアップロード後の一時ファイル処理による。版付きReleaseの4ファイルと更新フィード側の2ファイルが公開されたことはGitHubから取得して確認した。
- 公開前と公開後の読み戻しは各99項目が合格。公開ZIPは35,004,643バイト、SHA-256は `26af73373c55413fb7d99ee4ac476908dcbd9a4923f3580f309fea98d46db7ce`。独立取得した公開ZIPでDeveloper ID署名、staple、Gatekeeperを確認し、SparkleのEdDSA署名とbuild 771を照合した。Windows 0.2.19の全8ファイルの名前・サイズ・SHA-256と、`releases.win.json`・`RELEASES` のバイトが公開前と一致した。
- 更新前に0.2.17（683）一式と利用者データを退避した。素材DBはSQLite Backup APIで保存し、整合性と外部キーを検査した。公開ZIPから更新し、PID `70567` から `7838` に切り替わったこと、AppKitイベントループの稼働、本体と同梱helperを含む全バンドルのファイルが公開物と一致することを確認した。
- 素材DBの論理内容と原本65点、会話履歴、画像クリップボード20件のIDと内容は一致した。テキストクリップボード30件のうち29件はID・内容・順序が一致し、先頭1件は起動時に現在のクリップボードと同じ既存文字列を再取得したためIDと時刻だけが更新された。設定49項目のうち変更はSparkleの `SULastCheckTime` のみ。SQLiteのWAL/SHMと起動時の日次スナップショットの生成は通常動作で、新しい日次スナップショットの整合性と内容の一致も確認した。
- [Verify macOS Capabilities](https://github.com/shotaro311/hover-pocket/actions/runs/44302391033)はパネルの100回開閉を含めて成功。[Verify Pocket Contracts](https://github.com/shotaro311/hover-pocket/actions/runs/44302391055)はUbuntuとWindowsが成功し、macOSジョブはGitHub Actionsの `macos-14-arm64-us-default` が提供対象外のため実行前に取り消された。既存の未解決事項として残す。実アカウントでのAI Usage受入は未実施。
