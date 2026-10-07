# 2026-10-07 本番反映

## 対象

- WindowsとMacの会話・ライブラリUI、モデル／推論の選択、返答重複の防止、ショートカット、範囲収録、自由サイズと配置。
- 元のdirty checkoutとMac開発worktreeの未関係変更を保持し、Windowsの独立worktreeで両OSソースを統合。
- PR: https://github.com/shotaro311/hover-pocket/pull/48 。Windows 0.2.11、Mac 0.2.11 / build 677を公開・インストール済み。

## 検証と配布準備

- Windows配布ビルド、OAuth metadata一致、設定検査、初回全UI検査が成功。
- GitHub初回CIでWeather.CoreのWPF参照不足と、旧会話表示を前提にした静的検査が失敗。WPFのサイズ変換を別partialファイルへ分離し、停止中の表示条件を確認する検査に更新。ローカル天気18項目、共通音声検査42条件が成功。
- 配布版を809077eから再生成。8資産の下書きReleaseを更新し、ダウンロードしたNUPKGと手元のSHA-256一致を確認。
- 再生成版の全UI検査はホバー待ちとドラッグ準備で不安定な失敗を記録。Windows CIも最終ネイティブクリックで一度失敗したが、同じ検査条件の再実行で全項目成功。再生成配布版の実パネル会話40項目とサイズ70条件も成功。
- 自動承認レビューはOAuth設定を理由に最初のアップロードを拒否した。Google公式native-app仕様と、ローカルJSONがinstalledクライアントで配布版に一致することを値を出さず確認。追加証拠付きの再審査が通り下書きを作成できた。ユーザートークンは配布対象に含めない。

## 反映結果と未完了

- Windowsの本番反映は完了。両OSのPR CIが成功し、PR #48をmainへ統合（1c68f73）。Windows 0.2.11をWindows専用Releaseへ公開。公開版の読み戻し99項目、8資産のダウンロード／ハッシュ、Mac feedの不変、CIの0.2.10から0.2.11へのinstall / update / rollback / reinstallが成功。
- Windows本番パスへ0.2.11+809077eを適用し、PID38832のshell.ready、公開版とのDLL一致、ARP DisplayVersion 0.2.11、設定と自動起動設定の一致、素材20件／DB論理hash一致を確認。クリップボード画像20件と画像ファイルhashは一致。テキストは現在のClipboard内容を1件取り込み、30件上限で最古の非お気に入りが1件入れ替わった。残る29件は変更なし。更新前のアプリ、設定、素材DB、全Clipboard履歴をstartup-backupへ保持。最初のstrict readbackはこの通常追加を差分としてexit 1にしたため、clipboard-delta-readback.jsonに原因を記録している。
- SSHではホスト名解決／既知IP接続に失敗したが、Codex内のPC Operatorがpaired_websocket_relayでMacへ接続済みであることを確認。この経路の直接コマンド実行へ切り替えた。別チャットやモデルへの委譲は行っていない。Macの既存開発worktreeとdirty checkoutは保持し、main 377d9b4から本番用worktreeを作成した。
- Mac 0.2.11 / build 677のDeveloper ID署名、Apple公証Accepted（2eaa2189-025d-489e-8cae-fcba6bd698da）、staple、Gatekeeper検査が成功。公開した手動インストールZIPを再ダウンロードして手元の公証済みZIPとのSHA一致を確認し、/Applications/HoverPocket.appへ適用。本番PID91090、実行ファイルの公開版との一致を確認した。会話37項目、配置と自由サイズの検査（160条件、最小520x372・最大880x630、日付の比率維持）が成功。
- Macの設定、素材20件、DBの全テーブル内容・原本hash、チャット履歴は一致。Clipboardはテキスト30件・画像20件の上限整理で最古の非お気に入りが各1件入れ替わった。テキストの追加分は現在のClipboardと一致し、残る29テキストと19画像の内容・画像ファイルは不変。更新前のアプリ・設定・全ユーザーデータをstartup-backupへ保持した。strict照合はClipboard差分によりexit 1。集計補助コードの構文エラーも修正し、区分別の最終照合startup-resolved-readback.jsonが成功した。
- 両OSの公開版を再検査し99項目が成功。Mac専用appcastは677、Windows専用feedは0.2.11。各公開資産のダウンロード／hash、Sparkle署名、手動ZIP一致、GitHub latestのMac専用運用を確認した。Macの644から677へのinstall / upgrade / rollback / uninstall / reinstall CIも成功。最後にWindows本番PID38832の応答と0.2.11+809077eを再確認した。
- 元の返答二重表示の発生条件は未特定。Macの実範囲収録は引き続きOS許可待ち。

## 根拠

`artifacts/release-0211-20261007/` のpackage.log、package-v2.log、verify-settings.log、verify-ui.log、verify-v2/、verify-v3/、oauth-client-audit.json、draft-readback.json、downloaded/。OAuthの実値は記録していない。

CI: Windows https://github.com/shotaro311/hover-pocket/actions/runs/37596399888 、Mac https://github.com/shotaro311/hover-pocket/actions/runs/37596399956 、更新・復元 https://github.com/shotaro311/hover-pocket/actions/runs/37598379964 。公開: https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.11 。

Mac更新・復元CI: https://github.com/shotaro311/hover-pocket/actions/runs/37602224392 。Mac公開: https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.11-677 。Windows側のpublic-readback-both.jsonが両OSの公開検査結果。Mac本番用worktreeのartifacts/release-0211-20261007/にprepare.log、publish.log、verify-chat.log、verify-layout.log、data-before.json、data-after.json、data-readback.json、clipboard-delta.json、startup-resolved-readback.json、public-install/、startup-backup/を保持した。

