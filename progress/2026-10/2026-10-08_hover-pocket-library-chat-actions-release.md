# 2026-10-08 ライブラリと会話操作の本番反映

## 変更と反映

- [PR #52](https://github.com/shotaro311/hover-pocket/pull/52)をmainへ統合。統合コミットは`1cc8385a7bdabe28793f572e5c164c57f31003e0`。
- WindowsとMacでヘッダーのサイズ選択を廃止。右下のサイズ変更つまみと上下限を維持した。
- ライブラリ検索を120〜200pxにし、操作メニューを1行へ整理。狭い幅では横スクロールできる。
- 素材と会話の境界を上下にドラッグして高さを調整し、割合を保存する。双方の最小高さを確保し、サイズ変更へ追従する。
- 設定のAI・チャット項目に「Codexにアプリ内の操作をすべて許可」を追加。初期状態はオフ。対応する操作の確認を切り替え、素材のゴミ箱移動・復元・一括移動にも対応する。OSの許可は別途必要。
- 旧会話でツール一覧変更の案内が出た場合は左上の＋から新規会話を開始する。履歴は保持する。[使い方](../../docs/usage/library-chat-actions.md)。

## 最終検証

- Windows: releaseビルドは警告0・エラー0。最終配布バイナリの操作17項目、会話39項目、サイズ70条件、全UIが成功。設定オン・オフの保存、実マウスの境界ドラッグ、狭い幅の1行メニュー、ホバー収納を検証した。
- Windowsの実Codex接続で、隔離した素材を一括でゴミ箱へ移動できた。ユーザーの本番ライブラリにはこの検証操作を行っていない。
- Mac: releaseビルド、操作9項目、会話、保存54項目、全UI79項目、配置128＋160条件が成功。ネイティブ境界ドラッグの保存と保持解除、1行メニュー、狭い幅のスクロールを検証した。
- 両OSで拒否時の無変更、ゴミ箱からの復元、お気に入りと原本保持、準備後に追加された素材の除外、トークン偽造拒否、同じ操作の再実行抑止を確認した。Windowsの保存失敗時には境界位置を戻してエラーを表示する。
- Voiceの既存契約42項目、JavaScript構文、差分検査が成功。途中の旧レイアウト前提や非表示境界の検査失敗は修正し、最終ソースで再検証した。
- 最終PRのWindows CI `37640061263`、Mac CI `37640061607`が成功。統合mainの[Windows CI](https://github.com/shotaro311/hover-pocket/actions/runs/37641299264)と[Mac CI](https://github.com/shotaro311/hover-pocket/actions/runs/37641299301)も成功した。

## 公開配布物と更新

- [Windows 0.2.14](https://github.com/shotaro311/hover-pocket/releases/tag/win-v0.2.14)を8配布物と専用フィードへ公開。既存の未署名beta区分を維持し、GitHubのlatestには指定していない。
- [Mac 0.2.14 / build680](https://github.com/shotaro311/hover-pocket/releases/tag/v0.2.14-680)をDeveloper ID署名・公証・stapleして公開。公証`def3c0cb-184e-48eb-b9b3-3e51c77e0bf6`はAccepted。macOS専用appcastと手動ダウンロードaliasを更新した。
- 公開readbackは99項目すべて成功。各OSのフィード、配布物SHA256、Sparkle署名、Macの手動配布物一致を確認した。[独立公開検査CI](https://github.com/shotaro311/hover-pocket/actions/runs/37642040778)も成功した。
- [0.2.13から0.2.14への移行CI](https://github.com/shotaro311/hover-pocket/actions/runs/37642034009)は成功。Windowsの実インストール・更新・復元・再インストールと、Macの配布パッケージ導入・復元を隔離先で実行した。変更対象外の署名済みCodex sandbox MSI移行ジョブは実行対象から外した。

## 本番アプリの読み戻し

- Windowsを0.2.14へ更新し、起動・応答を確認。実バージョンは`0.2.14+f254a6ca4b36beeaf912382a58504338c549c58d`。導入済みDLL等は公開版と一致する。
- MacはCodex内のPC Operator接続で0.2.14 / build680へ更新し、起動を確認。アプリとhelperは公開版と一致し、署名・Gatekeeper・staple検査も成功した。
- 両OSで更新前後のデータと設定の保持を確認した。更新前のアプリとデータはバックアップへ保持する。元チェックアウトの未コミット変更とMacのstashも保持した。
- 公開・本番適用は既存の「どちらも本番反映してほしい」の承認に基づき実施した。端末固有の読み戻し証拠と詳細ログはローカルに保持し、この公開記録には機能・配布・検証結果だけを記載する。
